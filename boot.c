/* boot.c — boot loader */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

extern int uart_getc(FILE *file);
extern char __heap_start;
extern char __heap_end;

/* Ramdisk symbols from linker.ld */
extern char _ramdisk_start;
extern char _ramdisk_end;

extern void virtio_register(lua_State *L);

/* --- Ramdisk ------------------------------------------------------- */

#define RD_MAGIC "SLNE"
#define RD_ALIGN 8

typedef struct {
    const char *path;
    uint32_t    path_len;
    const char *data;
    uint32_t    data_len;
} RDFile;

static int rd_valid = 0;
static uint32_t rd_count = 0;

/* Find a file in the ramdisk by path. Returns pointer to data and
 * sets *size, or returns NULL if not found. */
static const char *rd_find(const char *path, uint32_t *size) {
    if (!rd_valid) return NULL;

    const uint8_t *p = (const uint8_t *)&_ramdisk_start + 8; /* skip magic + count */
    uint32_t align = RD_ALIGN;

    for (uint32_t i = 0; i < rd_count; i++) {
        uint32_t path_len = *(uint32_t *)p; p += 4;
        uint32_t data_len = *(uint32_t *)p; p += 4;

        const char *entry_path = (const char *)p;
        p += path_len;
        const char *entry_data = (const char *)p;
        p += data_len;

        /* Align to 8 bytes */
        uint32_t total = path_len + data_len;
        uint32_t padded = (total + align - 1) & ~(align - 1);
        p += padded - total;

        if (path_len == strlen(path) &&
            memcmp(entry_path, path, path_len) == 0) {
            *size = data_len;
            return entry_data;
        }
    }
    return NULL;
}

/* Lua: rd_find(path) → string or nil */
static int lua_rd_find(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    uint32_t size = 0;
    const char *data = rd_find(path, &size);
    if (data) {
        lua_pushlstring(L, data, size);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

/* Lua: rd_list() → table of path strings */
static int lua_rd_list(lua_State *L) {
    lua_newtable(L);
    if (!rd_valid) return 1;

    const uint8_t *p = (const uint8_t *)&_ramdisk_start + 8;
    uint32_t align = RD_ALIGN;

    for (uint32_t i = 0; i < rd_count; i++) {
        uint32_t path_len = *(uint32_t *)p; p += 4;
        uint32_t data_len = *(uint32_t *)p; p += 4;

        const char *entry_path = (const char *)p;
        p += path_len;
        p += data_len;

        uint32_t total = path_len + data_len;
        uint32_t padded = (total + align - 1) & ~(align - 1);
        p += padded - total;

        lua_pushinteger(L, i + 1);
        lua_pushlstring(L, entry_path, path_len);
        lua_settable(L, -3);
    }
    return 1;
}

/* Custom Lua loader: require("nyx.shell") → looks up "nyx/shell.lua"
 * in the ramdisk and loads it. Registered as a searcher in package.searchers. */
static int rd_lua_searcher(lua_State *L) {
    const char *modname = luaL_checkstring(L, 1);

    /* Convert module name to path: nyx.shell → nyx/shell.lua */
    char path[256];
    int j = 0;
    for (int i = 0; modname[i] && j < 250; i++) {
        path[j++] = (modname[i] == '.') ? '/' : modname[i];
    }
    memcpy(path + j, ".lua", 5);

    uint32_t size = 0;
    const char *data = rd_find(path, &size);
    if (!data) {
        lua_pushfstring(L, "no ramdisk file '%s'", path);
        return 1;
    }

    /* Load the chunk */
    char chunkname[260];
    snprintf(chunkname, sizeof(chunkname), "@%s", path);
    if (luaL_loadbuffer(L, data, size, chunkname) != LUA_OK) {
        return lua_error(L);
    }
    lua_pushstring(L, path); /* second return: origin */
    return 2;
}

/* Register the ramdisk searcher into package.searchers */
static void rd_register_searcher(lua_State *L) {
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "searchers");

    /* Shift existing searchers up and insert ours at index 2
     * (after the preload searcher, before the file searcher) */
    int n = (int)lua_rawlen(L, -1);
    for (int i = n; i >= 2; i--) {
        lua_rawgeti(L, -1, i);
        lua_rawseti(L, -2, i + 1);
    }
    lua_pushcfunction(L, rd_lua_searcher);
    lua_rawseti(L, -2, 2);

    lua_pop(L, 2); /* pop searchers, package */
}

/* --- Hardware Access ------------------------------------------------ */

static int lua_peek32(lua_State *L) {
    uintptr_t addr = (uintptr_t)luaL_checkinteger(L, 1);
    lua_pushinteger(L, (lua_Integer)(*(volatile uint32_t *)addr));
    return 1;
}

static int lua_poke32(lua_State *L) {
    uintptr_t addr  = (uintptr_t)luaL_checkinteger(L, 1);
    uint32_t  val   = (uint32_t)luaL_checkinteger(L, 2);
    *(volatile uint32_t *)addr = val;
    return 0;
}

static int lua_sysinfo(lua_State *L) {
    lua_newtable(L);
    lua_pushstring(L, "arch");
    lua_pushstring(L, "riscv64-unknown-elf");
    lua_settable(L, -3);
    lua_pushstring(L, "heap_kb");
    lua_pushinteger(L, (&__heap_end - &__heap_start) / 1024);
    lua_settable(L, -3);
    lua_pushstring(L, "ramdisk_files");
    lua_pushinteger(L, rd_valid ? (lua_Integer)rd_count : 0);
    lua_settable(L, -3);
    return 1;
}

static int lua_readline(lua_State *L) {
    static char buf[256];
    int idx = 0;

    while (1) {
        int c = uart_getc(NULL);

        if (c == '\r' || c == '\n') {
            printf("\r\n");
            buf[idx] = '\0';
            lua_pushstring(L, buf);
            return 1;
        } else if (c == 8 || c == 127) {
            if (idx > 0) {
                idx--;
                printf("\b \b");
                fflush(stdout);
            }
        } else if (idx < 255) {
            buf[idx++] = (char)c;
            putchar(c);
            fflush(stdout);
        }
    }
}

static int lua_prompt(lua_State *L) {
    printf("> ");
    fflush(stdout);
    return 0;
}

static int lua_readkey(lua_State *L) {
    int c = uart_getc(NULL);
    if (c == 27) {  /* escape sequence */
        int c2 = uart_getc(NULL);
        if (c2 == '[') {
            int c3 = uart_getc(NULL);
            switch (c3) {
                case 'A': lua_pushstring(L, "UP");    return 1;
                case 'B': lua_pushstring(L, "DOWN");  return 1;
                case 'C': lua_pushstring(L, "RIGHT"); return 1;
                case 'D': lua_pushstring(L, "LEFT");  return 1;
                case 'H': lua_pushstring(L, "HOME");  return 1;
                case 'F': lua_pushstring(L, "END");   return 1;
                case '3':
                    uart_getc(NULL); /* consume ~ */
                    lua_pushstring(L, "DEL"); return 1;
                default:
                    lua_pushstring(L, "ESC"); return 1;
            }
        }
        lua_pushstring(L, "ESC");
        return 1;
    }
    /* Return single char as string */
    char s[2] = { (char)c, 0 };
    lua_pushstring(L, s);
    return 1;
}

/* --- REPL ----------------------------------------------------------- */

static void repl(lua_State *L) {
    char buffer[256];
    int idx = 0;

    printf("> ");
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
        } else if (c == 8 || c == 127) {
            if (idx > 0) {
                idx--;
                printf("\b \b");
                fflush(stdout);
            }
        } else if (idx < 255) {
            buffer[idx++] = (char)c;
            putchar(c);
            fflush(stdout);
        }
    }
}

