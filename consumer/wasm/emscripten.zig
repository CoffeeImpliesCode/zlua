const std = @import("std");

pub fn target(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
    });
}

pub fn addIncludes(b: *std.Build, module: *std.Build.Module, sysroot: []const u8) void {
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) });
}

pub fn addLuaArchive(link: *std.Build.Step.Run, dependency: *std.Build.Dependency) void {
    // Reuse exactly the SDK artifact already linked by zlua's native module.
    const native = dependency.module("zlua").import_table.get("native").?;
    for (native.link_objects.items) |object| {
        switch (object) {
            .other_step => |artifact| if (artifact.kind == .lib) link.addArtifactArg(artifact),
            else => {},
        }
    }
}

pub fn addLinkFlags(link: *std.Build.Step.Run, optimize: std.lang.Optimize) void {
    link.addArgs(&.{
        "--no-entry",              "-mexception-handling", "-sSUPPORT_LONGJMP=wasm",
        "-sALLOW_MEMORY_GROWTH=1", "-sMODULARIZE=1",       "-sEXPORT_NAME=createZlua",
        "-sENVIRONMENT=node",      "-sSTACK_SIZE=1048576",
    });
    switch (optimize) {
        // Preserve Zig's safety-enabled C checks and provide their runtime.
        // -g2 avoids Binaryen 132's unsupported DW_LNE_define_file metadata.
        .debug => link.addArgs(&.{
            "-O0", "-g2", "-fsanitize=undefined", "-sASSERTIONS=2", "-sSTACK_OVERFLOW_CHECK=2",
        }),
        .safe => link.addArgs(&.{
            "-O2", "-fsanitize=undefined", "-sASSERTIONS=1", "-sSTACK_OVERFLOW_CHECK=2",
        }),
        .fast => link.addArg("-O3"),
        .small => link.addArg("-Oz"),
    }
}
