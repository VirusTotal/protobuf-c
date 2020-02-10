
load("@rules_cc//cc:defs.bzl", "cc_library")

def _GetPath(ctx, path):
    if ctx.label.workspace_root:
        return ctx.label.workspace_root + "/" + path
    else:
        return path

def _IsNewExternal(ctx):
    # Bazel 0.4.4 and older have genfiles paths that look like:
    #   bazel-out/local-fastbuild/genfiles/external/repo/foo
    # After the exec root rearrangement, they look like:
    #   ../repo/bazel-out/local-fastbuild/genfiles/foo
    return ctx.label.workspace_root.startswith("../")

def _GenDir(ctx):
    if _IsNewExternal(ctx):
        # We are using the fact that Bazel 0.4.4+ provides repository-relative paths
        # for ctx.genfiles_dir.
        return ctx.genfiles_dir.path + (
            "/" + ctx.attr.includes[0] if ctx.attr.includes and ctx.attr.includes[0] else ""
        )

    # This means that we're either in the old version OR the new version in the local repo.
    # Either way, appending the source path to the genfiles dir works.
    return ctx.var["GENDIR"] + "/" + _SourceDir(ctx)

def _SourceDir(ctx):
    if not ctx.attr.includes:
        return ctx.label.workspace_root
    if not ctx.attr.includes[0]:
        return _GetPath(ctx, ctx.label.package)
    if not ctx.label.package:
        return _GetPath(ctx, ctx.attr.includes[0])
    return _GetPath(ctx, ctx.label.package + "/" + ctx.attr.includes[0])

def _CHdrs(srcs):
    ret = [s[:-len(".proto")] + ".pb-c.h" for s in srcs]
    return ret

def _CSrcs(srcs):
    ret = [s[:-len(".proto")] + ".pb-c.c" for s in srcs]
    return ret

def _COuts(srcs):
    return _CHdrs(srcs) + _CSrcs(srcs)

def _proto_gen_impl(ctx):
    """General implementation for generating protos"""
    srcs = ctx.files.srcs
    deps = []
    deps += ctx.files.srcs
    source_dir = _SourceDir(ctx)
    gen_dir = _GenDir(ctx).rstrip("/")

    if source_dir:
        import_flags = ["-I" + source_dir, "-I" + gen_dir]
    else:
        import_flags = ["-I."]

    for dep in ctx.attr.deps:
        import_flags += dep.proto.import_flags
        deps += dep.proto.deps

    for src in srcs:
        args = []
        in_gen_dir = src.root.path == gen_dir
        if in_gen_dir:
            import_flags_real = []
            for f in depset(import_flags).to_list():
                path = f.replace("-I", "")
                import_flags_real.append("-I$(realpath -s %s)" % path)
        path_tpl = "$(realpath %s)" if in_gen_dir else "%s"
        args = []
        outs = _COuts([src.basename])
        outs = [ctx.actions.declare_file(out, sibling = src) for out in outs]
        inputs = [src] + deps
        tools = [ctx.executable.protoc]
        if ctx.executable.plugin:
            plugin = ctx.executable.plugin
            lang = ctx.attr.plugin_language
            if not lang and plugin.basename.startswith("protoc-gen-"):
                lang = plugin.basename[len("protoc-gen-"):]
            if not lang:
                fail("cannot infer the target language of plugin", "plugin_language")
            outdir = "." if in_gen_dir else gen_dir
            if ctx.attr.plugin_options:
                outdir = ",".join(ctx.attr.plugin_options) + ":" + outdir
            args += [("--plugin=protoc-gen-%s=" + path_tpl) % (lang, plugin.path)]
            args += ["--%s_out=%s" % (lang, outdir)]
            tools.append(plugin)

        if not in_gen_dir:
            ctx.actions.run(
                inputs = inputs,
                tools = tools,
                outputs = outs,
                arguments = args + import_flags + [src.path],
                executable = ctx.executable.protoc,
                mnemonic = "ProtoCompile",
                use_default_shell_env = True,
            )
        else:
            for out in outs:
                orig_command = " ".join(
                    ["$(realpath %s)" % ctx.executable.protoc.path] + args +
                    import_flags_real + ["-I.", src.basename],
                )
                command = ";".join([
                    'CMD="%s"' % orig_command,
                    "cd %s" % src.dirname,
                    "${CMD}",
                    "cd -",
                ])
                generated_out = "/".join([gen_dir, out.basename])
                if generated_out != out.path:
                    command += ";mv %s %s" % (generated_out, out.path)
                ctx.actions.run_shell(
                    inputs = inputs,
                    outputs = [out],
                    command = command,
                    mnemonic = "ProtoCompile",
                    tools = tools,
                    use_default_shell_env = True,
                )

    return struct(
        proto = struct(
            srcs = srcs,
            import_flags = import_flags,
            deps = deps,
        ),
    )


proto_gen = rule(
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = ["proto"]),
        "includes": attr.string_list(),
        "protoc": attr.label(
            cfg = "host",
            executable = True,
            allow_single_file = True,
            mandatory = True,
        ),
        "plugin": attr.label(
            cfg = "host",
            allow_files = True,
            executable = True,
        ),
        "plugin_language": attr.string(),
        "plugin_options": attr.string_list(),
        "outs": attr.output_list(),
    },
    output_to_genfiles = True,
    implementation = _proto_gen_impl,
)

def c_proto_library(
        name,
        srcs = [],
        deps = [],
        cc_libs = [],
        include = None,
        protoc = "@com_google_protobuf//:protoc",
        default_runtime = "@com_google_protobuf//:protobuf",
        **kargs):
    """Bazel rule to create a C protobuf library from proto source files
    Args:
      name: the name of the c_proto_library.
      srcs: the .proto files of the c_proto_library.
      deps: a list of dependency labels; must be cc_proto_library.
      cc_libs: a list of other cc_library targets depended by the generated
          cc_library.
      include: a string indicating the include path of the .proto files.
      protoc: the label of the protocol compiler to generate the sources.
      default_runtime: the implicitly default runtime which will be depended on by
          the generated cc_library target.
      **kargs: other keyword arguments that are passed to cc_library.
    """

    includes = []
    if include != None:
        includes = [include]

    gen_srcs = _CSrcs(srcs)
    gen_hdrs = _CHdrs(srcs)
    outs = gen_srcs + gen_hdrs

    gen_name = name + "_genproto"

    proto_gen(
        name = gen_name,
        srcs = srcs,
        deps = [s + "_genproto" for s in deps],
        includes = includes,
        protoc = protoc,
        plugin = "@com_github_protobuf_c//:protoc-gen-c",
        plugin_language = "c",
        outs = outs,
        visibility = ["//visibility:public"],
    )

    if default_runtime and not default_runtime in cc_libs:
        cc_libs = cc_libs + [default_runtime]

    cc_library(
        name = name,
        srcs = gen_srcs,
        hdrs = gen_hdrs,
        deps = cc_libs + ["@com_github_protobuf_c//:protobuf-c"],
        includes = includes,
        **kargs
    )
