#include "uart.h"
#include <stdint.h>

#define UART_BASE     0x10000000UL
#define UART_THR      (*(volatile uint8_t *)(UART_BASE + 0x00))
#define UART_LSR      (*(volatile uint8_t *)(UART_BASE + 0x05))
#define UART_LSR_THRE 0x20

void uart_init(void) {
    // QEMU virt 16550 UART is pre-initialized, nothing to do
}

void uart_putc(char c) {
    while ((UART_LSR & UART_LSR_THRE) == 0);
    UART_THR = c;
}

void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}