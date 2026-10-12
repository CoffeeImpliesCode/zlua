const std = @import("std");
pub const emscripten = @import("consumer/wasm/emscripten.zig");

const Backend = enum { lua, luajit };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "Lua runtime: lua (default) or luajit") orelse .lua;
    const linkage = b.option(
        std.lang.LinkMode,
        "linkage",
        "Native library linkage: static (default) or dynamic",
    ) orelse .static;

    if (target.result.os.tag == .wasi) {
        std.debug.panic("zlua: unsupported target: WASI is not supported", .{});
    }
    if (backend == .luajit and target.result.cpu.arch == .riscv64) {
        std.debug.panic("zlua: unsupported target: LuaJIT does not support riscv64", .{});
    }
    if (backend == .luajit) {
        switch (target.result.cpu.arch) {
            .wasm32, .wasm64 => std.debug.panic(
                "zlua: unsupported target: LuaJIT does not support WebAssembly (wasm32 or wasm64)",
                .{},
            ),
            else => {},
        }
    }
    const emscripten_sysroot = b.option(
        []const u8,
        "emscripten-sysroot",
        "Installed Emscripten sysroot for the Lua wasm consumer",
    );

    const dependency_name = @tagName(backend);
    const dependency = try switch (backend) {
        .lua => b.dependencyLazy("lua", .{
            .target = target,
            .optimize = optimize,
            .linkage = linkage,
        }),
        .luajit => b.dependencyLazy("luajit", .{
            .target = target,
            .optimize = optimize,
            .linkage = linkage,
        }),
    };
    if (emscripten_sysroot) |sysroot| {
        if (target.result.os.tag == .emscripten and backend == .lua) {
            const include: std.Build.LazyPath = .{
                .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
            };
            const native_module = dependency.module("lua");
            const archive = archive: {
                for (native_module.link_objects.items) |object| {
                    switch (object) {
                        .other_step => |artifact| {
                            if (artifact.kind == .lib) break :archive artifact;
                        },
                        else => {},
                    }
                }
                @panic("zlua: Lua SDK module has no attached library artifact");
            };
            native_module.addSystemIncludePath(include);
            archive.root_module.addSystemIncludePath(include);

            // TranslateC has no libc-file option. Use the SDK's
            // existing translation step; never duplicate its C source graph.
            const bindings = native_module.import_table.get("c") orelse unreachable;
            const generated = bindings.root_source_file.?.generated;
            const translate = b.graph.generated_files.items[@backingInt(generated.index)].cast(std.Build.Step.TranslateC).?;
            translate.addSystemIncludePath(include);

            // emcc cannot rewrite setjmp in precompiled wasm objects. Compile
            // Lua's existing source list with native wasm SjLj/EH instead.
            const flags: []const []const u8 = &.{
                "-mexception-handling", "-mllvm", "-wasm-enable-sjlj",
            };
            for (archive.root_module.link_objects.items) |object| {
                switch (object) {
                    .c_source_files => |sources| {
                        sources.flags = std.mem.concat(
                            b.allocator,
                            []const u8,
                            &.{ sources.flags, flags },
                        ) catch @panic("OOM");
                    },
                    .c_source_file => |source| {
                        source.flags = std.mem.concat(
                            b.allocator,
                            []const u8,
                            &.{ source.flags, flags },
                        ) catch @panic("OOM");
                    },
                    else => {},
                }
            }
        }
    }

    const options = b.addOptions();
    options.addOption(Backend, "backend", backend);
    const module = b.addModule("zlua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    module.addImport("native", dependency.module(dependency_name));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zlua", .module = module }},
        }),
    });
    const smoke = b.addExecutable(.{
        .name = "zlua-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zlua", .module = module }},
        }),
    });

    const check = b.step("check", "Compile tests and smoke for the selected target without running");
    check.dependOn(&tests.step);
    check.dependOn(&smoke.step);
    b.default_step.dependOn(check);

    const test_step = b.step("test", "Run the selected backend's shared and native API tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const smoke_step = b.step("smoke", "Run the selected backend's smoke executable");
    smoke_step.dependOn(&b.addRunArtifact(smoke).step);
}
