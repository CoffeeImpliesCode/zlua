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

pub fn addLinkFlags(link: *std.Build.Step.Run, optimize: std.builtin.OptimizeMode) void {
    link.addArgs(&.{
        "--no-entry",              "-mexception-handling", "-sSUPPORT_LONGJMP=wasm",
        "-sALLOW_MEMORY_GROWTH=1", "-sMODULARIZE=1",       "-sEXPORT_NAME=createZlua",
        "-sENVIRONMENT=node",      "-sSTACK_SIZE=1048576",
    });
    switch (optimize) {
        // Preserve Zig's safety-enabled C checks and provide their runtime.
        // -g2 avoids Binaryen 132's unsupported DW_LNE_define_file metadata.
        .Debug => link.addArgs(&.{
            "-O0", "-g2", "-fsanitize=undefined", "-sASSERTIONS=2", "-sSTACK_OVERFLOW_CHECK=2",
        }),
        .ReleaseSafe => link.addArgs(&.{
            "-O2", "-fsanitize=undefined", "-sASSERTIONS=1", "-sSTACK_OVERFLOW_CHECK=2",
        }),
        .ReleaseFast => link.addArg("-O3"),
        .ReleaseSmall => link.addArg("-Oz"),
    }
}

pub fn prepareZigLib(b: *std.Build) std.Build.LazyPath {
    // Zig 0.16's STOPSIG constructs SIG but incorrectly declares a u32 result.
    // Patch only a private build-cache copy; never change the installed library.
    const relative_path = b.pathJoin(&.{ "std", "os", "emscripten.zig" });
    const source = b.graph.zig_lib_directory;
    const contents = source.handle.readFileAlloc(
        b.graph.io,
        relative_path,
        b.allocator,
        .limited(1 << 24),
    ) catch @panic("zlua wasm: cannot read Zig Emscripten standard library");
    const needle = "    pub fn STOPSIG(s: u32) u32 {";
    if (std.mem.count(u8, contents, needle) != 1)
        @panic("zlua wasm: Zig 0.16 Emscripten STOPSIG patch target changed");
    const patched = std.mem.replaceOwned(
        u8,
        b.allocator,
        contents,
        needle,
        "    pub fn STOPSIG(s: u32) SIG {",
    ) catch @panic("OOM");
    const files = b.addWriteFiles();
    // Directory walkers use the host separator; match the same native path
    // so the original file cannot overwrite the patched file on Windows.
    const directory = files.addCopyDirectory(
        .{ .cwd_relative = source.path orelse "." },
        "",
        .{ .exclude_extensions = &.{relative_path} },
    );
    _ = files.add(relative_path, patched);
    return directory;
}
