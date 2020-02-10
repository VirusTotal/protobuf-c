


def source_files(name, srcs):
    outs = ['src/' + path for path in srcs]
    native.genrule(
        name = name,
        srcs = srcs,
        outs = outs,
        cmd = "mkdir src\n" + "\n".join([
            "cp $(location %s) $(location :%s)" % (src, dst)
        for src, dst in zip(srcs, outs)]),
    )
