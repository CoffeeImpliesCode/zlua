const std = @import("std");
const zlua = @import("zlua");

extern "c" fn zlua_conformance_newstate() ?*zlua.c.lua_State;
extern "c" fn zlua_conformance_openlibs(raw: *zlua.c.lua_State) c_int;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedPinnedInterpreterPath;
    var state: zlua.State = .{ .sdk = .{
        .raw = zlua_conformance_newstate() orelse return error.OutOfMemory,
    } };
    defer state.deinit();
    if (zlua_conformance_openlibs(state.handle()) != zlua.c.LUA_OK) {
        std.log.err("opening official test libraries: {s}", .{state.toBytes(-1) orelse "non-string Lua error"});
        return error.TestLibrariesFailed;
    }
    state.pushBytes(args[1]);
    state.setGlobal("conformance_cli");
    state.run(@embedFile("suite.lua"), "@zlua-conformance", 0) catch |err| {
        std.log.err("official suite: {s}", .{state.toBytes(-1) orelse "non-string Lua error"});
        return err;
    };
}
