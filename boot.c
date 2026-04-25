#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

// We'll use this to read one char at a time bypasses library buffering
extern int uart_getc(FILE *file); 

void boot(void) {
    char buffer[256];
    int idx = 0;
    
    printf("\n--- Selene (SNK) booting ---\n");

    lua_State *L = luaL_newstate();
    if (!L) { while(1); }
    luaL_openlibs(L);

    printf("Lua 5.4 Ready\n> ");
    fflush(stdout);

    while (1) {
        // Raw read
        int c = uart_getc(NULL);

        if (c == '\r' || c == '\n') {
            printf("\r\n"); // Visual newline
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
            putchar(c); // Echo back
            fflush(stdout);
        }
    }
}