/* --- Boot ----------------------------------------------------------- */

void boot(void) {
    printf("\n--- Selene (SNK) booting ---\n");

    /* Validate ramdisk */
    if (memcmp(&_ramdisk_start, RD_MAGIC, 4) == 0) {
        rd_count = *(uint32_t *)((char *)&_ramdisk_start + 4);
        rd_valid = 1;
        printf("ramdisk: OK (%lu files)\n", (unsigned long)rd_count);
    } else {
        printf("ramdisk: not found, falling back to bare REPL\n");
    }

    lua_State *L = luaL_newstate();
    if (!L) {
        printf("CRITICAL: Failed to init Lua state\n");
        while (1);
    }

    luaL_openlibs(L);

    /* Hardware globals */
    lua_register(L, "peek32",  lua_peek32);
    lua_register(L, "poke32",  lua_poke32);
    lua_register(L, "sysinfo", lua_sysinfo);

    /* Ramdisk globals + searcher */
    lua_register(L, "rd_find", lua_rd_find);
    lua_register(L, "rd_list", lua_rd_list);
    lua_register(L, "readline", lua_readline);
    lua_register(L, "prompt", lua_prompt);
    lua_register(L, "readkey", lua_readkey);

    virtio_register(L);

    if (rd_valid) {
        rd_register_searcher(L);

        /* Load kernel core */
        uint32_t core_size = 0;
        const char *core = rd_find("nyx/core.lua", &core_size);
        if (core) {
            if (luaL_loadbuffer(L, core, core_size, "@nyx/core.lua") == LUA_OK) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    printf("core.lua error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            }
        }

        /* Try to hand off to nyx/shell.lua */
        uint32_t size = 0;
        const char *shell = rd_find("nyx/shell.lua", &size);
        if (shell) {
            printf("Lua 5.5 Ready\n");
            if (luaL_loadbuffer(L, shell, size, "@nyx/shell.lua") == LUA_OK) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    printf("nyx/shell.lua error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            } else {
                printf("nyx/shell.lua load error: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        }
    } else {
        printf("Lua 5.5 Ready\n");
    }

    /* Fall back to bare C REPL if shell exits or ramdisk missing */
    repl(L);
}