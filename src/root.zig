//! Common Lua and LuaJIT state operations for the build-selected runtime.
//! Import `zlua`, create a `State`, and defer `deinit`; backend-specific APIs
//! remain available under `native`, including its generated C bindings in `c`.
//! Loading accepts text only. Opening libraries does not create a sandbox.
const std = @import("std");
const build_options = @import("build_options");

pub const native = @import("native");
pub const c = native.c;

/// Runtime selected by `-Dbackend`; Lua is the default.
pub const Backend = enum { lua, luajit };
/// Compile-time identity of the linked runtime.
pub const backend: Backend = @fromBackingInt(@intCast(@backingInt(build_options.backend)));

/// Protected compilation and execution failures; the error object stays on the stack.
pub const Error = error{
    SyntaxError,
    MemoryError,
    RuntimeError,
    ErrorInErrorHandler,
    UnexpectedStatus,
};

// Lua errors can longjmp out of this callback, so it must own no Zig resources.

const LoadRequest = struct {
    source: [*]const u8,
    source_length: usize,
    name: [*:0]const u8,
    load_status: c_int = c.LUA_OK,
    output_reference: c_int,
};

fn loadCallback(state: ?*c.lua_State) callconv(.c) c_int {
    const raw = state orelse unreachable;
    const request = @as(
        *LoadRequest,
        @ptrCast(@alignCast(c.lua_touserdata(raw, 1) orelse unreachable)),
    );
    request.load_status = c.luaL_loadbufferx(
        raw,
        request.source,
        request.source_length,
        request.name,
        "t",
    );
    if (request.load_status != c.LUA_OK) return c.lua_error(raw);

    if (comptime backend == .luajit) {
        // lua_cpcall discards results. Slot 1 was allocated during State.init.
        c.lua_rawgeti(raw, c.LUA_REGISTRYINDEX, request.output_reference);
        c.lua_insert(raw, -2);
        c.lua_rawseti(raw, -2, 1);
        return 0;
    }
    return 1;
}

fn initLoadOutputCallback(state: ?*c.lua_State) callconv(.c) c_int {
    const raw = state orelse unreachable;
    const reference = @as(
        *c_int,
        @ptrCast(@alignCast(c.lua_touserdata(raw, 1) orelse unreachable)),
    );
    c.lua_createtable(raw, 1, 0);
    reference.* = c.luaL_ref(raw, c.LUA_REGISTRYINDEX);
    return 0;
}

