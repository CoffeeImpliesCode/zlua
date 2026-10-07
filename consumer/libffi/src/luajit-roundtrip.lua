local ffi = require('ffi')
ffi.cdef[[
typedef double (*bridge_fn)(void *, int32_t, double);
typedef double (*dispatch_fn)(void *, bridge_fn, int32_t, double);
typedef bridge_fn (*return_fn)(bridge_fn);
typedef int32_t (*signed_fn)(int32_t, int32_t);
typedef double (*mixed_fn)(int32_t, double, int32_t, double);
typedef mixed_fn (*factory_fn)(void);
]]
local context = ffi.cast('void *', bridge_context)
local closure = ffi.cast('bridge_fn', bridge_code)
local dispatch = ffi.cast('dispatch_fn', bridge_dispatch)
local returned = ffi.cast('return_fn', bridge_return)
local factory = ffi.cast('factory_fn', bridge_factory)
assert(ffi.cast('signed_fn', bridge_signed)(-17, 4) == -47, 'builtin ffi calls separate signed C function')
assert(ffi.cast('mixed_fn', bridge_mixed)(-7, 1.5, 3, 0.25) == -9.75, 'builtin ffi mixed C ABI')
assert(factory()(-7, 1.5, 3, 0.25) == -9.75, 'native-returned function consumed by builtin ffi')
local inner_calls, outer_calls, wrong_context = 0, 0, false
-- These cdata objects remain strongly rooted until every native invocation finishes.
local function inner_body(ctx, a, b)
    if ctx ~= context then wrong_context = true; return 0 end
    inner_calls = inner_calls + 1
    return a * 2 + b
end
local function outer_body(ctx, a, b)
    if ctx ~= context then wrong_context = true; return 0 end
    outer_calls = outer_calls + 1
    return closure(ctx, a, b) + 7
end
local inner = ffi.cast('bridge_fn', inner_body)
local outer = ffi.cast('bridge_fn', outer_body)
local function nested_body(a, b) return dispatch(context, inner, a, b) + 5 end
local function exercise()
    assert(closure(context, -7, 1.5) == -59.5, 'libffi closure called by builtin ffi')
    assert(dispatch(context, inner, 2, 0.25) == 4.25, 'builtin callback invoked through separate ffi_call')
    local callback_from_native = returned(inner)
    assert(dispatch(context, callback_from_native, -3, 0.5) == -5.5, 'native-returned callback consumed by libffi')
    bridge_nested = nested_body
    collectgarbage('collect')
    assert(dispatch(context, outer, -4, 0.5) == 4.5, 'nested builtin callback -> libffi closure -> protected Lua -> libffi -> builtin callback')
    bridge_nested = nil
end
-- LuaJIT forbids compiled C calls that reenter Lua. Disable only the functions
-- on these callback paths, not the VM or the other consumer scenarios.
jit.off(exercise, true)
jit.off(outer_body, true)
jit.off(nested_body, true)
local ok, message = pcall(exercise)
bridge_nested = nil
inner:free()
outer:free()
assert(ok, message)
assert(inner_calls == 3 and outer_calls == 1 and not wrong_context, 'exact rooted callback counts and context')
return inner_calls, outer_calls
