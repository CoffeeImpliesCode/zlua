const std = @import("std");
const zlua = @import("zlua");
const ffi = @import("ffi");
const c = zlua.c;

extern fn zlua_ffi_signed(i32, i32) callconv(.c) i32;
extern fn zlua_ffi_mixed(i32, f64, i32, f64) callconv(.c) f64;
extern fn zlua_ffi_signed64(i64, i64) callconv(.c) i64;
const LuaFunction = fn (?*c.lua_State) callconv(.c) c_int;

const Context = struct {
    signed_cif: ffi.Function = undefined,
    mixed_cif: ffi.Function = undefined,
    closure_cif: ffi.Function = undefined,
    signed_types: [2]*ffi.Type = .{ ffi.types.sint32, ffi.types.sint32 },
    mixed_types: [4]*ffi.Type = .{
        ffi.types.sint32, ffi.types.double, ffi.types.sint32, ffi.types.double,
    },
    closure_types: [1]*ffi.Type = .{ffi.types.pointer},
    signed_calls: usize = 0,
    mixed_calls: usize = 0,
    closure_calls: usize = 0,
    rejected_calls: usize = 0,
    bias: i32 = -40,

    fn prepare(self: *Context) !void {
        try self.signed_cif.prepare(.default(), 2, &self.signed_types, ffi.types.sint32);
        try self.mixed_cif.prepare(.default(), 4, &self.mixed_types, ffi.types.double);
        try self.closure_cif.prepare(.default(), 1, &self.closure_types, ffi.types.sint);
    }
};

pub fn run() !void {
    // CIFs refer to their argument arrays; initialize in place and never move the context.
    var context: Context = .{};
    try context.prepare();
    // This probe never enters a Lua double: both inputs and the result exceed
    // its exact integer range. Keep an eight-byte result even on wasm32.
    {
        var types = [_]*ffi.Type{ ffi.types.sint64, ffi.types.sint64 };
        var cif: ffi.Function = undefined;
        try cif.prepare(.default(), 2, &types, ffi.types.sint64);
        var left: i64 = -9007199254740993;
        var right: i64 = -9007199254740995;
        var args = [_]*anyopaque{ @ptrCast(&left), @ptrCast(&right) };
        var result: i64 = 0;
        cif.call(&zlua_ffi_signed64, &args, &result);
        try expect(result == -27021597764222981);
    }
    const code = try ffi.Closure.allocCode(LuaFunction);
    defer code.free();
    try code.prepare(&context.closure_cif, closureCallback, &context);

    // Reverse defer order closes Lua before releasing its executable callback or userdata.
    var state = try zlua.State.initWithLibraries();
    defer state.deinit();
    if (!state.checkStack(8)) return error.StackUnavailable;
    register(&state, "ffi_signed", signedCallback, &context);
    register(&state, "ffi_mixed", mixedCallback, &context);
    c.lua_pushcclosure(state.handle(), code.trampoline, 0);
    c.lua_setglobal(state.handle(), "ffi_closure");

    state.pushNumber(123);
    try state.run(@embedFile("scenario.lua"), "@libffi/scenario.lua", 3);
    try expect(state.top() == 4);
    try expect(state.toNumber(1) == 123);
    try expect(state.toNumber(2) == -47);
    try expect(state.toNumber(3) == -9.75);
    try expect(state.toNumber(4) == -42);
    state.setTop(1);

    // The error originates in Lua after real ffi calls. The stack prefix survives.
    const failure = state.run(
        "assert(ffi_signed(-17, 4) == -47); error('ffi recovery marker')",
        "@libffi/error.lua",
        0,
    );
    if (failure) |_| {
        return error.MissingRuntimeError;
    } else |err| {
        if (err != error.RuntimeError) return err;
    }
    try expect(state.top() == 2);
    const message = state.toBytes(-1) orelse return error.MissingErrorMessage;
    try expect(std.mem.indexOf(u8, message, "ffi recovery marker") != null);
    state.pop(1);
    try state.run(
        "return ffi_signed(-17, 4), ffi_mixed(-7, 1.5, 3, 0.25), ffi_closure(2, -4)",
        "@libffi/recovered.lua",
        3,
    );
    try expect(state.top() == 4);
    try expect(state.toNumber(1) == 123);
    try expect(state.toNumber(2) == -47);
    try expect(state.toNumber(3) == -9.75);
    try expect(state.toNumber(4) == -42);
    try expect(context.signed_calls == 3);
    try expect(context.mixed_calls == 2);
    try expect(context.closure_calls == 2);
    try expect(context.rejected_calls == 3);
    try @import("roundtrip.zig").run();
}

