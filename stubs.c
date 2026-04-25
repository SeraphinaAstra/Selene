/* stubs.c — Stub Functions */
#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>

/* Memory Symbols from Linker */
extern char __heap_start;
extern char __heap_end;
static char *hptr = &__heap_start;

/* RISC-V Hardware Constants (QEMU virt board) */
#define UART0_BASE  0x10000000
#define UART0_THR   (*(volatile char*)(UART0_BASE + 0x00))
#define UART0_RBR   (*(volatile char*)(UART0_BASE + 0x00))
#define UART0_LSR   (*(volatile char*)(UART0_BASE + 0x05))

/* CLINT Timer registers */
#define CLINT_MTIME 0x0200bff8 
#define TIMER_FREQ  10000000   // 10MHz

/* --- Memory Allocator --- */
void * _sbrk(ptrdiff_t incr) {
    char *prev = hptr;
    if (hptr + incr > &__heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }
    hptr += incr;
    return (void *)prev;
}

/* --- UART Hardware Access --- */
int uart_getc(FILE *file) {
    (void)file;
    while ((UART0_LSR & 0x01) == 0);
    return (unsigned char)UART0_RBR;
}

static int uart_putc(char c, FILE *file) {
    (void)file;
    while ((UART0_LSR & 0x20) == 0);
    UART0_THR = c;
    return (unsigned char)c;
}

static int uart_flush(FILE *file) {
    (void)file;
    /* UART is always flushed when putc returns, nothing to do */
    return 0;
}

/* Picolibc Glue */
static FILE uart_stdio = FDEV_SETUP_STREAM(uart_putc, uart_getc, uart_flush, _FDEV_SETUP_RW);
FILE *const stdin = &uart_stdio;
__strong_reference(stdin, stdout);
__strong_reference(stdin, stderr);

/* --- Timing Support --- */
clock_t times(struct tms *buf) {
    uint64_t t = *(volatile uint64_t*)CLINT_MTIME;
    clock_t ticks = (clock_t)(t / (TIMER_FREQ / 100));
    if (buf) {
        buf->tms_utime = ticks;
        buf->tms_stime = 0;
        buf->tms_cutime = 0;
        buf->tms_cstime = 0;
    }
    return ticks;
}

int gettimeofday(struct timeval *tv, void *tz) {
    if (tv) {
        uint64_t t = *(volatile uint64_t*)CLINT_MTIME;
        tv->tv_sec = t / TIMER_FREQ;
        tv->tv_usec = (t % TIMER_FREQ) / (TIMER_FREQ / 1000000);
    }
    return 0;
}

/* --- I/O and Filesystem Stubs (Fixes Linker Errors) --- */

ssize_t read(int fd, void *buf, size_t count) {
    // For now, only support reading from stdin (UART)
    if (fd == STDIN_FILENO) {
        char *ptr = (char *)buf;
        for (size_t i = 0; i < count; i++) {
            ptr[i] = (char)uart_getc(NULL);
        }
        return count;
    }
    errno = EBADF;
    return -1;
}

ssize_t write(int fd, const void *buf, size_t count) {
    // Redirect all writes to UART
    const char *ptr = (const char *)buf;
    for (size_t i = 0; i < count; i++) {
        if (ptr[i] == '\n') uart_putc('\r', NULL);
        uart_putc(ptr[i], NULL);
    }
    return count;
}

int unlink(const char *pathname) {
    (void)pathname;
    errno = ENOENT; // No filesystem yet
    return -1;
}

int rename(const char *oldpath, const char *newpath) {
    (void)oldpath; (void)newpath;
    errno = ENOENT;
    return -1;
}

/* Other Required Stubs */
void _exit(int status) { (void)status; while(1); }
int open(const char *p, int f, ...) { (void)p; (void)f; errno = ENOENT; return -1; }
int close(int fd) { (void)fd; return -1; }
off_t lseek(int fd, off_t o, int w) { (void)fd; (void)o; (void)w; return -1; }
int fstat(int fd, struct stat *st) { (void)fd; (void)st; return -1; }