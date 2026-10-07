const std = @import("std");
const testing = std.testing;
const zlua = @import("zlua");
const State = zlua.State;
const c = zlua.c;

fn number(state: *const State, index: c_int, expected: f64) !void {
    try testing.expectEqual(expected, state.toNumber(index) orelse return error.ExpectedNumber);
}

fn bytes(state: *const State, index: c_int, expected: []const u8) !void {
    try testing.expectEqualSlices(u8, expected, state.toBytes(index) orelse return error.ExpectedString);
}

fn doubleCallback(raw: ?*c.lua_State) callconv(.c) c_int {
    const value = c.lua_tonumberx(raw, 1, null);
    c.lua_pushnumber(raw, value * 2);
    return 1;
}

test "creation without libraries and explicit library opening" {
    var state = try State.init();
    defer state.deinit();
    try testing.expect(state.isOpen());
    try testing.expectEqual(@as(usize, 0), state.top());
    try state.run("return math, type, string, table", "=no-libraries", null);
    for (1..5) |index| try testing.expectEqual(c.LUA_TNIL, c.lua_type(state.handle(), @intCast(index)));
    state.setTop(0);
    state.openLibraries();
    try state.run("return type(math), type(string), type(table), type(coroutine), type(package)", "=libraries", null);
    try bytes(&state, 1, "table");
    try bytes(&state, 2, "table");
    try bytes(&state, 3, "table");
    try bytes(&state, 4, "table");
    try bytes(&state, 5, "table");
}

test "arithmetic math and multiple result ordering" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    try state.run("return 6*7, math.sqrt(81), -3.25, 'last'", "=arithmetic", null);
    try testing.expectEqual(@as(usize, 4), state.top());
    try number(&state, 1, 42);
    try number(&state, 2, 9);
    try number(&state, 3, -3.25);
    try bytes(&state, -1, "last");
}

test "fixed result counts truncate pad nil and discard" {
    var state = try State.init();
    defer state.deinit();
    try state.run("return 1, 2, 3", "=truncate", 1);
    try testing.expectEqual(@as(usize, 1), state.top());
    try number(&state, 1, 1);
    state.setTop(0);
    try state.run("return 7", "=padding", 3);
    try testing.expectEqual(@as(usize, 3), state.top());
    try number(&state, 1, 7);
    try testing.expectEqual(c.LUA_TNIL, c.lua_type(state.handle(), 2));
    try testing.expectEqual(c.LUA_TNIL, c.lua_type(state.handle(), 3));
    state.setTop(0);
    try state.run("return 9, 10", "=discard", 0);
    try testing.expectEqual(@as(usize, 0), state.top());
}

test "load and protected call preserve caller prefix and pass arguments" {
    var state = try State.init();
    defer state.deinit();
    state.pushBytes("prefix");
    try state.load("local a,b = ...; return a+b, a-b", "=arguments");
    try testing.expectEqual(@as(usize, 2), state.top());
    try testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(state.handle(), -1));
    state.pushNumber(30);
    state.pushNumber(12);
    try state.protectedCall(2, null);
    try testing.expectEqual(@as(usize, 3), state.top());
    try bytes(&state, 1, "prefix");
    try number(&state, 2, 42);
    try number(&state, 3, 18);

    state.pop(2);
    for (0..32) |_| {
        try state.load("return 42", "=repeated-success");
        try testing.expectEqual(@as(usize, 2), state.top());
        try testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(state.handle(), -1));
        // A failed load must neither replace the earlier function nor leave scratch output.
        try testing.expectError(error.SyntaxError, state.load("return )", "=repeated-error"));
        try testing.expectEqual(@as(usize, 3), state.top());
        try testing.expectEqual(c.LUA_TSTRING, c.lua_type(state.handle(), -1));
        state.pop(1);
        try state.protectedCall(0, 1);
        try number(&state, -1, 42);
        try bytes(&state, 1, "prefix");
        state.pop(1);
        if (comptime zlua.backend == .luajit) {
            c.lua_rawgeti(state.handle(), c.LUA_REGISTRYINDEX, state.load_output_reference);
            try testing.expectEqual(c.LUA_TTABLE, c.lua_type(state.handle(), -1));
            c.lua_rawgeti(state.handle(), -1, 1);
            try testing.expectEqual(c.LUA_TNIL, c.lua_type(state.handle(), -1));
            state.pop(2);
        }
        try testing.expectEqual(@as(usize, 1), state.top());
    }
}

