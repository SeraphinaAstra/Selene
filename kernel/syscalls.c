#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/times.h>
#include "uart.h"

clock_t _times(struct tms *buf) { return -1; }

extern char _bss_end;
static char *heap_ptr = NULL;

void *_sbrk(intptr_t increment) {
    if (heap_ptr == NULL)
        heap_ptr = &_bss_end;
    char *prev = heap_ptr;
    heap_ptr += increment;
    return (void *)prev;
}

int _write(int fd, char *buf, int len) {
    for (int i = 0; i < len; i++)
        uart_putc(buf[i]);
    return len;
}

int _read(int fd, char *buf, int len)        { return 0; }
int _close(int fd)                           { return -1; }
int _fstat(int fd, struct stat *st) {
    st->st_mode = 0020000;  // S_IFCHR value, hardcoded
    return 0;
}
int _isatty(int fd)                          { return 1; }
int _lseek(int fd, int off, int dir)         { return 0; }
void _exit(int code)                         { while(1); }
int _kill(int pid, int sig)                  { return -1; }
int _getpid(void)                            { return 1; }