load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Madgram: the flat, pre-Liquid-Glass navigation bar, used for every screen while `ClassicDesign.isEnabled`
# (restored from NavigationBarImpl's `.legacy` style, deleted upstream in 16b065d8d0).
swift_library(
    name = "ClassicNavigationBar",
    module_name = "ClassicNavigationBar",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/AppBundle",
    ],
    visibility = [
        "//visibility:public",
    ],
)
