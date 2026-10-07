const std = @import("std");
const zlua = @import("zlua");

pub fn main(init: std.process.Init) !void {
    var state = try zlua.State.initWithLibraries();
    defer state.deinit();
    state.pushBytes("consumer-prefix");
    state.pushNumber(21);
    state.setGlobal("seed");
    try state.run("return math.floor(seed * 2), string.char(97, 0, 98)", "=consumer", 2);
    if (state.top() != 3 or state.toNumber(2) != 42) return error.BadResult;
    if (!std.mem.eql(u8, state.toBytes(1) orelse return error.MissingPrefix, "consumer-prefix")) return error.BadPrefix;
    if (!std.mem.eql(u8, state.toBytes(3) orelse return error.MissingString, "a\x00b")) return error.BadString;
    state.pop(2);
    if (state.run("error('consumer-recovery')", "=consumer-error", 0)) |_| {
        return error.ExpectedRuntimeError;
    } else |err| {
        if (err != error.RuntimeError) return err;
    }
    if (state.top() != 2 or state.toBytes(-1) == null) return error.BadErrorObject;
    state.pop(1);
    try state.run("return 42", "=consumer-recovery", 1);
    if (state.top() != 2 or state.toNumber(-1) != 42) return error.BadRecovery;
    var buffer: [128]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.print("zlua consumer backend={s} result=42\n", .{@tagName(zlua.backend)});
    try output.flush();
}