fn expect(condition: bool) error{ScenarioMismatch}!void {
    if (!condition) return error.ScenarioMismatch;
}

fn register(state: *zlua.State, name: [*:0]const u8, function: *const LuaFunction, context: *Context) void {
    c.lua_pushlightuserdata(state.handle(), context);
    c.lua_pushcclosure(state.handle(), function, 1);
    c.lua_setglobal(state.handle(), name);
}

fn upvalue(raw: *c.lua_State) *Context {
    return @ptrCast(@alignCast(c.lua_touserdata(raw, c.lua_upvalueindex(1)).?));
}

fn number(raw: *c.lua_State, index: c_int) ?f64 {
    if (c.lua_type(raw, index) != c.LUA_TNUMBER) return null;
    const value = if (comptime zlua.backend == .lua)
        c.lua_tonumberx(raw, index, null)
    else
        c.lua_tonumber(raw, index);
    if (!std.math.isFinite(value) or @abs(value) > 1000) return null;
    return value;
}

fn integer(raw: *c.lua_State, index: c_int) ?i32 {
    const value = number(raw, index) orelse return null;
    if (@trunc(value) != value) return null;
    return @intFromFloat(value);
}

fn reject(raw: *c.lua_State, context: *Context) c_int {
    context.rejected_calls += 1;
    // Return an error pair instead of longjmp across a live libffi trampoline frame.
    c.lua_pushnil(raw);
    _ = c.lua_pushstring(raw, "ffi arguments must be finite numbers (integers where required)");
    return 2;
}

fn signedCallback(optional_raw: ?*c.lua_State) callconv(.c) c_int {
    const raw = optional_raw.?;
    const context = upvalue(raw);
    if (c.lua_gettop(raw) != 2) return reject(raw, context);
    var left = integer(raw, 1) orelse return reject(raw, context);
    var right = integer(raw, 2) orelse return reject(raw, context);
    var args = [_]*anyopaque{ @ptrCast(&left), @ptrCast(&right) };
    // libffi widens integral returns smaller than ffi_arg; reserve a full signed word.
    var result: ffi.sarg = 0;
    context.signed_cif.call(&zlua_ffi_signed, &args, &result);
    context.signed_calls += 1;
    c.lua_pushnumber(raw, @floatFromInt(result));
    return 1;
}

fn mixedCallback(optional_raw: ?*c.lua_State) callconv(.c) c_int {
    const raw = optional_raw.?;
    const context = upvalue(raw);
    if (c.lua_gettop(raw) != 4) return reject(raw, context);
    var left = integer(raw, 1) orelse return reject(raw, context);
    var scale = number(raw, 2) orelse return reject(raw, context);
    var right = integer(raw, 3) orelse return reject(raw, context);
    var offset = number(raw, 4) orelse return reject(raw, context);
    var args = [_]*anyopaque{
        @ptrCast(&left), @ptrCast(&scale), @ptrCast(&right), @ptrCast(&offset),
    };
    var result: f64 = 0;
    context.mixed_cif.call(&zlua_ffi_mixed, &args, &result);
    context.mixed_calls += 1;
    c.lua_pushnumber(raw, result);
    return 1;
}

fn closureCallback(_: *ffi.Function, result: *anyopaque, args: ?[*]*anyopaque, datum: ?*anyopaque) callconv(.c) void {
    const raw = (@as(*const ?*c.lua_State, @ptrCast(@alignCast(args.?[0]))).*).?;
    const context: *Context = @ptrCast(@alignCast(datum.?));
    // Closure storage follows the declared type (riscv allocates rtype->size).
    // Unlike ffi_call's promoted result buffer, this callback writes exactly C int.
    const output: *c_int = @ptrCast(@alignCast(result));
    if (c.lua_gettop(raw) != 2) {
        output.* = reject(raw, context);
        return;
    }
    const left = integer(raw, 1) orelse {
        output.* = reject(raw, context);
        return;
    };
    const right = integer(raw, 2) orelse {
        output.* = reject(raw, context);
        return;
    };
    context.closure_calls += 1;
    c.lua_pushnumber(raw, @floatFromInt(context.bias + left + right));
    output.* = 1;
}
