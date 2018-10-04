load("@bazel_tools//tools/build_defs/pkg:pkg.bzl", "pkg_tar")
load(
    ":java_gapic_pkg_deps_resolution.bzl",
    "construct_dep_strings",
    "construct_gradle_assembly_includes_subs",
    "construct_gradle_build_deps_subs",
    "get_dynamic_subsitution_func",
    "is_source_dependency",
    "is_proto_dependency",
)

def _java_gapic_build_configs_pkg_impl(ctx):
    expanded_templates = []
    deps_struct = construct_dep_strings(
        ctx.attr.deps,
        ctx.attr.test_deps,
        ctx.attr.artifact_group_overrides,
    )
    paths = _construct_package_dir_paths(ctx.attr.package_dir, ctx.outputs.pkg, ctx.label.name)
    for template in ctx.attr.templates.items():
        substitutions = dict(ctx.attr.static_substitutions)
        dynamic_subs_func_name = ctx.attr.dynamic_substitutions.get(template[0])
        if dynamic_subs_func_name:
            dynamic_subs_func = get_dynamic_subsitution_func(dynamic_subs_func_name)
            substitutions.update(dynamic_subs_func(deps_struct))

        expanded_template = ctx.actions.declare_file(
            "%s/%s" % (paths.package_dir_sibling_basename, template[1]),
            sibling = paths.package_dir_sibling_parent,
        )
        expanded_templates.append(expanded_template)
        ctx.actions.expand_template(
            template = template[0].files.to_list()[0],
            substitutions = substitutions,
            output = expanded_template,
        )

    # Note the script is more complicated than it intuitively should be because of the limitations
    # inherent to bazel execution environment: no absolute paths allowed, the generated artifacts
    # must ensure uniqueness within a build. The template output directory manipulations are
    # to modify default 555 file permissions on any generated by bazel file (exectuable read-only,
    # which is not at all what we need for build files). There is no bazel built-in way to change
    # the generated files permissions, also the actual files accessible by the script are symlinks
    # and `chmod`, when applied to a directory, does not change the attributes of symlink targets
    # inside the directory. Chaning the symlink target's permissions is also not an option, because
    # they are on a read-only file system.
    script = """
    mkdir -p {package_dir_path}
    for templ in {templates}; do
        cp $templ {package_dir_path}/
    done
    chmod 644 {package_dir_path}/*
    cd {package_dir_path}
    tar -zchpf {package_dir}.tar.gz {package_dir_expr}
    cd -
    mv {package_dir_path}/{package_dir}.tar.gz {pkg}
    """.format(
        templates = " ".join(["'%s'" % f.path for f in expanded_templates]),
        package_dir_path = paths.package_dir_path,
        package_dir = paths.package_dir,
        pkg = ctx.outputs.pkg.path,
        package_dir_expr = paths.package_dir_expr,
    )

    ctx.actions.run_shell(
        inputs = expanded_templates,
        command = script,
        outputs = [ctx.outputs.pkg],
    )

java_gapic_build_configs_pkg = rule(
    attrs = {
        "deps": attr.label_list(mandatory = True, non_empty = True),
        "test_deps": attr.label_list(mandatory = False, allow_empty = True),
        "package_dir": attr.string(mandatory = False),
        "artifact_group_overrides": attr.string_dict(mandatory = False, allow_empty = True, default = {}),
        "templates": attr.label_keyed_string_dict(mandatory = False, allow_files = True),
        "static_substitutions": attr.string_dict(mandatory = False, allow_empty = True, default = {}),
        "dynamic_substitutions": attr.label_keyed_string_dict(mandatory = False, allow_files = True),
    },
    outputs = {"pkg": "%{name}.tar.gz"},
    implementation = _java_gapic_build_configs_pkg_impl,
)

