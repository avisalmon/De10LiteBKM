/* The tiny library every program uses: the UART (for printf-style debugging over USB), the text screen, keys.
   It is plain C in a header so one translation unit holds everything (the compiler builds one image). */
#ifndef LIB_H
#define LIB_H
#include "soc.h"

void putc(int c)
{
    while (IO_UART & 1)
        ;
    IO_UART = c;
}

void puts(char *s)
{
    while (*s)
        putc(*s++);
}

/* decimal, no leading zeros */
void putnum(int n)
{
    char buf[12];
    int i = 0;
    if (n < 0) {
        putc('-');
        n = -n;
    }
    do {
        buf[i++] = '0' + n % 10;
        n /= 10;
    } while (n);
    while (i > 0)
        putc(buf[--i]);
}

void puthex(unsigned int v)
{
    int i;
    for (i = 28; i >= 0; i -= 4)
        putc("0123456789ABCDEF"[(v >> i) & 15]);
}

/* ---- the text screen */
void cls(int bg)
{
    int i;
    volatile int *p = (volatile int *)TEXT_BASE;
    for (i = 0; i < TEXT_COLS * TEXT_ROWS; i++)
        p[i] = CELL(' ', 7, bg);
}

void put_cell(int row, int col, int ch, int fg, int bg)
{
    TEXT_AT(row, col) = CELL(ch, fg, bg);
}

void put_str(int row, int col, char *s, int fg, int bg)
{
    while (*s)
        TEXT_AT(row, col++) = CELL(*s++, fg, bg);
}

/* right-aligned decimal in `width` cells */
void put_num(int row, int col, int n, int width, int fg, int bg)
{
    int i;
    for (i = width - 1; i >= 0; i--) {
        TEXT_AT(row, col + i) = CELL((n || i == width - 1) ? '0' + n % 10 : ' ', fg, bg);
        n /= 10;
    }
}

/* ---- keys: held now, and "just pressed this frame" */
int keys_now;
int keys_last;
int keys_pressed;

void keys_poll(void)
{
    keys_last = keys_now;
    keys_now = IO_BUTTONS;
    keys_pressed = keys_now & ~keys_last;
}

/* binary -> BCD for the 7-segment digits (six digits) */
int to_bcd(int n)
{
    int r = 0, shift = 0;
    while (n && shift < 24) {
        r |= (n % 10) << shift;
        n /= 10;
        shift += 4;
    }
    return r;
}

/* wait for the next frame (vertical sync) */
void wait_frame(void)
{
    int f = IO_FRAME;
    while (IO_FRAME == f)
        ;
}
#endif
