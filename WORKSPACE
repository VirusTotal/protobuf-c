workspace(name = "com_github_protobuf_c")

# Bazel workspace file
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
  name = "bazel_skylib",
  remote = "https://github.com/bazelbuild/bazel-skylib",
  commit = "327d61b5eaa15c11a868a1f7f3f97cdf07d31c58",
  shallow_since = "1572441481 +0100"
)

git_repository(
  name = "com_google_protobuf",
  remote = "https://github.com/google/protobuf",
  commit = "403df1d047607b5194d938d3c9943a4813308eb3",
  shallow_since = "1572384890 -0700"
)

load("@com_google_protobuf//:protobuf_deps.bzl", "protobuf_deps")
protobuf_deps()
