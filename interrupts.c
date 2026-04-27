/* interrupts.c — CLINT timer + trap dispatch for Selene */
#include <stdint.h>
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"

#define CLINT_BASE      0x02000000UL
#define CLINT_MTIME     (*(volatile uint64_t *)(CLINT_BASE + 0xBFF8))
#define CLINT_MTIMECMP  (*(volatile uint64_t *)(CLINT_BASE + 0x4000))

#define CLINT_HZ        10000000UL
#define CLINT_MS        (CLINT_HZ / 1000)
#define DEFAULT_TICK_MS 10

/* mcause value for M-mode timer interrupt */
#define MCAUSE_TIMER_INT 0x8000000000000007ULL

static volatile int preempt_flag  = 0;
static uint64_t     tick_interval = DEFAULT_TICK_MS * CLINT_MS;

/* ------------------------------------------------------------------ */
/* Trap dispatcher — called from trap_entry in entry.S                 */
/* ------------------------------------------------------------------ */

void trap_handler(uint64_t mcause) {
    if (mcause == MCAUSE_TIMER_INT) {
        /* rearm and signal — hook will yield on next instruction count */
        CLINT_MTIMECMP = CLINT_MTIME + tick_interval;
        preempt_flag = 1;
    } else {
        /* unexpected trap — print and halt */
        printf("TRAP: mcause=0x%llx — halting\n",
               (unsigned long long)mcause);
        while (1);
    }
}

/* ------------------------------------------------------------------ */
/* Lua debug hook                                                       */
/* Fires every N instructions. If the timer set preempt_flag,          */
/* yields directly from C — no Lua call boundary crossing.            */
/* ------------------------------------------------------------------ */

static void lua_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (!preempt_flag) return;

    /* never yield the main thread — only coroutines are preemptible */
    int is_main = lua_pushthread(L);
    lua_pop(L, 1);
    if (is_main) return;

    preempt_flag = 0;
    lua_yield(L, 0);
}

/* ------------------------------------------------------------------ */
/* Lua API                                                              */
/* ------------------------------------------------------------------ */

static int lua_timer_start(lua_State *L) {
    preempt_flag = 0;
    /* install hook — coroutines created after this inherit it */
    lua_sethook(L, lua_hook, LUA_MASKCOUNT, 500);
    /* arm CLINT */
    CLINT_MTIMECMP = CLINT_MTIME + tick_interval;
    /* enable M-mode timer interrupt */
    __asm__ volatile (
        "li   t0, 0x80\n"
        "csrs mie, t0\n"
        "csrsi mstatus, 0x8\n"
        ::: "t0"
    );
    return 0;
}

static int lua_timer_stop(lua_State *L) {
    /* disable interrupts first so no new flag can be set */
    __asm__ volatile (
        "li   t0, 0x80\n"
        "csrc mie, t0\n"
        "csrci mstatus, 0x8\n"  /* also clear global MIE in mstatus */
        ::: "t0"
    );
    preempt_flag = 0;           /* clear any pending flag */
    CLINT_MTIMECMP = 0xFFFFFFFFFFFFFFFFULL;
    lua_sethook(L, NULL, 0, 0); /* remove hook */
    return 0;
}

static int lua_set_timer_interval(lua_State *L) {
    int ms = (int)luaL_checkinteger(L, 1);
    if (ms < 1) ms = 1;
    tick_interval = (uint64_t)ms * CLINT_MS;
    CLINT_MTIMECMP = CLINT_MTIME + tick_interval;
    return 0;
}


/* ------------------------------------------------------------------ */
/* Init                                                                 */
/* ------------------------------------------------------------------ */

void interrupts_init(lua_State *L) {
    lua_register(L, "timer_start",        lua_timer_start);
    lua_register(L, "timer_stop",         lua_timer_stop);
    lua_register(L, "set_timer_interval", lua_set_timer_interval);
    /* hook and timer armed by timer_start(), not here */
}