def _java_gapic_srcs_pkg_impl(ctx):
    srcs = []
    proto_srcs = []
    for src_dep in ctx.attr.deps:
        if is_source_dependency(src_dep):
            srcs.extend(src_dep.java.source_jars.to_list())
        if is_proto_dependency(src_dep):
            proto_srcs.extend(src_dep.proto.check_deps_sources.to_list())

    test_srcs = []
    for test_src_dep in ctx.attr.test_deps:
        if is_source_dependency(test_src_dep):
            test_srcs.extend(test_src_dep.java.source_jars.to_list())

    paths = _construct_package_dir_paths(ctx.attr.package_dir, ctx.outputs.pkg, ctx.label.name)

    # Note the script is more complicated than it intuitively should be because of limitations
    # inherent to bazel execution environment: no absolute paths allowed, the generated artifacts
    # must ensure uniqueness within a build.
    script = """
    for src in {srcs}; do
        mkdir -p {package_dir_path}/src/main/java
        unzip -q -o $src -d {package_dir_path}/src/main/java
        rm -r -f {package_dir_path}/src/main/java/META-INF
    done
    for proto_src in {proto_srcs}; do
        mkdir -p {package_dir_path}/src/main/proto
        cp -f --parents $proto_src {package_dir_path}/src/main/proto
    done
    for test_src in {test_srcs}; do
        mkdir -p {package_dir_path}/src/test/java
        unzip -q -o $test_src -d {package_dir_path}/src/test/java
        rm -r -f {package_dir_path}/src/test/java/META-INF
    done
    cd {package_dir_path}
    tar -zchpf {package_dir}.tar.gz {package_dir_expr}
    cd -
    mv {package_dir_path}/{package_dir}.tar.gz {pkg}
    """.format(
        srcs = " ".join(["'%s'" % f.path for f in srcs]),
        proto_srcs = " ".join(["'%s'" % f.path for f in proto_srcs]),
        test_srcs = " ".join(["'%s'" % f.path for f in test_srcs]),
        package_dir_path = paths.package_dir_path,
        package_dir = paths.package_dir,
        pkg = ctx.outputs.pkg.path,
        package_dir_expr = paths.package_dir_expr,
    )

    ctx.actions.run_shell(
        inputs = srcs + proto_srcs + test_srcs,
        command = script,
        outputs = [ctx.outputs.pkg],
    )

java_gapic_srcs_pkg = rule(
    attrs = {
        "deps": attr.label_list(mandatory = True, non_empty = True),
        "test_deps": attr.label_list(mandatory = False, allow_empty = True),
        "package_dir": attr.string(mandatory = True),
    },
    outputs = {"pkg": "%{name}.tar.gz"},
    implementation = _java_gapic_srcs_pkg_impl,
)

def java_gapic_proto_gradle_pkg(
        name,
        deps,
        group,
        version,
        test_deps = None,
        visibility = None,
        classifier = ""):
    _java_gapic_gradle_pkg(
        name = name,
        pkg_type = "proto",
        deps = deps + [
            "@com_google_protobuf_protobuf_java//jar",
            "@com_google_api_grpc_proto_google_common_protos//jar",
        ],
        test_deps = test_deps,
        visibility = visibility,
        group = group,
        version = version,
        classifier = classifier,
    )

def java_gapic_grpc_gradle_pkg(
        name,
        group,
        version,
        deps,
        test_deps = None,
        visibility = None,
        classifier = ""):
    _java_gapic_gradle_pkg(
        name = name,
        pkg_type = "grpc",
        deps = deps + [
            "@io_grpc_grpc_protobuf//jar",
            "@io_grpc_grpc_stub//jar",
        ],
        test_deps = test_deps,
        visibility = visibility,
        group = group,
        version = version,
        classifier = classifier,
    )

def java_gapic_client_gradle_pkg(
        name,
        group,
        version,
        deps,
        test_deps = None,
        visibility = None,
        classifier = ""):
    _java_gapic_gradle_pkg(
        name = name,
        pkg_type = "client",
        deps = deps,
        test_deps = test_deps,
        visibility = visibility,
        group = group,
        version = version,
        classifier = classifier,
    )

