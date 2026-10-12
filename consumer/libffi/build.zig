const std = @import("std");
const wasm_ffi = @import("wasm-libffi.zig");

const Backend = enum { lua, luajit };

pub fn build(b: *std.Build) !void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "Lua runtime") orelse .lua;
    const linkage = b.option(std.lang.LinkMode, "linkage", "Native library linkage") orelse .static;

    const is_wasm = target.result.cpu.arch.isWasm();
    if (is_wasm and backend == .luajit) {
        // zlua owns the backend rejection, before the lazy libffi fetch.
        _ = b.dependency("zlua", .{
            .target = target,
            .optimize = optimize,
            .backend = backend,
            .linkage = linkage,
        });
        unreachable;
    }
    if (target.result.cpu.arch == .wasm32 and target.result.os.tag == .emscripten) {
        var query = target.query;
        const exceptions = @backingInt(std.Target.wasm.Feature.exception_handling);
        query.cpu_features_add.addFeature(exceptions);
        query.cpu_features_sub.removeFeature(exceptions);
        target = b.resolveTargetQuery(query);
        try buildWasm(b, target, optimize, linkage);
        return;
    }
    // Reject unsupported targets before resolving the lazy libffi dependency.
    if (!supportedTarget(target.result)) {
        std.debug.panic(
            "zlua libffi: unsupported target {s}-{s}-{s}; " ++
                "requires a supported desktop C ABI or wasm32-emscripten (not WASI)",
            .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) },
        );
    }
    const lua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .linkage = linkage,
    });
    const ffi_dep = try b.dependencyLazy("libffi", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("zlua", lua_dep.module("zlua"));
    module.addImport("ffi", ffi_dep.module("ffi"));
    module.linkLibrary(ffi_dep.artifact("ffi"));
    module.addCSourceFile(.{ .file = b.path("src/native.c"), .flags = &.{"-std=c11"} });

    const executable = b.addExecutable(.{ .name = "zlua-libffi-smoke", .root_module = module });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(executable);
    const test_run = b.addRunArtifact(tests);
    run.skip_foreign_checks = false;
    test_run.skip_foreign_checks = false;
    b.step("run", "Run the native Lua/libffi smoke scenario").dependOn(&run.step);
    b.step("test", "Run native Lua/libffi integration tests").dependOn(&test_run.step);
    const check = b.step("check", "Compile executable and tests without running (cross-target safe)");
    check.dependOn(&executable.step);
    check.dependOn(&tests.step);
    b.default_step.dependOn(check);
}

fn buildWasm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, linkage: std.lang.LinkMode) !void {
    const emscripten = (b.lazyImport(@This(), "zlua") orelse return).emscripten;
    if (linkage != .static)
        @panic("zlua libffi wasm: only -Dlinkage=static is supported");
    const sysroot = b.option([]const u8, "emscripten-sysroot", "Installed Emscripten sysroot (same SDK/cache used by emcc)") orelse
        @panic("zlua libffi wasm: -Demscripten-sysroot=/absolute/path/to/sysroot is required");
    const emcc = b.option([]const u8, "emcc", "Emscripten compiler executable") orelse "emcc";
    const node = b.option([]const u8, "node", "Node.js executable") orelse "node";
    const lua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .backend = .lua,
        .linkage = .static,
        .@"emscripten-sysroot" = sysroot,
    });
    // Upstream's build lacks a wasm selector. Resolve a supported graph solely
    // to access the immutable package; no host artifact or headers are linked.
    const ffi_dep = try b.dependencyLazy("libffi", .{
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }),
        .optimize = optimize,
        .linkage = .static,
    });
    const ffi = wasm_ffi.create(b, emscripten, ffi_dep, target, optimize, sysroot);
    const module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("zlua", lua_dep.module("zlua"));
    module.addImport("ffi", ffi.module);
    module.linkLibrary(ffi.library);
    module.addCSourceFile(.{ .file = b.path("src/native.c"), .flags = &.{"-std=c11"} });
    emscripten.addIncludes(b, module, sysroot);
    const library = b.addLibrary(.{
        .name = "zlua-libffi-wasm-scenario",
        .linkage = .static,
        .root_module = module,
    });
    library.bundle_compiler_rt = true;
    const link = b.addSystemCommand(&.{emcc});
    link.addArtifactArg(library);
    emscripten.addLuaArchive(link, lua_dep);
    link.addArtifactArg(ffi.library);
    emscripten.addLinkFlags(link, optimize);
    // libffi's EM_JS dependencies dynamically create executable table entries.
    // Upstream EM_JS also uses stack helpers without declaring their JS deps.
    // Emscripten 6 no longer includes these implicitly. BigInt is now default.
    link.addArgs(&.{
        "-sALLOW_TABLE_GROWTH=1",
        "-sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE=['$stackSave','$stackRestore','$stackAlloc']",
        "-sEXPORTED_FUNCTIONS=['_zluaFfiWasmScenario','_malloc','_free']",
        "-o",
    });
    const javascript = link.addOutputFileArg("zlua-libffi-wasm.js");
    const check = b.step("check", "Compile and link Lua/libffi wasm with emcc");
    check.dependOn(&link.step);
    b.default_step.dependOn(check);
    const execute = b.addSystemCommand(&.{node});
    execute.addFileArg(b.path("src/run.cjs"));
    execute.addFileArg(javascript);
    b.step("run", "Run real Lua/libffi wasm functions and callbacks").dependOn(&execute.step);
    b.step("test", "Run the shared Lua/libffi scenario in wasm").dependOn(&execute.step);
}

fn supportedTarget(target: std.Target) bool {
    // These desktop combinations use sources and ABI declarations provided by the pin.
    // In particular, its ARM Windows assembly cannot be built with Zig's GNU tooling.
    return switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            .x86, .x86_64, .aarch64, .riscv64 => true,
            else => false,
        },
        .macos, .freebsd, .netbsd, .openbsd => switch (target.cpu.arch) {
            .x86, .x86_64, .aarch64 => true,
            else => false,
        },
        .dragonfly => target.cpu.arch == .x86_64,
        .windows => (target.cpu.arch == .x86 or target.cpu.arch == .x86_64) and
            target.abi == .gnu,
        else => false,
    };
}