/// Owns one runtime state and its stack, released by `deinit`.
/// Copies are not independent owners: never close or use a copy after its owner closes.
/// Operations other than `isOpen` and `deinit` require an open state. Calls on one
/// state must be externally serialized. Native callbacks may use the active C stack,
/// but must not close the state or let Lua's longjmp skip Zig resource cleanup.
/// Pushes and other unprotected native operations can raise a fatal runtime panic
/// on allocation failure; `load` and `protectedCall` return protected errors.
pub const State = struct {
    /// Owned SDK state; do not replace or close this field separately.
    sdk: native.State,
    /// Internal LuaJIT output scratch, rooted until state destruction; do not modify.
    load_output_reference: c_int = c.LUA_NOREF,

    /// Creates an empty state using the runtime's allocator, without standard libraries.
    /// LuaJIT also creates protected output scratch storage, released by `deinit`.
    /// On `error.OutOfMemory`, no resource is transferred to the caller.
    pub fn init() error{OutOfMemory}!State {
        var self = State{ .sdk = try native.State.init() };
        errdefer self.sdk.deinit();
        if (comptime backend == .luajit) {
            if (c.lua_cpcall(self.handle(), initLoadOutputCallback, @ptrCast(&self.load_output_reference)) != c.LUA_OK)
                return error.OutOfMemory;
        }
        return self;
    }

    /// Creates a state and opens all standard libraries, including unsafe host facilities.
    pub fn initWithLibraries() error{OutOfMemory}!State {
        var self = try init();
        self.openLibraries();
        return self;
    }

    /// Closes the state and invalidates all its pointers and borrowed strings.
    /// Repeating this on the same variable is safe; copies retain stale ownership.
    pub fn deinit(self: *State) void {
        self.sdk.deinit();
        self.load_output_reference = c.LUA_NOREF;
    }

    /// Reports whether this variable still owns an open state.
    pub fn isOpen(self: *const State) bool {
        return self.sdk.raw != null;
    }

    /// Borrows the native state until `deinit`; using a closed state is a programmer error.
    pub fn handle(self: *const State) *c.lua_State {
        return self.sdk.raw orelse @panic("zlua: operation on a closed State");
    }

    /// Number of values on the active stack.
    pub fn top(self: *const State) usize {
        return @intCast(c.lua_gettop(self.handle()));
    }

    /// Sets the absolute stack size, padding with nil when growing.
    /// `count` must fit `c_int` and growing requires sufficient stack capacity.
    pub fn setTop(self: *State, count: usize) void {
        c.lua_settop(self.handle(), countInt(count));
    }

    /// Removes `count` values; `count <= top()` is a programmer precondition.
    pub fn pop(self: *State, count: usize) void {
        const current = self.top();
        std.debug.assert(count <= current);
        self.setTop(current - count);
    }

    /// Reserves room for `count` additional values, or returns false if unavailable.
    pub fn checkStack(self: *State, count: usize) bool {
        const raw = self.handle();
        if (count > std.math.maxInt(c_int)) return false;
        return c.lua_checkstack(raw, @intCast(count)) != 0;
    }

    /// Opens all standard libraries. This includes host I/O and is not sandboxing.
    pub fn openLibraries(self: *State) void {
        _ = self.handle();
        switch (backend) {
            .lua => self.sdk.openLibraries(),
            .luajit => self.sdk.openLibs(),
        }
    }

    /// Compiles text with `name` for diagnostics, rejecting binary chunks.
    /// Pushes one function on success or one error object on failure, preserving
    /// the stack prefix. Syntax and memory failures return their corresponding tags.
    /// Requires three free stack slots. Use `checkStack(3)` when availability is uncertain.
    pub fn load(self: *State, source: []const u8, name: [:0]const u8) Error!void {
        const raw = self.handle();
        var request = LoadRequest{
            .source = source.ptr,
            .source_length = source.len,
            .name = name.ptr,
            .output_reference = self.load_output_reference,
        };
        const status = switch (backend) {
            .lua => blk: {
                // These pushes do not allocate; a zero-upvalue C function is light.
                c.lua_pushcclosure(raw, loadCallback, 0);
                c.lua_pushlightuserdata(raw, @ptrCast(&request));
                break :blk c.lua_pcallk(raw, 1, 1, 0, 0, null);
            },
            .luajit => c.lua_cpcall(raw, loadCallback, @ptrCast(&request)),
        };
        if (comptime backend == .luajit) {
            if (status == c.LUA_OK) {
                // Only nonallocating operations follow cpcall. Keep the function on
                // the caller's stack and clear the scratch without freeing its ref.
                c.lua_rawgeti(raw, c.LUA_REGISTRYINDEX, self.load_output_reference);
                c.lua_rawgeti(raw, -1, 1);
                c.lua_pushnil(raw);
                c.lua_rawseti(raw, -3, 1);
                c.lua_remove(raw, -2);
            }
        }
        const load_status = if (request.load_status == c.LUA_OK)
            status
        else
            request.load_status;
        try statusOk(load_status);
    }

    /// Calls the value below `nargs` stack arguments, replacing them with results.
    /// `nargs < top()` and all counts must fit `c_int`. `null` keeps all results;
    /// a fixed count truncates or pads with nil. Reserve stack capacity for fixed
    /// results first. On failure the function and arguments become one error object;
    /// the earlier prefix remains. Errors may be non-string values.
    pub fn protectedCall(self: *State, nargs: usize, nresults: ?usize) Error!void {
        std.debug.assert(nargs < self.top());
        const argument_count = countInt(nargs);
        const result_count = if (nresults) |count| countInt(count) else c.LUA_MULTRET;
        const raw = self.handle();
        const status = switch (backend) {
            .lua => c.lua_pcallk(raw, argument_count, result_count, 0, 0, null),
            .luajit => c.lua_pcall(raw, argument_count, result_count, 0),
        };
        try statusOk(status);
    }

    /// Loads text and calls it without arguments, preserving earlier stack values.
    /// Errors leave one error object. Requires three free stack slots, as for `load`.
    /// `null` retains all results.
    pub fn run(
        self: *State,
        source: []const u8,
        name: [:0]const u8,
        nresults: ?usize,
    ) Error!void {
        try self.load(source, name);
        try self.protectedCall(0, nresults);
    }

    /// Pushes nil. Push operations require available stack capacity.
    pub fn pushNil(self: *State) void {
        c.lua_pushnil(self.handle());
    }

    /// Pushes a boolean.
    pub fn pushBoolean(self: *State, value: bool) void {
        _ = self.handle();
        self.sdk.pushBoolean(value);
    }

    /// Pushes a double; use `native` for backend-specific exact integer operations.
    pub fn pushNumber(self: *State, value: f64) void {
        _ = self.handle();
        self.sdk.pushNumber(value);
    }

    /// Copies the exact bytes into a runtime string, including embedded NUL bytes.
    /// The input may be released immediately afterward.
    pub fn pushBytes(self: *State, value: []const u8) void {
        _ = c.lua_pushlstring(self.handle(), value.ptr, value.len);
    }

    /// Lua truthiness: only nil, false, and an absent stack value are false.
    pub fn toBoolean(self: *const State, index: c_int) bool {
        _ = self.handle();
        return self.sdk.toBoolean(index);
    }

    /// Converts numbers and numeric strings to a double, or returns `null`.
    pub fn toNumber(self: *const State, index: c_int) ?f64 {
        _ = self.handle();
        return switch (backend) {
            .lua => self.sdk.toNumber(index),
            .luajit => self.sdk.toNumberX(index),
        };
    }

    /// Borrows an actual string, or returns `null` without converting other types.
    /// Keep the string rooted in this open state until the borrow is copied or no
    /// longer used. Removing the last root permits GC to invalidate the bytes.
    pub fn toBytes(self: *const State, index: c_int) ?[]const u8 {
        const raw = self.handle();
        if (c.lua_type(raw, index) != c.LUA_TSTRING) return null;
        var length: usize = 0;
        const value = c.lua_tolstring(raw, index, &length);
        return value[0..length];
    }

    /// Pushes the named global, or nil if absent.
    pub fn getGlobal(self: *State, name: [:0]const u8) void {
        _ = self.handle();
        self.sdk.getGlobal(name);
    }

    /// Consumes the top value and assigns it to the named global.
    pub fn setGlobal(self: *State, name: [:0]const u8) void {
        std.debug.assert(self.top() > 0);
        self.sdk.setGlobal(name);
    }

    /// Pushes a C function with no upvalues. The function must be nonnull and live
    /// while reachable. Lua invokes it on the calling thread with a borrowed active
    /// state and arguments; it may call C stack APIs but must not close this owner.
    pub fn pushFunction(self: *State, function: c.lua_CFunction) void {
        std.debug.assert(function != null);
        c.lua_pushcclosure(self.handle(), function, 0);
    }
};

fn countInt(count: usize) c_int {
    std.debug.assert(count <= std.math.maxInt(c_int));
    return @intCast(count);
}

fn statusOk(status: c_int) Error!void {
    return switch (status) {
        c.LUA_OK => {},
        c.LUA_ERRSYNTAX => error.SyntaxError,
        c.LUA_ERRMEM => error.MemoryError,
        c.LUA_ERRRUN => error.RuntimeError,
        c.LUA_ERRERR => error.ErrorInErrorHandler,
        else => error.UnexpectedStatus,
    };
}
