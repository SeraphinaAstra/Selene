#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

void boot(void) {
    char buffer[256];
    printf("\n--- Selene (SNK) booting ---\n");

    printf("[OS] Initializing Lua state... ");
    lua_State *L = luaL_newstate();
    if (!L) {
        printf("FAILED\n");
        while(1);
    }
    printf("OK\n");

    printf("[OS] Opening Lua libraries... ");
    luaL_openlibs(L);
    printf("OK\n");

    printf("\nLua 5.4 Ready\n");

    while (1) {
        printf("> ");
        fflush(stdout);
        if (fgets(buffer, sizeof(buffer), stdin)) {
            buffer[strcspn(buffer, "\n")] = 0;
            if (strlen(buffer) == 0) continue;
            if (luaL_dostring(L, buffer) != LUA_OK) {
                printf("Error: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        }
    }
}