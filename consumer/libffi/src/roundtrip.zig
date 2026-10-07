const std = @import("std");
const zlua = @import("zlua");
const ffi = @import("ffi");
const c = zlua.c;
const Callback = fn (?*anyopaque, i32, f64) callconv(.c) f64;
const Mixed = fn (i32, f64, i32, f64) callconv(.c) f64;
extern fn zlua_ffi_signed(i32, i32) callconv(.c) i32;
extern fn zlua_ffi_mixed(i32, f64, i32, f64) callconv(.c) f64;
extern fn zlua_ffi_get_mixed() callconv(.c) *const Mixed;

const Context = struct {
    raw: *c.lua_State = undefined,
    reference: c_int = undefined,
    cif: ffi.Function = undefined,
    types: [3]*ffi.Type = .{ ffi.types.pointer, ffi.types.sint32, ffi.types.double },
    code: *const Callback = undefined,
    calls: usize = 0,
    errors: usize = 0,
    dispatches: usize = 0,
    pointer_mismatches: usize = 0,
    error_marker: bool = false,
    total: f64 = 0,
};

pub fn run() !void {
    // Keep the CIF, its type array, callback userdata and executable memory stable.
    var context: Context = .{};
    try context.cif.prepare(.default(), 3, &context.types, ffi.types.double);
    const code = try ffi.Closure.allocCode(Callback);
    defer code.free();
    context.code = code.trampoline;
    try code.prepare(&context.cif, callback, &context);
    var state = try zlua.State.initWithLibraries();
    defer state.deinit(); // Lua finalizers run before closure/userdata are released.
    context.raw = state.handle();
    if (!state.checkStack(16)) return error.StackUnavailable;
    try state.run(
        "return function(a,b) if a == 999 then error('protected bridge error') end " ++
            "if bridge_nested then return bridge_nested(a,b) end return a*3+b-40 end",
        "@libffi/bridge-body.lua",
        1,
    );
    context.reference = c.luaL_ref(context.raw, c.LUA_REGISTRYINDEX);
    defer c.luaL_unref(context.raw, c.LUA_REGISTRYINDEX, context.reference);
    c.lua_pushlightuserdata(context.raw, &context);
    c.lua_pushcclosure(context.raw, invoke, 1);
    c.lua_setglobal(context.raw, "ffi_bridge");
    try state.run(@embedFile("bridge-tests.lua"), "@libffi/bridge-tests.lua", 0);
    try expect(state.top() == 0);
    try expect(context.calls == 4 and context.errors == 1 and context.error_marker);
    try expect(context.total == -135.25);

    if (comptime zlua.backend == .luajit) {
        pointer(&state, "bridge_context", &context);
        pointer(&state, "bridge_code", code.trampoline);
        pointer(&state, "bridge_dispatch", &dispatch);
        pointer(&state, "bridge_return", &returnCallback);
        pointer(&state, "bridge_factory", &zlua_ffi_get_mixed);
        pointer(&state, "bridge_signed", &zlua_ffi_signed);
        pointer(&state, "bridge_mixed", &zlua_ffi_mixed);
        try state.run(@embedFile("luajit-roundtrip.lua"), "@libffi/luajit-roundtrip.lua", 2);
        try expect(state.top() == 2);
        try expect(state.toNumber(1) == 3 and state.toNumber(2) == 1);
        state.setTop(0);
        try expect(context.calls == 6 and context.errors == 1);
        try expect(context.dispatches == 4);
        try expect(context.total == -197.25);
    }
    try expect(context.pointer_mismatches == 0);
}

fn expect(ok: bool) error{RoundTripMismatch}!void {
    if (!ok) return error.RoundTripMismatch;
}

fn pointer(state: *zlua.State, name: [*:0]const u8, value: anytype) void {
    const address: *const anyopaque = @ptrCast(value);
    c.lua_pushlightuserdata(state.handle(), @constCast(address));
    c.lua_setglobal(state.handle(), name);
}