test "syntax and runtime errors remain rooted and permit recovery" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    state.pushBytes("prefix");
    try testing.expectError(error.SyntaxError, state.load("return )", "=syntax-marker"));
    try testing.expectEqual(@as(usize, 2), state.top());
    const syntax = state.toBytes(-1) orelse return error.ExpectedString;
    try testing.expect(std.mem.indexOf(u8, syntax, "syntax-marker") != null);
    try bytes(&state, 1, "prefix");
    state.pop(1);
    try testing.expectError(error.RuntimeError, state.run("error('runtime-marker')", "=runtime", null));
    try testing.expectEqual(@as(usize, 2), state.top());
    const runtime = state.toBytes(-1) orelse return error.ExpectedString;
    try testing.expect(std.mem.indexOf(u8, runtime, "runtime-marker") != null);
    state.pop(1);
    try state.run("return 42", "=recovery", 1);
    try bytes(&state, 1, "prefix");
    try number(&state, 2, 42);
}

test "protected calls retain non-string error objects" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    state.pushNumber(123);
    try testing.expectError(error.RuntimeError, state.run("error({code=42})", "=table-error", null));
    try testing.expectEqual(@as(usize, 2), state.top());
    try testing.expect(state.toBytes(-1) == null);
    try testing.expectEqual(c.LUA_TTABLE, c.lua_type(state.handle(), -1));
    _ = c.lua_getfield(state.handle(), -1, "code");
    try number(&state, -1, 42);
    state.pop(2);
    try number(&state, -1, 123);
    try state.run("return 7", "=recovery", 1);
    try number(&state, -1, 7);
}

test "text loader rejects Lua and LuaJIT binary signatures" {
    var state = try State.init();
    defer state.deinit();
    for ([_][]const u8{ "\x1bLua\x55\x00", "\x1bLJ\x02\x00" }) |chunk| {
        try testing.expectError(error.SyntaxError, state.load(chunk, "=binary"));
        try testing.expectEqual(@as(usize, 1), state.top());
        try testing.expect(state.toBytes(-1) != null);
        state.pop(1);
    }
    try state.run("return 42", "=text", 1);
    try number(&state, -1, 42);
}

test "text loader rejects valid bytecode produced by the selected runtime" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    try state.run("return string.dump(function() return 42 end)", "=dump", 1);
    const dumped = state.toBytes(1) orelse return error.ExpectedString;
    try testing.expect(dumped.len > 4 and dumped[0] == 0x1b);
    try testing.expectError(error.SyntaxError, state.load(dumped, "=native-bytecode"));
    try testing.expectEqual(@as(usize, 2), state.top());
    try testing.expect(state.toBytes(-1) != null);
    state.pop(1);
    try testing.expectEqualSlices(u8, dumped, state.toBytes(1).?);
}

test "loading compiles without execution and zero return values leave no results" {
    var state = try State.init();
    defer state.deinit();
    try state.load("executed=42", "=deferred");
    state.getGlobal("executed");
    try testing.expectEqual(c.LUA_TNIL, c.lua_type(state.handle(), -1));
    state.pop(1);
    try state.protectedCall(0, null);
    try testing.expectEqual(@as(usize, 0), state.top());
    state.getGlobal("executed");
    try number(&state, -1, 42);
    state.pop(1);
    try state.run("return", "=no-results", null);
    try testing.expectEqual(@as(usize, 0), state.top());
}

test "binary-safe strings empty strings and UTF8 round trip through Lua" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    const payload = "a\x00b\xff\x00λ🙂";
    state.pushBytes(payload);
    state.setGlobal("payload");
    try state.run("return payload, #payload, '', string.sub(payload, 2, 3)", "=bytes", null);
    try bytes(&state, 1, payload);
    try number(&state, 2, @floatFromInt(payload.len));
    try bytes(&state, 3, "");
    try bytes(&state, 4, "\x00b");
}

const FailureAllocator = struct {
    original: c.lua_Alloc,
    original_user_data: ?*anyopaque,
    fail_minimum_size: usize,
    armed: bool = false,
    failures: usize = 0,
    failed_size: usize = 0,
};

