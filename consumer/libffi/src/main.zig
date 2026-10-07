const std = @import("std");
const zlua = @import("zlua");
const scenario = @import("scenario.zig");

pub fn main(init: std.process.Init) !void {
    try scenario.run();
    try std.Io.File.stdout().writeStreamingAll(
        init.io,
        "zlua/libffi smoke: " ++ @tagName(zlua.backend) ++
            " signed=-47 signed64=-27021597764222981 mixed=-9.75 closure=-42 recovery=ok" ++
            " bridge=-59.5,-33.75,-42 bridge-errors=1" ++
            (if (zlua.backend == .luajit)
                " builtin-signed=-47 builtin-mixed=-9.75 returned=-9.75" ++
                    " callback=4.25 returned-callback=-5.5 nested=4.5" ++
                    " bridge-calls=6 dispatches=4 callbacks=3,1 total=-197.25\n"
            else
                " bridge-calls=4 total=-135.25\n"),
    );
}

test "signed and mixed ABI, protected Lua callbacks, recovery and bidirectional LuaJIT ffi roundtrips" {
    try scenario.run();
}
