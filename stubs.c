/* stubs.c — Stub Functions */
#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

extern lua_State *global_L;

#define MAX_FD 32
typedef struct {
    int used;
    char path[256];
    uint32_t offset;
    uint32_t size;
} fd_entry_t;

static fd_entry_t fd_table[MAX_FD];
static int next_fd = 3; // 0=stdin, 1=stdout, 2=stderr

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

int uart_kbhit(FILE *file) {
    (void)file;
    return (UART0_LSR & 0x01) != 0;
}

int uart_getc_nb(FILE *file) {
    (void)file;
    if (!(UART0_LSR & 0x01)) return -1;
    return (unsigned char)UART0_RBR;
}

int uart_putc(char c, FILE *file) {
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

int open(const char *pathname, int flags, ...) {
    if (!global_L) {
        errno = EIO;
        return -1;
    }
    
    // Check if file exists first
    lua_getglobal(global_L, "fs");
    lua_getfield(global_L, -1, "exists");
    lua_pushstring(global_L, pathname);
    
    if (lua_pcall(global_L, 1, 1, 0) != LUA_OK || !lua_toboolean(global_L, -1)) {
        lua_pop(global_L, 2); // pop boolean result and fs table
        errno = ENOENT;
        return -1;
    }
    lua_pop(global_L, 1); // pop exists result

    // Read entire file to get size (since we can't get inode)
    lua_getglobal(global_L, "fs");
    lua_getfield(global_L, -1, "read");
    lua_pushstring(global_L, pathname);
    
    if (lua_pcall(global_L, 1, 1, 0) != LUA_OK) {
        lua_pop(global_L, 1);
        errno = ENOENT;
        return -1;
    }
    
    size_t size = lua_rawlen(global_L, -1);
    lua_pop(global_L, 1);
    
    // Find free fd
    int fd = next_fd++;
    if (fd >= MAX_FD) {
        errno = EMFILE;
        return -1;
    }
    
    fd_table[fd].used = 1;
    strncpy(fd_table[fd].path, pathname, sizeof(fd_table[fd].path) - 1);
    fd_table[fd].path[sizeof(fd_table[fd].path) - 1] = '\0';
    fd_table[fd].offset = 0;
    fd_table[fd].size = size;
    
    return fd;
}

int close(int fd) {
    if (fd < 3 || fd >= MAX_FD || !fd_table[fd].used) {
        errno = EBADF;
        return -1;
    }
    
    fd_table[fd].used = 0;
    return 0;
}

ssize_t read(int fd, void *buf, size_t count) {
    if (fd == STDIN_FILENO) {
        char *ptr = (char *)buf;
        for (size_t i = 0; i < count; i++) {
            ptr[i] = (char)uart_getc(NULL);
        }
        return count;
    }
    
    if (fd < 3 || fd >= MAX_FD || !fd_table[fd].used || !global_L) {
        errno = EBADF;
        return -1;
    }
    
    lua_getglobal(global_L, "fs");
    lua_getfield(global_L, -1, "read");
    lua_pushstring(global_L, fd_table[fd].path);
    
    if (lua_pcall(global_L, 1, 1, 0) != LUA_OK) {
        lua_pop(global_L, 1);
        errno = EIO;
        return -1;
    }
    
    size_t total_len;
    const char *data = lua_tolstring(global_L, -1, &total_len);
    
    // Handle offset and count since fs.read() returns entire file
    size_t available = total_len - fd_table[fd].offset;
    size_t read_len = (count < available) ? count : available;
    
    if (read_len > 0) {
        memcpy(buf, data + fd_table[fd].offset, read_len);
        fd_table[fd].offset += read_len;
    }
    
    lua_pop(global_L, 1);
    
    return read_len;
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
    
    if (fd < 3 || fd >= MAX_FD || !fd_table[fd].used || !global_L) {
        errno = EBADF;
        return -1;
    }
    
    // For write: we need to read-modify-write since fs.write() replaces entire file
    lua_getglobal(global_L, "fs");
    lua_getfield(global_L, -1, "read");
    lua_pushstring(global_L, fd_table[fd].path);
    
    // Ignore read errors (file might not exist yet for writing)
    int read_ok = lua_pcall(global_L, 1, 1, 0) == LUA_OK;
    
    size_t current_size = 0;
    const char *current_data = NULL;
    if (read_ok) {
        current_data = lua_tolstring(global_L, -1, &current_size);
    }
    
    // Calculate new file size
    size_t new_size = fd_table[fd].offset + count;
    if (new_size < current_size) new_size = current_size;
    
    // Use stack buffer for small writes to avoid heap allocation
    #define SMALL_WRITE_THRESHOLD 512
    char stack_buf[SMALL_WRITE_THRESHOLD];
    char *new_buf;
    
    if (new_size <= SMALL_WRITE_THRESHOLD) {
        new_buf = stack_buf;
    } else {
        new_buf = malloc(new_size);
        if (!new_buf) {
            if (read_ok) lua_pop(global_L, 1);
            errno = ENOMEM;
            return -1;
        }
    }
    
    // Copy existing data
    if (current_data && current_size > 0) {
        memcpy(new_buf, current_data, current_size);
    }
    
    // Write new data at offset
    memcpy(new_buf + fd_table[fd].offset, buf, count);
    
    // Call fs.write() with full new content
    lua_getglobal(global_L, "fs");
    lua_getfield(global_L, -1, "write");
    lua_pushstring(global_L, fd_table[fd].path);
    lua_pushlstring(global_L, new_buf, new_size);
    
    if (new_size > SMALL_WRITE_THRESHOLD) {
        free(new_buf);
    }
    if (read_ok) lua_pop(global_L, 1); // pop read result
    
    if (lua_pcall(global_L, 2, 0, 0) != LUA_OK) {
        lua_pop(global_L, 1);
        errno = EIO;
        return -1;
    }
    
    lua_pop(global_L, 1); // pop fs table
    
    fd_table[fd].offset += count;
    if (fd_table[fd].offset > fd_table[fd].size) {
        fd_table[fd].size = fd_table[fd].offset;
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
off_t lseek(int fd, off_t offset, int whence) {
    if (fd < 3 || fd >= MAX_FD || !fd_table[fd].used) {
        errno = EBADF;
        return -1;
    }
    
    switch (whence) {
        case SEEK_SET: 
            fd_table[fd].offset = offset; 
            break;
        case SEEK_CUR: 
            fd_table[fd].offset += offset; 
            break;
        case SEEK_END: 
            fd_table[fd].offset = fd_table[fd].size + offset; 
            break;
        default: 
            errno = EINVAL; 
            return -1;
    }
    
    return fd_table[fd].offset;
}

int fstat(int fd, struct stat *st) {
    if (fd < 3) {
        memset(st, 0, sizeof(struct stat));
        st->st_mode = S_IFCHR;
        return 0;
    }
    
    if (fd >= MAX_FD || !fd_table[fd].used || !global_L) {
        errno = EBADF;
        return -1;
    }
    
    // No fs.stat() available, use cached values from open()
    (void)global_L;
    
    memset(st, 0, sizeof(struct stat));
    st->st_ino = fd; // Use fd as fake inode number
    st->st_size = fd_table[fd].size;
    st->st_mode = S_IFREG | 0644;
    st->st_nlink = 1;
    
    return 0;
}
