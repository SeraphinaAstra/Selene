#include <stdio.h>
#include "uart.h"
#include "memory.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static const char *boot_script =
    "print('LuaOS v0.1')\n"
    "print('Lua ' .. _VERSION .. ' on RISC-V')\n"
    "print('ready.')\n";

void kernel_main(void) {
    uart_init();
    memory_init();
    uart_puts("LuaOS: booting...\n");

    lua_State *L = luaL_newstate();
    if (!L) {
        uart_puts("LuaOS: FATAL: lua state alloc failed\n");
        while(1);
    }

    luaL_openlibs(L);
    uart_puts("LuaOS: Lua VM ok\n");

    if (luaL_dostring(L, boot_script) != LUA_OK) {
        uart_puts("LuaOS: Lua error: ");
        uart_puts(lua_tostring(L, -1));
        uart_puts("\n");
    }

    lua_close(L);
    uart_puts("LuaOS: halted\n");
    while(1);
}