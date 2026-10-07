const scenario = @import("scenario.zig");

export fn zluaFfiWasmScenario() c_int {
    scenario.run() catch return 1;
    return 0;
}
