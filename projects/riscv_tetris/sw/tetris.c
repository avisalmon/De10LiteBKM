/* Tetris for the RV32I SoC, in the C subset of tools/cc.py.
 *
 * The well is 10 x 20; every cell is 2 x 2 text characters (16 x 16 pixels), so the well fills 40 of the 60 rows.
 * Controls (game pad): Left / Right move (held: auto-repeat), Up or A rotate, Down soft drop, B hard drop,
 * Start starts / pauses. Over USB the same keys come as letters (see riscv_tetris_top.sv).
 * One update per frame: wait_frame(), poll the keys, move, then redraw only what changed.
 */
#include "soc.h"
#include "lib.h"

#define WELL_W 10
#define WELL_H 20
#define WELL_ROW 10         /* text row of the well's top */
#define WELL_COL 30         /* text column of the well's left edge */
#define FRAME_COLOR 8

/* the seven pieces, four rotations each, as 4 x 4 bit masks: bit r*4+c, row 0 at the top */
int shapes[7][4] = {
    {0x00F0, 0x4444, 0x0F00, 0x2222},   /* I */
    {0x0660, 0x0660, 0x0660, 0x0660},   /* O */
    {0x0270, 0x0232, 0x0720, 0x0262},   /* T */
    {0x0360, 0x0462, 0x0360, 0x0462},   /* S */
    {0x0630, 0x0264, 0x0630, 0x0264},   /* Z */
    {0x0710, 0x0226, 0x0470, 0x0322},   /* J */
    {0x0740, 0x0622, 0x0170, 0x0223},   /* L */
};
int colors[7] = {11, 14, 13, 10, 12, 9, 6};         /* cyan, yellow, magenta, green, red, blue, orange */
int line_points[5] = {0, 40, 100, 300, 1200};

char board[WELL_H][WELL_W];     /* 0 empty, else colour */
int cur, rot, px, py;           /* the falling piece */
int nxt;
int score, lines, level;
int state;                      /* 0 title, 1 playing, 2 paused, 3 game over */
int fall_timer, das_timer, das_dir, drop_timer;
int sound_frames;
int well_dirty, panel_dirty;
int bag[7];
int bag_left;

/* ---------------------------------------------------------------- pieces */
int piece_bit(int type, int r, int row, int col)
{
    return (shapes[type][r] >> (row * 4 + col)) & 1;
}

int fits(int type, int r, int x, int y)
{
    int row, col;
    for (row = 0; row < 4; row++)
        for (col = 0; col < 4; col++)
            if (piece_bit(type, r, row, col)) {
                int bx = x + col, by = y + row;
                if (bx < 0 || bx >= WELL_W || by >= WELL_H)
                    return 0;
                if (by >= 0 && board[by][bx])
                    return 0;
            }
    return 1;
}

/* a shuffled bag of the seven pieces: every piece once before any repeats, like the modern game */
int next_from_bag(void)
{
    int i, k, t;
    if (bag_left == 0) {
        for (i = 0; i < 7; i++)
            bag[i] = i;
        for (i = 6; i > 0; i--) {
            k = (IO_RANDOM & 0x7FFFFFFF) % (i + 1);
            t = bag[i]; bag[i] = bag[k]; bag[k] = t;
        }
        bag_left = 7;
    }
    bag_left--;
    return bag[bag_left];
}

void spawn(void)
{
    cur = nxt;
    nxt = next_from_bag();
    rot = 0;
    px = 3;
    py = 0;
    fall_timer = 0;
    well_dirty = 1;
    panel_dirty = 1;
    if (!fits(cur, rot, px, py)) {
        state = 3;
        sound_frames = 60;
    }
}

void beep(int half, int frames)
{
    IO_BUZZER = half;
    sound_frames = frames;
}

int frames_per_drop(void)
{
    int f = 48 - level * 4;
    return f < 4 ? 4 : f;
}

void lock_piece(void)
{
    int row, col, n = 0, r, w, full;
    for (row = 0; row < 4; row++)
        for (col = 0; col < 4; col++)
            if (piece_bit(cur, rot, row, col) && py + row >= 0)
                board[py + row][px + col] = colors[cur];
    /* clear full rows, top to bottom, moving everything above down */
    for (r = 0; r < WELL_H; r++) {
        full = 1;
        for (col = 0; col < WELL_W; col++)
            if (!board[r][col])
                full = 0;
        if (full) {
            n++;
            for (w = r; w > 0; w--)
                for (col = 0; col < WELL_W; col++)
                    board[w][col] = board[w - 1][col];
            for (col = 0; col < WELL_W; col++)
                board[0][col] = 0;
        }
    }
    if (n) {
        score += line_points[n] * (level + 1);
        lines += n;
        level = lines / 10;
        beep(n == 4 ? 6000 : 9000, 12);
    } else
        beep(30000, 2);
    spawn();
}

