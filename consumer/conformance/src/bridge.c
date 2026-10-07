#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "ltests.h"

#if LUA_VERSION_RELEASE_NUM != 50501
#error "Conformance requires the pinned Lua 5.5.1 runtime"
#endif

static int open_test_libraries(lua_State *L) {
    luai_openlibs(L);
    return 0;
}

/* The ltests luaL_newstate macro selects debug_realloc and l_memcontrol. */
lua_State *zlua_conformance_newstate(void) {
    return luaL_newstate();
}

/* No Lua longjmp may cross Zig-owned state cleanup. */
int zlua_conformance_openlibs(lua_State *L) {
    lua_pushcfunction(L, open_test_libraries);
    return lua_pcall(L, 0, 0, 0);
}
