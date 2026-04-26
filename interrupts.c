/* interrupts.c — CLINT timer setup and preemptive hook for Selene */
#include <stdint.h>
#include "lua.h"
#include "lauxlib.h"

/* CLINT MMIO addresses (QEMU virt) */
#define CLINT_BASE      0x02000000UL
#define CLINT_MTIME     (*(volatile uint64_t *)(CLINT_BASE + 0xBFF8))
#define CLINT_MTIMECMP  (*(volatile uint64_t *)(CLINT_BASE + 0x4000))

/* 10MHz CLINT clock — ticks per millisecond */
#define CLINT_HZ        10000000UL
#define CLINT_MS        (CLINT_HZ / 1000)

/* Default tick interval: 10ms */
#define DEFAULT_TICK_MS 10

static volatile int preempt_flag = 0;
static uint64_t tick_interval = DEFAULT_TICK_MS * CLINT_MS;
static lua_State *hook_L = NULL;

/* ------------------------------------------------------------------ */
/* Trap handler                                                         */
/* ------------------------------------------------------------------ */

/* Called from your trap vector when mcause == timer interrupt.
 * Rearms mtimecmp and sets the flag — that's all.
 * The actual yield happens in lua_hook on the Lua side.            */
void timer_interrupt_handler(void) {
    CLINT_MTIMECMP = CLINT_MTIME + tick_interval;
    preempt_flag = 1;
}

/* ------------------------------------------------------------------ */
/* Lua debug hook                                                       */
/* ------------------------------------------------------------------ */

/* Fires every N Lua instructions. If the timer set preempt_flag,
 * calls sched_tick() in Lua which yields the current coroutine.   */
static void lua_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (!preempt_flag) return;
    preempt_flag = 0;

    lua_getglobal(L, "sched_tick");
    if (lua_isfunction(L, -1)) {
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            /* swallow scheduler errors — don't crash the kernel */
            lua_pop(L, 1);
        }
    } else {
        lua_pop(L, 1);
    }
}

/* ------------------------------------------------------------------ */
/* Lua API                                                              */
/* ------------------------------------------------------------------ */

/* set_timer_interval(ms) — tune tick rate from Lua */
static int lua_set_timer_interval(lua_State *L) {
    int ms = (int)luaL_checkinteger(L, 1);
    if (ms < 1) ms = 1;
    tick_interval = (uint64_t)ms * CLINT_MS;
    /* rearm immediately */
    CLINT_MTIMECMP = CLINT_MTIME + tick_interval;
    return 0;
}

/* timer_start() — arm timer and enable interrupts when scheduler is ready */
static int lua_timer_start(lua_State *L) {
    (void)L;
    CLINT_MTIMECMP = CLINT_MTIME + tick_interval;
    __asm__ volatile (
        "li t0, 0x80\n"      /* MTIE = bit 7 */
        "csrs mie, t0\n"
        "csrsi mstatus, 0x8\n" /* MIE = bit 3 */
        ::: "t0"
    );
    return 0;
}

/* timer_stop() — disarm timer when scheduler exits */
static int lua_timer_stop(lua_State *L) {
    (void)L;
    CLINT_MTIMECMP = 0xFFFFFFFFFFFFFFFFULL; /* far future — never fires */
    return 0;
}

/* ------------------------------------------------------------------ */
/* Init                                                                 */
/* ------------------------------------------------------------------ */

void interrupts_init(lua_State *L) {
    hook_L = L;

    /* Register Lua API */
    lua_register(L, "set_timer_interval", lua_set_timer_interval);
    lua_register(L, "timer_start", lua_timer_start);
    lua_register(L, "timer_stop", lua_timer_stop);

    /* Install the debug hook — fires every 500 instructions */
    lua_sethook(L, lua_hook, LUA_MASKCOUNT, 500);
}
