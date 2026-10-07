/* Keep all official test ABI settings, but expose the real SDK function.
 * The test allocator macro belongs only in bridge.c and the official CLI. */
#include "lua.h"
#undef luaL_newstate
#include "lauxlib.h"
#include "lualib.h"