fn failLargeAllocation(
    user_data: ?*anyopaque,
    memory: ?*anyopaque,
    old_size: usize,
    new_size: usize,
) callconv(.c) ?*anyopaque {
    const probe = @as(*FailureAllocator, @ptrCast(@alignCast(user_data orelse unreachable)));
    if (probe.armed and memory == null and new_size >= probe.fail_minimum_size) {
        probe.armed = false;
        probe.failures += 1;
        probe.failed_size = new_size;
        return null;
    }
    const original = probe.original orelse unreachable;
    return original(probe.original_user_data, memory, old_size, new_size);
}

// The second collection shrinks the sparse intern table after parsing, not during setup.
test "LuaJIT load protects string-table shrink after parsing" {
    if (comptime zlua.backend == .luajit) {
        var state = try State.init();
        defer state.deinit();
        const raw = state.handle();

        state.pushBytes("prefix");
        _ = c.lua_gc(raw, c.LUA_GCSTOP, 0);
        var key: [8]u8 = undefined;
        for (0..8_192) |index| {
            std.mem.writeInt(u64, &key, @intCast(index), .little);
            state.pushBytes(&key);
            state.pop(1);
        }
        _ = c.lua_gc(raw, c.LUA_GCCOLLECT, 0);
        _ = c.lua_gc(raw, c.LUA_GCSETPAUSE, 0);
        _ = c.lua_gc(raw, c.LUA_GCSETSTEPMUL, 1_000_000);
        _ = c.lua_gc(raw, c.LUA_GCRESTART, -1);

        var original_user_data: ?*anyopaque = null;
        const original = c.lua_getallocf(raw, &original_user_data);
        var probe = FailureAllocator{
            .original = original,
            .original_user_data = original_user_data,
            .fail_minimum_size = 8_192,
        };
        c.lua_setallocf(raw, failLargeAllocation, &probe);
        defer c.lua_setallocf(raw, original, original_user_data);
        probe.armed = true;

        try testing.expectError(error.MemoryError, state.load("", ""));
        try testing.expectEqual(@as(usize, 1), probe.failures);
        try testing.expect(probe.failed_size >= probe.fail_minimum_size);
        try testing.expectEqual(@as(usize, 2), state.top());
        try bytes(&state, 1, "prefix");
        try testing.expectEqual(c.LUA_TSTRING, c.lua_type(raw, -1));
        state.pop(1);
        c.lua_rawgeti(raw, c.LUA_REGISTRYINDEX, state.load_output_reference);
        c.lua_rawgeti(raw, -1, 1);
        try testing.expectEqual(c.LUA_TNIL, c.lua_type(raw, -1));
        state.pop(2);
        try state.run("return 42", "", 1);
        try bytes(&state, 1, "prefix");
        try number(&state, -1, 42);
        c.lua_rawgeti(raw, c.LUA_REGISTRYINDEX, state.load_output_reference);
        c.lua_rawgeti(raw, -1, 1);
        try testing.expectEqual(c.LUA_TNIL, c.lua_type(raw, -1));
        state.pop(2);
    }
}

test "borrowed string stays valid while rooted across native garbage collection" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    var payload: [4096]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    state.pushBytes(&payload);
    const borrowed = state.toBytes(1) orelse return error.ExpectedString;
    try state.run("for i=1,10000 do local s=string.rep('x', 100) end", "=allocation-pressure", 0);
    _ = c.lua_gc(state.handle(), c.LUA_GCCOLLECT, @as(c_int, 0));
    try testing.expectEqualSlices(u8, &payload, borrowed);
    try testing.expectEqual(@as(usize, 1), state.top());
}

test "boolean conversion follows Lua truthiness not numeric truthiness" {
    var state = try State.init();
    defer state.deinit();
    state.pushNil();
    state.pushBoolean(false);
    state.pushBoolean(true);
    state.pushNumber(0);
    state.pushBytes("");
    try testing.expect(!state.toBoolean(1));
    try testing.expect(!state.toBoolean(2));
    try testing.expect(state.toBoolean(3));
    try testing.expect(state.toBoolean(4));
    try testing.expect(state.toBoolean(5));
    try testing.expect(!state.toBoolean(100));
}

test "numeric conversions preserve portable double precision and reject wrong values" {
    var state = try State.init();
    defer state.deinit();
    for ([_]f64{ 0, -0.125, 1.5, 9007199254740991, -9007199254740991 }) |value| {
        state.pushNumber(value);
        try number(&state, -1, value);
        try testing.expect(state.toBytes(-1) == null);
        state.pop(1);
    }
    state.pushBytes("12.75");
    try number(&state, -1, 12.75);
    try bytes(&state, -1, "12.75");
    state.pushBytes("not-a-number");
    try testing.expect(state.toNumber(-1) == null);
    state.pushBoolean(true);
    try testing.expect(state.toNumber(-1) == null);
    state.pushNil();
    try testing.expect(state.toNumber(-1) == null);
    try testing.expect(state.toNumber(100) == null);
    try testing.expect(state.toBytes(100) == null);
}

