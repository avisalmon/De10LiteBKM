/* The C compiler's test suite: runs on the simulator and on the board. Every check prints its number and
   PASS/FAIL on the UART; the exit code is the number of failures. Also a benchmark of the toolchain's output. */
#include "soc.h"
#include "lib.h"

int failures;
int checks;

int g_int = 42;
char g_char = 'x';
unsigned char g_uchar = 200;
int g_arr[5] = {1, 2, 3, 4, 5};
char g_str[] = "hello";
char *g_ptr = "world";
int g_grid[3][4] = {{1, 2, 3, 4}, {5, 6, 7, 8}, {9, 10, 11, 12}};
int g_zero;
int g_bss[10];
#define SQUARE(x) ((x) * (x))
#define LIMIT 100

void check(int cond)
{
    checks++;
    puts(cond ? "ok   " : "FAIL ");
    putnum(checks);
    putc('\n');
    if (!cond)
        failures++;
}

int add(int a, int b) { return a + b; }
int fact(int n) { return n <= 1 ? 1 : n * fact(n - 1); }
int sum_arr(int *p, int n)
{
    int s = 0, i;
    for (i = 0; i < n; i++)
        s += p[i];
    return s;
}
void fill(char *dst, int n, char c)
{
    while (n-- > 0)
        *dst++ = c;
}
int many(int a, int b, int c, int d, int e, int f, int g, int h) { return a + b + c + d + e + f + g + h; }
int strlen_(char *s)
{
    int n = 0;
    while (s[n])
        n++;
    return n;
}

int main(void)
{
    int i, j, x, y;
    int loc[8];
    char buf[16];
    unsigned int u;
    unsigned char uc;
    char c;
    int *p;

    /* 1 arithmetic */
    x = 7; y = -3;
    check(x + y == 4 && x - y == 10 && x * y == -21 && x / y == -2 && x % y == 1 && -x == -7);
    /* 2 runtime multiply, divide, modulo with various signs and large values */
    check(123456 * 789 == 97406784 && -100 / 7 == -14 && -100 % 7 == -2 && 100 / -7 == -14 && 100 % -7 == 2);
    u = 4000000000u;
    check(u / 3 == 1333333333u && u % 7 == 4000000000u % 7 && (u >> 1) == 2000000000u);
    /* 3 shifts and bit operations */
    x = 0x12345678;
    check((x >> 4) == 0x01234567 && (x << 4) == 0x23456780 && (x & 0xFF) == 0x78 && (x | 1) == 0x12345679 &&
          (x ^ x) == 0 && ~0 == -1 && (-16 >> 2) == -4);
    /* 4 comparisons and logic */
    check((3 < 5) && !(5 < 3) && (5 >= 5) && (4 <= 5) && (3 != 4) && (3 == 3) && ((0 || 2) == 1) && ((3 && 0) == 0));
    check(-1 < 1 && (unsigned)-1 > 1u && (unsigned char)255 == 255 && (char)255 == -1);
    /* 5 globals and arrays */
    check(g_int == 42 && g_char == 'x' && g_uchar == 200 && g_arr[2] == 3 && g_str[1] == 'e' && g_str[5] == 0 &&
          g_ptr[0] == 'w' && g_grid[1][2] == 7 && g_grid[2][3] == 12 && g_zero == 0 && g_bss[9] == 0);
    g_arr[2] = 30;
    g_grid[2][1]++;
    check(g_arr[2] == 30 && sum_arr(g_arr, 5) == 42 && g_grid[2][1] == 11 && sizeof(g_grid) == 48 &&
          sizeof(int) == 4 && sizeof(char) == 1 && sizeof(buf) == 16);
    /* 6 locals, pointers, pointer arithmetic */
    for (i = 0; i < 8; i++)
        loc[i] = i * i;
    p = loc;
    p += 3;
    check(*p == 9 && p[1] == 16 && *(p - 1) == 4 && p - loc == 3 && &loc[7] - p == 4 && (p < &loc[7]));
    fill(buf, 15, 'a');
    buf[15] = 0;
    buf[3] = 'b';
    check(strlen_(buf) == 15 && buf[3] == 'b' && buf[4] == 'a');
    /* 7 functions: recursion, 8 arguments, nested calls */
    check(fact(6) == 720 && add(fact(3), add(1, 2)) == 9 && many(1, 2, 3, 4, 5, 6, 7, 8) == 36);
    /* 8 control flow: while, do, for, break, continue, switch, ternary */
    x = 0;
    for (i = 0; i < 10; i++) {
        if (i == 2) continue;
        if (i == 7) break;
        x += i;
    }
    check(x == 0 + 1 + 3 + 4 + 5 + 6);
    i = 0; x = 0;
    do { x += ++i; } while (i < 4);
    check(x == 10 && i == 4);
    x = 0;
    for (i = 0; i < 5; i++)
        switch (i) {
        case 0: x += 1; break;
        case 1:
        case 2: x += 10; break;
        case 4: x += 1000; break;
        default: x += 100;
        }
    check(x == 1121);
    /* 9 compound assignment, ++/--, chars */
    x = 10; x += 5; x -= 3; x *= 2; x /= 4; x %= 4; x <<= 3; x >>= 1; x |= 1; x &= 0xF; x ^= 2;
    check(x == 11);     /* 15 12 24 6 2 16 8 9 9 11 */
    c = 100; c += 100;          /* wraps: signed char */
    uc = 250; uc += 10;
    check(c == -56 && uc == 4);
    i = 5; j = i++ + ++i;       /* 5 + 7 */
    check(j == 12 && i == 7);
    /* 10 macros, strings, the screen and I/O registers */
    check(SQUARE(3 + 1) == 16 && LIMIT == 100 && CELL('A', 15, 1) == 0x1F41);
    TEXT_AT(0, 0) = CELL('C', 14, 0);
    TEXT_AT(1, 1) = CELL(BLOCK_FULL, 2, 0);
    IO_HEX = 0x00C0DE;
    IO_LEDS = checks;
    x = IO_FRAME;
    y = IO_CYCLES;
    check(x >= 0 && y >= 0);
    puts("checks ");
    putnum(checks);
    puts(" failures ");
    putnum(failures);
    putc('\n');
    return failures;
}
