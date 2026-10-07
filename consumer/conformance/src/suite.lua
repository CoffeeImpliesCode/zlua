assert(_VERSION == "Lua 5.5", "official suite requires Lua 5.5")
assert(type(T) == "table", "official ltests T module is missing")
assert(T.testC, "official internal C tests are missing")
assert(not _U and not _soft and not _port and not _nomsg,
       "reduced official-suite modes are forbidden")
assert(type(conformance_cli) == "string" and #conformance_cli > 0)
arg = {[0] = "all.lua", [-1] = conformance_cli}
conformance_cli = nil
package.path = "./?.lua;" .. package.path
package.cpath = "./libs/?.so;" .. package.cpath
assert(loadfile("all.lua"))()