test "globals tables and C callbacks interact with real Lua code" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    state.pushNumber(21);
    state.setGlobal("seed");
    try testing.expectEqual(@as(usize, 0), state.top());
    state.pushFunction(doubleCallback);
    state.setGlobal("double_it");
    try state.run("answer={value=double_it(seed)}; return answer.value, type(double_it)", "=callback", null);
    try number(&state, 1, 42);
    try bytes(&state, 2, "function");
    state.setTop(0);
    state.getGlobal("answer");
    try testing.expectEqual(c.LUA_TTABLE, c.lua_type(state.handle(), -1));
    _ = c.lua_getfield(state.handle(), -1, "value");
    try number(&state, -1, 42);
    state.setTop(0);
    state.getGlobal("missing_global");
    try testing.expectEqual(c.LUA_TNIL, c.lua_type(state.handle(), -1));
}

test "state globals and stacks are isolated" {
    var first = try State.init();
    defer first.deinit();
    var second = try State.init();
    defer second.deinit();
    try testing.expect(first.handle() != second.handle());
    first.pushNumber(42);
    first.setGlobal("only_first");
    second.getGlobal("only_first");
    try testing.expectEqual(c.LUA_TNIL, c.lua_type(second.handle(), -1));
    first.getGlobal("only_first");
    try number(&first, -1, 42);
    first.pushBytes("extra");
    try testing.expectEqual(@as(usize, 2), first.top());
    try testing.expectEqual(@as(usize, 1), second.top());
}

test "stack reservation absolute sizing and repeated teardown" {
    var state = try State.init();
    defer state.deinit();
    try testing.expect(state.checkStack(128));
    state.pushNumber(42);
    state.setTop(4);
    try testing.expectEqual(@as(usize, 4), state.top());
    try number(&state, 1, 42);
    try testing.expectEqual(c.LUA_TNIL, c.lua_type(state.handle(), 4));
    state.pop(0);
    state.pop(3);
    try number(&state, -1, 42);
    state.setTop(0);
    try state.load("return 42", "=close-with-loaded-function");
    try testing.expectEqual(@as(usize, 1), state.top());
    try testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(state.handle(), -1));
    state.deinit();
    try testing.expect(!state.isOpen());
    try testing.expectEqual(c.LUA_NOREF, state.load_output_reference);
    state.deinit();
    try testing.expect(!state.isOpen());
}

test "selected native SDK exposes backend-specific runtime behavior" {
    var state = try State.initWithLibraries();
    defer state.deinit();
    if (zlua.backend == .lua) {
        try testing.expectEqual(@as(c_int, 505), zlua.native.c.LUA_VERSION_NUM);
        zlua.native.c.lua_pushinteger(state.handle(), 9223372036854775807);
        try testing.expectEqual(@as(c_int, 1), zlua.native.c.lua_isinteger(state.handle(), -1));
        try testing.expectEqual(
            @as(zlua.native.c.lua_Integer, 9223372036854775807),
            zlua.native.c.lua_tointegerx(state.handle(), -1, null),
        );
        state.pop(1);
        try state.run("return math.type(42), utf8.len('λ🙂'), _VERSION", "=lua-native", null);
        try bytes(&state, 1, "integer");
        try number(&state, 2, 2);
        try bytes(&state, 3, "Lua 5.5");
    } else {
        try testing.expectEqual(@as(c_int, 501), zlua.native.c.LUA_VERSION_NUM);
        _ = zlua.native.c.luaJIT_setmode(state.handle(), 0, zlua.native.c.LUAJIT_MODE_ENGINE | zlua.native.c.LUAJIT_MODE_ON);
        try state.run("local ffi=require('ffi'); local a=ffi.new('int[1]',42); return jit.version, tonumber(a[0]), type(jit.status())", "=luajit-native", null);
        const version = state.toBytes(1) orelse return error.ExpectedString;
        try testing.expect(std.mem.startsWith(u8, version, "LuaJIT 2.1"));
        try number(&state, 2, 42);
        try bytes(&state, 3, "boolean");
    }
}
