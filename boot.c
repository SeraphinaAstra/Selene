#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

extern int uart_getc(FILE *file);
extern char __heap_start;
extern char __heap_end;

/* --- Hardware Access Features --- */

// peek32(addr)
static int lua_peek32(lua_State *L) {
    uintptr_t addr = (uintptr_t)luaL_checkinteger(L, 1);
    uint32_t val = *(volatile uint32_t*)addr;
    lua_pushinteger(L, (lua_Integer)val);
    return 1;
}

// poke32(addr, val)
static int lua_poke32(lua_State *L) {
    uintptr_t addr = (uintptr_t)luaL_checkinteger(L, 1);
    uint32_t val = (uint32_t)luaL_checkinteger(L, 2);
    *(volatile uint32_t*)addr = val;
    return 0;
}

// sysinfo()
static int lua_sysinfo(lua_State *L) {
    lua_newtable(L);
    
    lua_pushstring(L, "arch");
    lua_pushstring(L, "riscv64-unknown-elf");
    lua_settable(L, -3);
    
    lua_pushstring(L, "heap_kb");
    lua_pushinteger(L, (&__heap_end - &__heap_start) / 1024);
    lua_settable(L, -3);
    
    return 1;
}

void boot(void) {
    char buffer[256];
    int idx = 0;
    
    printf("\n--- Selene (SNK) booting ---\n");

    lua_State *L = luaL_newstate();
    if (!L) {
        printf("CRITICAL: Failed to init Lua state\n");
        while(1);
    }
    
    luaL_openlibs(L);

    /* Register OS commands */
    lua_register(L, "peek32", lua_peek32);
    lua_register(L, "poke32", lua_poke32);
    lua_register(L, "sysinfo", lua_sysinfo);

    printf("Lua 5.5 Ready\n> ");
    fflush(stdout);

    while (1) {
        int c = uart_getc(NULL);

        if (c == '\r' || c == '\n') {
            printf("\r\n");
            buffer[idx] = '\0';
            
            if (idx > 0) {
                if (luaL_dostring(L, buffer) != LUA_OK) {
                    printf("Error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            }
            
            idx = 0;
            printf("> ");
            fflush(stdout);
        } 
        else if (c == 8 || c == 127) { // Backspace
            if (idx > 0) {
                idx--;
                printf("\b \b");
                fflush(stdout);
            }
        } 
        else if (idx < 255) {
            buffer[idx++] = (char)c;
            putchar(c);
            fflush(stdout);
        }
    }
}