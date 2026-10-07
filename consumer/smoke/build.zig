const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(enum { lua, luajit }, "backend", "Lua runtime backend") orelse .lua;
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Native library linkage") orelse .static;
    const dependency = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .linkage = linkage,
    });
    const executable = b.addExecutable(.{
        .name = "zlua-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zlua", .module = dependency.module("zlua") }},
        }),
    });
    const check = b.step("check", "Compile consumer without executing it");
    check.dependOn(&executable.step);
    b.default_step.dependOn(check);
    const run = b.addRunArtifact(executable);
    b.step("run", "Execute consumer against its selected real Lua runtime").dependOn(&run.step);
}
