const std = @import("std");
const zlua = @import("zlua");

pub fn main(init: std.process.Init) !void {
    var state = try zlua.State.initWithLibraries();
    defer state.deinit();

    state.pushBytes("prefix");
    try state.run("return 6 * 7", "=smoke", 1);
    const result = state.toNumber(-1) orelse return error.ExpectedNumber;
    if (result != 42) return error.WrongResult;
    if (state.top() != 2) return error.WrongStack;
    state.pop(1);

    state.run("error('expected smoke failure')", "=smoke-error", 0) catch |err| {
        if (err != error.RuntimeError) return err;
        if (state.top() != 2) return error.WrongErrorStack;
        if (state.toBytes(-1) == null) return error.ExpectedErrorMessage;
        state.pop(1);
        try state.run("return 42", "=smoke-recovery", 1);
        if (state.toNumber(-1) != 42) return error.RecoveryFailed;
        if (state.top() != 2) return error.WrongRecoveryStack;
        if (!std.mem.eql(u8, state.toBytes(1) orelse return error.LostPrefix, "prefix")) {
            return error.LostPrefix;
        }

        var buffer: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.print("backend={s} result={d}\n", .{
            @tagName(zlua.backend),
            result,
        });
        try stdout.interface.flush();
        return;
    };
    return error.ExpectedRuntimeError;
}
