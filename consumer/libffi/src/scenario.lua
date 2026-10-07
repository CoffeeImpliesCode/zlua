local signed = ffi_signed(-17, 4)
local mixed = ffi_mixed(-7, 1.5, 3, 0.25)
local closure = ffi_closure(2, -4)
assert(signed == -47, 'signed C ABI result')
assert(mixed == -9.75, 'mixed integer/double C ABI result')
assert(closure == -42, 'executable closure userdata result')

local value, message = ffi_signed('not a number', 4)
assert(value == nil and type(message) == 'string')
value, message = ffi_mixed(-7, 1.5, 3.5, 0.25)
assert(value == nil and type(message) == 'string')
value, message = ffi_closure(2, {})
assert(value == nil and type(message) == 'string')

return signed, mixed, closure