fn callback(_: *ffi.Function, result: *anyopaque, args: ?[*]*anyopaque, datum: ?*anyopaque) callconv(.c) void {
    const context: *Context = @ptrCast(@alignCast(datum.?));
    const output: *f64 = @ptrCast(@alignCast(result));
    output.* = 0;
    const passed_context = @as(*const ?*anyopaque, @ptrCast(@alignCast(args.?[0]))).*;
    if (passed_context != datum) {
        context.pointer_mismatches += 1;
        return;
    }
    const left = @as(*const i32, @ptrCast(@alignCast(args.?[1]))).*;
    const right = @as(*const f64, @ptrCast(@alignCast(args.?[2]))).*;
    const raw = context.raw;
    const top = c.lua_gettop(raw);
    defer c.lua_settop(raw, top);
    context.calls += 1;
    if (c.lua_checkstack(raw, 4) == 0) {
        context.errors += 1;
        return;
    }
    _ = c.lua_rawgeti(raw, c.LUA_REGISTRYINDEX, context.reference);
    c.lua_pushnumber(raw, @floatFromInt(left));
    c.lua_pushnumber(raw, right);
    // A Lua error must terminate at this protection boundary, never unwind an
    // ffi_call or trampoline. The outer wrapper reports it after ffi returns.
    const status = if (comptime zlua.backend == .lua)
        c.lua_pcallk(raw, 2, 1, 0, 0, null)
    else
        c.lua_pcall(raw, 2, 1, 0);
    if (status != 0) {
        context.errors += 1;
        var len: usize = 0;
        if (c.lua_tolstring(raw, -1, &len)) |message| {
            context.error_marker = std.mem.indexOf(u8, message[0..len], "protected bridge error") != null;
        }
        return;
    }
    if (c.lua_type(raw, -1) != c.LUA_TNUMBER) {
        context.errors += 1;
        return;
    }
    output.* = if (comptime zlua.backend == .lua)
        c.lua_tonumberx(raw, -1, null)
    else
        c.lua_tonumber(raw, -1);
    context.total += output.*;
}

fn dispatch(datum: ?*anyopaque, function: *const Callback, left: i32, right: f64) callconv(.c) f64 {
    const context: *Context = @ptrCast(@alignCast(datum.?));
    var pointer_arg = datum;
    var integer_arg = left;
    var double_arg = right;
    var args = [_]*anyopaque{ @ptrCast(&pointer_arg), @ptrCast(&integer_arg), @ptrCast(&double_arg) };
    var result: f64 = 0;
    context.dispatches += 1;
    context.cif.call(function, &args, &result);
    return result;
}

fn returnCallback(function: *const Callback) callconv(.c) *const Callback {
    return function;
}

fn invoke(optional_raw: ?*c.lua_State) callconv(.c) c_int {
    const raw = optional_raw.?;
    const context: *Context = @ptrCast(@alignCast(c.lua_touserdata(raw, c.lua_upvalueindex(1)).?));
    // Scenario inputs are fixed numeric ABI probes, not a general public API.
    const left_number = if (comptime zlua.backend == .lua) c.lua_tonumberx(raw, 1, null) else c.lua_tonumber(raw, 1);
    const right = if (comptime zlua.backend == .lua) c.lua_tonumberx(raw, 2, null) else c.lua_tonumber(raw, 2);
    const errors = context.errors;
    const result = dispatchClosure(context, @intFromFloat(left_number), right);
    if (context.errors != errors) {
        c.lua_pushnil(raw);
        _ = c.lua_pushstring(raw, "protected bridge error");
        return 2;
    }
    c.lua_pushnumber(raw, result);
    return 1;
}

fn dispatchClosure(context: *Context, left: i32, right: f64) f64 {
    var datum: ?*anyopaque = context;
    var integer_arg = left;
    var double_arg = right;
    var args = [_]*anyopaque{ @ptrCast(&datum), @ptrCast(&integer_arg), @ptrCast(&double_arg) };
    var result: f64 = 0;
    context.cif.call(context.code, &args, &result);
    return result;
}