/* ---------------------------------------------------------------- drawing */
void draw_cell(int row, int col, int color)
{
    int r = WELL_ROW + row * 2, c = WELL_COL + col * 2;
    int dark = color >= 9 ? color - 8 : color;
    if (color) {
        TEXT_AT(r, c) = CELL(BLOCK_FULL, color, 0);
        TEXT_AT(r, c + 1) = CELL(BLOCK_FULL, color, 0);
        TEXT_AT(r + 1, c) = CELL(BLOCK_FULL, color, 0);
        TEXT_AT(r + 1, c + 1) = CELL(BLOCK_FULL, dark, 0);
    } else {
        TEXT_AT(r, c) = CELL(' ', 0, 0);
        TEXT_AT(r, c + 1) = CELL(' ', 0, 0);
        TEXT_AT(r + 1, c) = CELL(' ', 0, 0);
        TEXT_AT(r + 1, c + 1) = CELL('.', 8, 0);
    }
}

void draw_well(void)
{
    int row, col, prow, pcol;
    for (row = 0; row < WELL_H; row++)
        for (col = 0; col < WELL_W; col++)
            draw_cell(row, col, board[row][col]);
    if (state == 1 || state == 2)
        for (prow = 0; prow < 4; prow++)
            for (pcol = 0; pcol < 4; pcol++)
                if (piece_bit(cur, rot, prow, pcol) && py + prow >= 0)
                    draw_cell(py + prow, px + pcol, colors[cur]);
}

void draw_frame(void)
{
    int r, c;
    for (r = WELL_ROW - 1; r <= WELL_ROW + WELL_H * 2; r++) {
        TEXT_AT(r, WELL_COL - 2) = CELL(BLOCK_FULL, FRAME_COLOR, 0);
        TEXT_AT(r, WELL_COL - 1) = CELL(BLOCK_FULL, FRAME_COLOR, 0);
        TEXT_AT(r, WELL_COL + WELL_W * 2) = CELL(BLOCK_FULL, FRAME_COLOR, 0);
        TEXT_AT(r, WELL_COL + WELL_W * 2 + 1) = CELL(BLOCK_FULL, FRAME_COLOR, 0);
    }
    for (c = WELL_COL - 2; c < WELL_COL + WELL_W * 2 + 2; c++) {
        TEXT_AT(WELL_ROW - 1, c) = CELL(BLOCK_FULL, FRAME_COLOR, 0);
        TEXT_AT(WELL_ROW + WELL_H * 2, c) = CELL(BLOCK_FULL, FRAME_COLOR, 0);
    }
}

void draw_next(void)
{
    int row, col, r0 = WELL_ROW + 4, c0 = WELL_COL + WELL_W * 2 + 6;
    put_str(r0 - 2, c0, "NEXT", 15, 0);
    for (row = 0; row < 4; row++)
        for (col = 0; col < 4; col++) {
            int on = piece_bit(nxt, 0, row, col);
            int ch = on ? BLOCK_FULL : ' ';
            TEXT_AT(r0 + row * 2, c0 + col * 2) = CELL(ch, colors[nxt], 0);
            TEXT_AT(r0 + row * 2, c0 + col * 2 + 1) = CELL(ch, colors[nxt], 0);
            TEXT_AT(r0 + row * 2 + 1, c0 + col * 2) = CELL(ch, colors[nxt], 0);
            TEXT_AT(r0 + row * 2 + 1, c0 + col * 2 + 1) = CELL(ch, colors[nxt], 0);
        }
}

void draw_panel(void)
{
    int c0 = WELL_COL - 26;
    put_str(WELL_ROW + 2, c0, "SCORE", 15, 0);
    put_num(WELL_ROW + 3, c0, score, 8, 14, 0);
    put_str(WELL_ROW + 6, c0, "LEVEL", 15, 0);
    put_num(WELL_ROW + 7, c0, level, 8, 14, 0);
    put_str(WELL_ROW + 10, c0, "LINES", 15, 0);
    put_num(WELL_ROW + 11, c0, lines, 8, 14, 0);
    draw_next();
    IO_HEX = to_bcd(score);
    IO_LEDS = (1 << (level + 1)) - 1;
}

