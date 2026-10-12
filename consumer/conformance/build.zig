const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(std.lang.LinkMode, "linkage", "Instrumented Lua linkage") orelse .static;
    const backend = b.option(enum { lua, luajit }, "backend", "Official suite runtime (Lua only)") orelse .lua;
    if (backend != .lua) @panic("conformance: the official Lua 5.5.1 suite cannot run on LuaJIT");
    if (target.result.os.tag != .linux) @panic("conformance: full official tests require Linux, POSIX shell, and ELF .so fixtures");

    // Lazy resolution keeps rejected backends/targets from fetching the suite.
    const suite = try b.dependencyLazy("lua_tests", .{});
    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .backend = .lua,
        .linkage = linkage,
    });
    const zlua_module = zlua_dep.module("zlua");
    const sdk = try zlua_dep.builder.dependencyLazy("lua", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
    });
    const native = zlua_module.import_table.get("native").?;
    const archive = libraryArtifact(native);
    const cli = interpreterArtifact(sdk.builder);
    const headers = sdk.path("src");
    const test_headers = suite.path("ltests");

    instrument(archive.root_module, test_headers);
    instrument(cli.root_module, test_headers);
    archive.root_module.addCSourceFile(.{
        .file = suite.path("ltests/ltests.c"),
        .flags = &.{"-std=gnu99"},
    });
    if (linkage == .dynamic) {
        // Extend the SDK's ELF public export map only for official T entrypoints.
        const exports = b.addWriteFiles();
        archive.setVersionScript(exports.add("lua-conformance.map",
            \\LUA_5_5 {
            \\  global:
            \\    lua_*;
            \\    luaL_*;
            \\    luaopen_*;
            \\    debug_realloc;
            \\    l_memcontrol;
            \\    luaB_opentests;
            \\  local:
            \\    *;
            \\};
            \\
        ));
    }
    configureTemporaryNames(b, archive.root_module);
    configureTemporaryNames(b, cli.root_module);
    const bindings = native.import_table.get("c").?;
    const translation_step = b.graph.generated_files.items[@backingInt(bindings.root_source_file.?.generated.index)];
    const translation = translation_step.cast(std.Build.Step.TranslateC).?;
    translation.addIncludePath(test_headers);
    translation.defineCMacro("LUA_USER_H", "\"ltests.h\"");
    // Do not translate luaL_newstate's allocator macro into an SDK replacement.
    translation.source = b.path("src/translate.h");

    const executable = b.addExecutable(.{
        .name = "zlua-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zlua", .module = zlua_module }},
        }),
    });
    executable.rdynamic = true;
    executable.root_module.addIncludePath(headers);
    instrument(executable.root_module, test_headers);
    executable.root_module.addCMacro("LUA_USE_LINUX", "1");
    executable.root_module.addCSourceFile(.{ .file = b.path("src/bridge.c"), .flags = &.{"-std=gnu99"} });

    const staged = b.addWriteFiles();
    _ = staged.addCopyDirectory(suite.path(""), "", .{});
    const check = b.step("check", "Compile instrumented wrapper, pinned interpreter, and all five official C fixtures");
    check.dependOn(&executable.step);
    check.dependOn(&cli.step);
    const fixtures = [_][2][]const u8{
        .{ "lib1", "lib1.c" },     .{ "lib11", "lib11.c" },
        .{ "lib2", "lib2.c" },     .{ "lib21", "lib21.c" },
        .{ "lib2-v2", "lib22.c" },
    };
    for (fixtures) |fixture| {
        const library = b.addLibrary(.{
            .name = fixture[0],
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = .fast,
                .link_libc = true,
                .pic = true,
            }),
        });
        library.root_module.addIncludePath(headers);
        instrument(library.root_module, test_headers);
        library.root_module.addCMacro("LUA_USE_LINUX", "1");
        library.root_module.addCSourceFile(.{
            .file = suite.path(b.fmt("libs/{s}", .{fixture[1]})),
            .flags = &.{ "-std=gnu99", "-Wall" },
        });
        library.linker_allow_shlib_undefined = true;
        _ = staged.addCopyFile(library.getEmittedBin(), b.fmt("libs/{s}.so", .{fixture[0]}));
        check.dependOn(&library.step);
    }
    b.default_step.dependOn(check);

    // A real interpreter preflight uses Zig's standard foreign-execution guard.
    // The full suite also spawns this exact CLI itself through POSIX shell.
    const preflight = b.addRunArtifact(cli);
    clearLuaEnvironment(preflight);
    preflight.addArgs(&.{ "-e", "assert(_VERSION == 'Lua 5.5' and type(T) == 'table' and T.testC); assert(os.setlocale('pt_BR') or os.setlocale('ptb'), 'full suite requires pt_BR locale'); assert(os.setlocale('C'))" });
    const run = b.addSystemCommand(&.{"bash"});
    clearLuaEnvironment(run);
    run.addFileArg(b.path("src/run.sh"));
    run.addArtifactArg(executable);
    run.step.dependOn(&preflight.step);
    run.addDirectoryArg(staged.getDirectory());
    run.addArtifactArg(cli);
    b.step("run", "Run the entire untouched official suite with strict success and no-skip oracle").dependOn(&run.step);
}

fn instrument(module: *std.Build.Module, headers: std.Build.LazyPath) void {
    module.addIncludePath(headers);
    module.addCMacro("LUA_USER_H", "\"ltests.h\"");
}

fn clearLuaEnvironment(run: *std.Build.Step.Run) void {
    for ([_][]const u8{
        "LUA_INIT", "LUA_INIT_5_5", "LUA_PATH", "LUA_PATH_5_5", "LUA_CPATH", "LUA_CPATH_5_5",
        "BASH_ENV", "ENV",
    }) |name| run.removeEnvironmentVariable(name);
}

fn configureTemporaryNames(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src"));
    // run.sh enters a fresh approved scratch directory before any suite code.
    // Leaf names preserve the CLI -l module-name tests (hyphens mean versions).
    module.addCMacro("LUA_TMPNAMTEMPLATE", "\"lua_XXXXXX\"");
    const header = b.root.joinString(b.allocator, "src/tempnam.h") catch @panic("OOM");
    const flags: []const []const u8 = &.{ "-include", header };
    for (module.link_objects.items) |object| switch (object) {
        .c_source_files => |sources| {
            sources.flags = std.mem.concat(b.allocator, []const u8, &.{ sources.flags, flags }) catch @panic("OOM");
        },
        .c_source_file => |source| {
            source.flags = std.mem.concat(b.allocator, []const u8, &.{ source.flags, flags }) catch @panic("OOM");
        },
        else => {},
    };
}

fn libraryArtifact(module: *std.Build.Module) *std.Build.Step.Compile {
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |artifact| if (artifact.kind == .lib) return artifact,
        else => {},
    };
    @panic("conformance: pinned SDK module has no library artifact");
}

fn interpreterArtifact(builder: *std.Build) *std.Build.Step.Compile {
    for (builder.getInstallStep().dependencies.items) |step| {
        if (step.cast(std.Build.Step.InstallArtifact)) |install| {
            if (install.artifact.kind == .exe and std.mem.eql(u8, install.artifact.name, "lua")) return install.artifact;
        }
    }
    @panic("conformance: pinned SDK has no installed Lua interpreter artifact");
}
