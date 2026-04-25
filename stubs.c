#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>

extern char __heap_start;
extern char __heap_end;
static char *hptr = &__heap_start;

void * _sbrk(ptrdiff_t incr) {
    char *prev = hptr;
    if (hptr + incr > &__heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }
    hptr += incr;
    return (void *)prev;
}

#define UART0_BASE  0x10000000
#define UART0_THR   (*(volatile char*)(UART0_BASE + 0x00))
#define UART0_RBR   (*(volatile char*)(UART0_BASE + 0x00))
#define UART0_LSR   (*(volatile char*)(UART0_BASE + 0x05))

static int uart_putc(char c, FILE *file) {
    (void)file;
    while ((UART0_LSR & 0x20) == 0);
    UART0_THR = c;
    return (unsigned char)c;
}

static int uart_getc(FILE *file) {
    (void)file;
    while ((UART0_LSR & 0x01) == 0);
    return (unsigned char)UART0_RBR;
}

static FILE uart_stdio = FDEV_SETUP_STREAM(uart_putc, uart_getc, NULL, _FDEV_SETUP_RW);
FILE *const stdin = &uart_stdio;
__strong_reference(stdin, stdout);
__strong_reference(stdin, stderr);

ssize_t read(int fd, void *buf, size_t count) {
    if (fd == STDIN_FILENO) {
        char *ptr = (char *)buf;
        for (size_t i = 0; i < count; i++) {
            char c = (char)uart_getc(NULL);
            if (c == '\r') c = '\n';
            ptr[i] = c;
            uart_putc(c, NULL); 
            if (c == '\n') return i + 1;
        }
        return count;
    }
    return -1;
}

ssize_t write(int fd, const void *buf, size_t count) {
    if (fd == STDOUT_FILENO || fd == STDERR_FILENO) {
        const char *ptr = (const char *)buf;
        for (size_t i = 0; i < count; i++) {
            if (ptr[i] == '\n') uart_putc('\r', NULL);
            uart_putc(ptr[i], NULL);
        }
        return count;
    }
    return -1;
}

clock_t times(struct tms *buf) { return (clock_t)-1; }
int gettimeofday(struct timeval *tv, void *tz) { return 0; }
void _exit(int status) { while(1); }
int open(const char *p, int f, ...) { return -1; }
int close(int fd) { return -1; }
off_t lseek(int fd, off_t o, int w) { return -1; }
int unlink(const char *p) { return -1; }
int rename(const char *o, const char *n) { return -1; }