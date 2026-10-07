const std = @import("std");
const zlua = @import("zlua");
const State = zlua.State;
const c = zlua.c;
extern "c" fn puts(message: [*:0]const u8) c_int;

// Export a C entry point rather than using Zig's host-dependent process startup.
// The Node launcher asserts its status; every semantic check runs inside wasm.
export fn zluaWasmScenario() callconv(.c) c_int {
    scenario() catch |err| {
        _ = puts(@errorName(err));
        return 1;
    };
    return 0;
}

fn scenario() !void {
    var state = try State.initWithLibraries();
    defer state.deinit();
    if (!state.checkStack(16)) return error.StackCapacity;
    state.pushBytes("caller-prefix");
    c.lua_pushcclosure(state.handle(), doubleCallback, 0);
    state.setGlobal("zig_double");
    try state.run(
        \\local t = {3, 1, 4, 2}
        \\table.sort(t)
        \\local sum = 0
        \\for i, value in ipairs(t) do
        \\  if i % 2 == 0 then sum = sum + value * 2 else sum = sum + value end
        \\end
        \\local binary = string.char(65, 0, 255, 90)
        \\return sum, table.concat(t, ':'), math.sqrt(81),
        \\       string.reverse(binary), #binary, zig_double(21), type(os.clock)
    , "=wasm-semantics", null);
    try expect(state.top() == 8);
    try expectBytes(&state, 1, "caller-prefix");
    try expectNumber(&state, 2, 16);
    try expectBytes(&state, 3, "1:2:3:4");
    try expectNumber(&state, 4, 9);
    try expectBytes(&state, 5, "Z\xff\x00A");
    try expectNumber(&state, 6, 4);
    try expectNumber(&state, 7, 42);
    try expectBytes(&state, 8, "function");
    state.setTop(1);

    // Both protected failures execute Lua's setjmp/longjmp path in wasm.
    if (state.load("return )", "=wasm-syntax")) |_| {
        return error.ExpectedSyntaxError;
    } else |err| {
        try expect(err == error.SyntaxError);
    }
    try expect(state.top() == 2);
    try expectErrorMarker(&state, "wasm-syntax");
    try expectBytes(&state, 1, "caller-prefix");
    state.pop(1);
    if (state.run("error('wasm-runtime-marker')", "=wasm-runtime", null)) |_| {
        return error.ExpectedRuntimeError;
    } else |err| {
        try expect(err == error.RuntimeError);
    }
    try expect(state.top() == 2);
    try expectErrorMarker(&state, "wasm-runtime-marker");
    try expectBytes(&state, 1, "caller-prefix");
    state.pop(1);

    try state.load("local a, b = ...; return a+b, a-b, 'recovered'", "=wasm-recovery");
    state.pushNumber(30);
    state.pushNumber(12);
    try state.protectedCall(2, null);
    try expect(state.top() == 4);
    try expectBytes(&state, 1, "caller-prefix");
    try expectNumber(&state, 2, 42);
    try expectNumber(&state, 3, 18);
    try expectBytes(&state, 4, "recovered");
    state.setTop(1);
    try state.run("return 7", "=wasm-padding", 3);
    try expect(state.top() == 4);
    try expectNumber(&state, 2, 7);
    try expect(c.lua_type(state.handle(), 3) == c.LUA_TNIL);
    try expect(c.lua_type(state.handle(), 4) == c.LUA_TNIL);
    state.pop(3);
    try expect(state.top() == 1);
    try expectBytes(&state, 1, "caller-prefix");
}

fn expect(condition: bool) error{AssertionFailed}!void {
    if (!condition) return error.AssertionFailed;
}

fn expectNumber(state: *const State, index: c_int, expected: f64) !void {
    const actual = state.toNumber(index) orelse return error.ExpectedNumber;
    if (actual != expected) return error.NumberMismatch;
}

fn expectBytes(state: *const State, index: c_int, expected: []const u8) !void {
    const actual = state.toBytes(index) orelse return error.ExpectedString;
    if (!std.mem.eql(u8, expected, actual)) return error.BytesMismatch;
}

fn expectErrorMarker(state: *const State, marker: []const u8) !void {
    const actual = state.toBytes(-1) orelse return error.ExpectedErrorString;
    if (std.mem.indexOf(u8, actual, marker) == null) return error.ErrorMarkerMissing;
}

// No resources or Zig cleanup may be skipped by a Lua longjmp in a callback.
fn doubleCallback(raw: ?*c.lua_State) callconv(.c) c_int {
    const value = c.lua_tonumberx(raw, 1, null);
    c.lua_pushnumber(raw, value * 2);
    return 1;
}