def java_gapic_assembly_gradle_raw_pkg(name, deps, visibility = None):
    resource_target_name = "%s-resources" % name
    settings_tmpl_label = Label("//rules_gapic/java:resources/gradle/settings.gradle.tmpl")
    build_tmpl_label = Label("//rules_gapic/java:resources/gradle/assembly.gradle.tmpl")
    java_gapic_build_configs_pkg(
        name = resource_target_name,
        deps = deps,
        templates = {
            build_tmpl_label: "build.gradle",
            settings_tmpl_label: "settings.gradle",
        },
        dynamic_substitutions = {
            settings_tmpl_label: "construct_gradle_assembly_includes_subs",
        },
    )

    pkg_tar(
        name = name,
        extension = "tar.gz",
        deps = [
            Label("//rules_gapic/java:gradlew"),
            resource_target_name,
        ] + deps,
        package_dir = name,
        visibility = visibility,
    )

def java_gapic_assembly_gradle_pkg(
    name,
    client_group,
    version,
    client_deps,
    client_test_deps,
    grpc_group = None,
    proto_deps = None,
    grpc_deps = None,
    visibility = None):

    proto_target = "proto-%s" % name
    proto_target_dep = []
    grpc_target = "grpc-%s" % name
    grpc_target_dep = []
    client_target = "gapic-%s" % name

    if proto_deps:
        java_gapic_proto_gradle_pkg(
            name = proto_target,
            deps = proto_deps,
            group = grpc_group,
            version = version,
        )
        proto_target_dep = [":%s" % proto_target]

    if grpc_deps:
        java_gapic_grpc_gradle_pkg(
            name = grpc_target,
            deps = proto_target_dep + grpc_deps,
            group = grpc_group,
            version = version,
        )
        grpc_target_dep = ["%s" % grpc_target]

    java_gapic_client_gradle_pkg(
        name = client_target,
        deps = proto_target_dep + client_deps,
        test_deps = grpc_target_dep + client_test_deps,
        group = client_group,
        version = version,
    )

    java_gapic_assembly_gradle_raw_pkg(
        name = name,
        deps = proto_target_dep + grpc_target_dep + [":%s" % client_target]
    )

#
# Private helper functions
#
def _construct_package_dir_paths(attr_package_dir, out_pkg, label_name):
    if attr_package_dir:
        package_dir = attr_package_dir
        package_dir_expr = "../{}/*".format(package_dir)
    else:
        package_dir = label_name
        package_dir_expr = "./*"

    # We need to include label in the path to eliminate possible output files duplicates
    # (labels are guaranteed to be unique by bazel itself)
    package_dir_path = "%s/%s/%s" % (out_pkg.dirname, label_name, package_dir)
    return struct(
        package_dir = package_dir,
        package_dir_expr = package_dir_expr,
        package_dir_path = package_dir_path,
        package_dir_sibling_parent = out_pkg,
        package_dir_sibling_basename = label_name,
    )

def _java_gapic_gradle_pkg(
        name,
        pkg_type,
        deps,
        pkg_deps = [],
        visibility = None,
        test_deps = None,
        group = "",
        version = "",
        classifier = None):
    resource_target_name = "%s-resources" % name
    template_label = Label("//rules_gapic/java:resources/gradle/%s.gradle.tmpl" % pkg_type)
    java_gapic_build_configs_pkg(
        name = resource_target_name,
        deps = deps,
        test_deps = test_deps,
        package_dir = name,
        artifact_group_overrides = {
            "javax.annotation-api": "javax.annotation",
            "google-http-client": "com.google.http-client",
            "google-http-client-jackson2": "com.google.http-client",
        },
        templates = {
            template_label: "build.gradle",
        },
        static_substitutions = {
            "{{name}}": name,
            "{{group}}": group,
            "{{version}}": version,
        },
        dynamic_substitutions = {
            template_label: "construct_gradle_build_deps_subs",
        },
    )

    srcs_pkg_target_name = "%s-srcs_pkg" % name
    java_gapic_srcs_pkg(
        name = srcs_pkg_target_name,
        deps = deps,
        test_deps = test_deps,
        package_dir = name,
        visibility = visibility,
    )

    pkg_tar(
        name = name,
        extension = "tar.gz",
        deps = [
            resource_target_name,
            srcs_pkg_target_name,
        ] + pkg_deps,
        visibility = visibility,
    )