void draw_static(void)
{
    int c0 = WELL_COL - 26, c1 = WELL_COL + WELL_W * 2 + 6;
    cls(0);
    put_str(2, 27, "R I S C - V   T E T R I S", 14, 0);
    put_str(4, 20, "an RV32I CPU written in Verilog, a game written in C", 7, 0);
    draw_frame();
    put_str(WELL_ROW + 16, c0, "MOVE   LEFT RIGHT", 7, 0);
    put_str(WELL_ROW + 17, c0, "TURN   UP OR A", 7, 0);
    put_str(WELL_ROW + 18, c0, "DROP   DOWN", 7, 0);
    put_str(WELL_ROW + 19, c0, "SLAM   B", 7, 0);
    put_str(WELL_ROW + 20, c0, "PAUSE  START", 7, 0);
    put_str(WELL_ROW + 24, c0, "DE10-LITE BKM", 8, 0);
    put_str(WELL_ROW + 25, c0, "PROJECTS/RISCV_TETRIS", 8, 0);
    put_str(WELL_ROW + 16, c1, "SOC", 15, 0);
    put_str(WELL_ROW + 17, c1, "RV32I 25 MHZ", 7, 0);
    put_str(WELL_ROW + 18, c1, "32 KB RAM", 7, 0);
    put_str(WELL_ROW + 19, c1, "80X60 TEXT", 7, 0);
    put_str(WELL_ROW + 20, c1, "3 CLK / INSTR", 7, 0);
}

void draw_message(char *s, int fg)
{
    int r = WELL_ROW + WELL_H - 1, c = WELL_COL + WELL_W - 5, i;
    for (i = 0; i < 10; i++) {
        TEXT_AT(r - 1, c + i) = CELL(' ', 0, fg);
        TEXT_AT(r, c + i) = CELL(' ', 0, fg);
        TEXT_AT(r + 1, c + i) = CELL(' ', 0, fg);
    }
    while (*s)
        TEXT_AT(r, c++) = CELL(*s++, 0, fg);
}

/* ---------------------------------------------------------------- the game */
void new_game(void)
{
    int r, c;
    for (r = 0; r < WELL_H; r++)
        for (c = 0; c < WELL_W; c++)
            board[r][c] = 0;
    score = 0; lines = 0; level = 0;
    bag_left = 0;
    nxt = next_from_bag();
    state = 1;
    das_dir = 0;
    spawn();
}

void try_move(int dx)
{
    if (fits(cur, rot, px + dx, py)) {
        px += dx;
        well_dirty = 1;
    }
}

void try_rotate(void)
{
    int nr = (rot + 1) & 3, k;
    int kicks[5];
    kicks[0] = 0; kicks[1] = -1; kicks[2] = 1; kicks[3] = -2; kicks[4] = 2;
    for (k = 0; k < 5; k++)
        if (fits(cur, nr, px + kicks[k], py)) {
            rot = nr;
            px += kicks[k];
            well_dirty = 1;
            beep(40000, 1);
            return;
        }
}

void step_down(int soft)
{
    if (fits(cur, rot, px, py + 1)) {
        py++;
        if (soft)
            score++;
        well_dirty = 1;
        panel_dirty = soft;
    } else
        lock_piece();
    fall_timer = 0;
}

void hard_drop(void)
{
    while (fits(cur, rot, px, py + 1)) {
        py++;
        score += 2;
    }
    lock_piece();
}

void play_frame(void)
{
    int dir = 0;
    if (keys_pressed & BTN_START) {
        state = 2;
        draw_message("  PAUSED  ", 14);
        return;
    }
    if (keys_now & BTN_LEFT) dir = -1;
    if (keys_now & BTN_RIGHT) dir = 1;
    /* delayed auto-shift: move at once, again after 10 frames, then every 3 */
    if (dir != das_dir) {
        das_dir = dir;
        das_timer = 0;
        if (dir) try_move(dir);
    } else if (dir) {
        das_timer++;
        if (das_timer == 10 || (das_timer > 10 && (das_timer - 10) % 3 == 0))
            try_move(dir);
    }
    if (keys_pressed & (BTN_UP | BTN_A))
        try_rotate();
    if (keys_pressed & BTN_B) {
        hard_drop();
        return;
    }
    if (keys_now & BTN_DOWN) {
        drop_timer++;
        if (drop_timer >= 2) {
            drop_timer = 0;
            step_down(1);
            return;
        }
    } else
        drop_timer = 0;
    fall_timer++;
    if (fall_timer >= frames_per_drop())
        step_down(0);
}

int main(void)
{
    draw_static();
    draw_well();
    draw_message("  START   ", 10);
    state = 0;
    while (1) {
        wait_frame();
        keys_poll();
        if (sound_frames > 0) {
            sound_frames--;
            if (sound_frames == 0)
                IO_BUZZER = 0;
        }
        if (state == 0 || state == 3) {
            if (keys_pressed & (BTN_START | BTN_KEY0)) {
                new_game();
                draw_well();
                draw_panel();
            }
        } else if (state == 2) {
            if (keys_pressed & BTN_START) {
                state = 1;
                well_dirty = 1;
            }
        } else {
            play_frame();
            if (well_dirty) {
                draw_well();
                well_dirty = 0;
            }
            if (panel_dirty) {
                draw_panel();
                panel_dirty = 0;
            }
            if (state == 3)
                draw_message("GAME  OVER", 12);
        }
    }
    return 0;
}
