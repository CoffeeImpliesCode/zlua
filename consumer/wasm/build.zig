const std = @import("std");

pub fn build(b: *std.Build) void {
    const emscripten = b.lazyImport(@This(), "zlua").?.emscripten;
    const optimize = b.standardOptimizeOption(.{});
    const sysroot = b.option(
        []const u8,
        "emscripten-sysroot",
        "Installed Emscripten sysroot (same SDK/cache used by emcc)",
    ) orelse @panic("zlua wasm: -Demscripten-sysroot=/absolute/path/to/sysroot is required");
    const emcc = b.option([]const u8, "emcc", "Emscripten compiler executable") orelse "emcc";
    const node = b.option([]const u8, "node", "Node.js executable") orelse "node";
    const target = emscripten.target(b);
    const dependency = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .backend = .lua,
        .linkage = .static,
        .@"emscripten-sysroot" = sysroot,
    });
    const library = b.addLibrary(.{
        .name = "zlua-wasm-scenario",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zlua", .module = dependency.module("zlua") }},
        }),
    });
    library.bundle_compiler_rt = true;
    emscripten.addIncludes(b, library.root_module, sysroot);
    const link = b.addSystemCommand(&.{emcc});
    link.addArtifactArg(library);
    emscripten.addLuaArchive(link, dependency);
    emscripten.addLinkFlags(link, optimize);
    link.addArg("-sEXPORTED_FUNCTIONS=['_zluaWasmScenario']");
    link.addArg("-o");
    // Keep JS and its neighboring wasm in the build cache, not zig-out.
    const javascript = link.addOutputFileArg("zlua-wasm.js");
    const check = b.step("check", "Compile and link the real Lua wasm consumer with emcc");
    check.dependOn(&link.step);
    b.default_step.dependOn(check);
    const execute = b.addSystemCommand(&.{node});
    execute.addFileArg(b.path("src/run.cjs"));
    execute.addFileArg(javascript);
    const run = b.step("run", "Execute detailed Lua semantics in wasm using Node.js");
    run.dependOn(&execute.step);
}
