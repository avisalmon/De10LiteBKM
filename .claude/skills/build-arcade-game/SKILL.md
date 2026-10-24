---
name: build-arcade-game
description: >
  Build a playable arcade game in Verilog on the DE10-Lite with the LCD / game-pad shield (Pac-Man, Snake, Breakout,
  Space Invaders, Tetris, a maze game...): screen layout, a per-frame game-logic state machine, tile movement,
  enemy AI, sprites drawn from math and bitmaps, score text, buzzer sound, joystick input, and testing it without
  hands (a self-playing testbench that renders frames; USB letters to play the real board). Proven with Pac-Man.
  TRIGGER: "make a game", "build a game", "arcade game", "pacman", "pac-man", "snake", "breakout", "tetris",
  "space invaders", "pong", "maze game", "ghosts", "game on the screen", "play on the board".
---

# Build an arcade game

Proven on the board (2026-10-24): **Pac-Man**, the arcade maze (28 x 31 tiles, 244 dots), four ghosts with the
arcade's targeting, scatter/chase, frightened mode, eyes going home, levels, lives, high score, the intro tune.
9,504 LEs (19 %), 8 multipliers, timing met at 25 MHz; built from scratch in one session, tested in simulation and on
the board without a human. The project, its three pages and its review log: `projects/pacman/` (the `make-project`
standard); a private try-out can live in `my_designs/<game>/` (git-ignored).

## The plan (same for every game)

```
projects/<game>/assets/make_*.py   Python writes the tables: tile map (as a .sv case table), pictures ($readmemb file)
projects/<game>/src/<game>_top.sv   board: pll25, Screens_dispaly, gamepad, debounce, debug_link, jtag_uart
                 src/<game>_logic.sv  the game: one update per frame
                 src/<game>_draw.sv   the screen: a colour for every pixel, from the game state
                 src/<game>_sound.sv  buzzer effects
                 sim/tb_<game>.sv     plays the game, renders frames to PPM, checks rules
python scripts/new_project.py projects/<game> <game>_top --lib display gamepad debug font sevenseg debounce
```
`src/extra.qsf`: `set_global_assignment -name MISC_FILE assets/<pic>.bin` (so the .qar carries the data files).
Loop: `python scripts/sim.py projects/<game>/sim/tb_<game>.sv` -> look at the PPMs -> `de10.py build` -> `program`
-> play over USB + `de10.py screen` / `cam` -> hand the joystick to the user.

## Screen

* The scan is 640 x 480 at 25 MHz (`pxl_x`, `pxl_y`); the debug capture and a sensible art grid are **320 x 240**:
  `lx = pxl_x[9:1]`, `ly = pxl_y[8:1]` (each art pixel = 2 x 2 scan pixels).
* The LCD panel is 800 x 480: the picture fills the middle 640 columns, the 80-column strips at each side are never
  written and show **white**. Not a bug in your game; the screen capture shows only the picture.
* 8 x 8 tiles on the 320 x 240 grid = 40 x 30 cells. Pac-Man: maze 224 wide in columns 48..271, panels of 6 text
  cells each side; the maze is 248 tall, so 4 rows are cut top and bottom (`my = ly + 4`).
* Memories answer one clock late: address them with the **next** scan pixel, `nx = pxl_x + 1`, decide the rest
  from the current pixel (see `build-rom`). Pictures: `$readmemb` with 2-digit entries for a 2-bit ROM (hex into a
  2-bit ROM = one warning per line, 61,000 warnings).
* Layers in one `always_comb` priority chain: sprites (front) -> player -> text -> items -> walls -> black.

## Game logic: one update per frame

* `tick` = the falling edge of `VGA_VS` in the 25 MHz domain (inside the vertical blank: ~36,000 clocks before
  the next visible line; a whole Pac-Man frame update takes a few hundred).
* **Game states** (a frame counter `gtimer` per state): ATTRACT ("PUSH START") -> FILL (rewrite the level RAM, 1024
  clocks) -> READY (2 s; 4.3 s with the intro tune) -> PLAY -> FREEZE (ghost eaten, 0.5 s) / DYING (1 s) -> DEATH
  (animation) -> READY or GAME OVER; LEVEL (maze flashes) -> FILL.
* **Micro-sequencer** inside PLAY: one actor at a time, one pixel step at a time, a few clocks per step: load the
  actor's registers, ask the tile table about the next tile (one query port, answer next clock), move, write back,
  then a collision pass, then timers. Sequential is small and easy to debug; the frame has time to spare.
* Start the level RAM fill after `locked` (writes before the PLL locks are lost, gotcha 6).

## Tile movement (any maze or grid game)

* Position in pixels; tile = `x >> 3`; **decisions only at the tile centre** (`x[2:0] == 4 && y[2:0] == 4`),
  between centres keep going. Reversing is allowed anywhere.
* Player: remember the last direction asked for (`want`); at a centre take it if that tile is open, else keep going,
  stop if the way ahead is a wall. This makes turning before the corner work, as in the arcade.
* Speed without fractions: `acc += speed` (1/16 pixel per frame), move `acc >> 4` pixels this frame (0..2).
  Pac-Man numbers (60 fps, 8-pixel tiles): Pac-Man 16 (18 with frightened ghosts), ghosts 15 (16-17 later levels),
  ghosts in the tunnel 7, frightened 8, eyes 32, in/out of the house 8.
* Tunnel: the row is open past the edges; `x = (x == 0) ? 223 : x - 1`. Out-of-maze tiles count as walls elsewhere.
* Collisions by pixel distance (`|dx| <= 4 && |dy| <= 4`), not "same tile": two actors crossing can swap tiles in
  one frame and never share one.

## Enemy AI (the arcade's ghost rules, reusable for any chaser)

At each tile centre a ghost tries up, left, down, right (that order breaks ties), never backwards, never into a
wall, and takes the open way whose next tile is **closest (squared distance) to its target**:

| Ghost | Chase target | Scatter corner |
|---|---|---|
| Blinky (red) | Pac-Man's tile | top right (25, -3) |
| Pinky (pink) | 4 tiles ahead of Pac-Man (facing up: also 4 left, the arcade bug) | top left (2, -3) |
| Inky (cyan) | the point 2 ahead of Pac-Man, doubled away from Blinky: `2*P2 - B` | bottom right (27, 31) |
| Clyde (orange) | Pac-Man if 8+ tiles away, else his corner | bottom left (0, 31) |

* Mode timer: scatter 7 s, chase 20, scatter 7, chase 20, scatter 5, chase 20, scatter 5, chase forever; every
  mode change reverses all ghosts. Paused while frightened.
* Power pellet: ghosts reverse and turn blue for 6 s (less each level; flashing the last 2 s); they pick a random
  open way at each centre (LFSR). Eaten: 200, 400, 800, 1600; the eyes target the door, then enter, then leave.
* House: states HOUSE -> LEAVE (to the door's x, then up) -> ACTIVE -> EYES -> ENTER -> LEAVE. Moves inside the
  house ignore walls. Release: Pinky at once, Inky after 30 dots or 4 s, Clyde after 60 dots or 8 s.

## Sprites from math (no picture memory)

* Centre on a half pixel: `dx2 = 2*(mx - x) + 1` (odd numbers), a 13-pixel disc is `dx2*dx2 + dy2*dy2 <= 169`.
* A wedge (Pac-Man's mouth, a pie, a radar) with half-opening `t` in any direction: rotate into (a = along, b =
  across) and test `a*sin(t) > |b|*cos(t)` (x16 integers). Works up to 180 degrees, so the death animation is the
  same test with `t` growing to 180.
* Small bitmaps as a function returning a row: `function [13:0] body_row(input [3:0] r, input frame)`; animate
  with `frame[3]`. Eyes: two whites shifted one pixel toward the direction, pupils at the leading edge.
* Every sprite gets its own module instance (`ghost_sprite` x 4 with a colour parameter); the draw module ORs and
  prioritises the `hit` outputs.

## Text, score, numbers

* `font8x8` (`--lib font`): one instance, fed by whichever text layer covers the pixel (panel on the screen's grid,
  messages on the maze's grid). Strings: `function [7:0] str6(input [47:0] s, input [2:0] i) = s[8*(5-i) +: 8]`.
* Keep score, high score and level in **BCD**: a 6-digit BCD adder (digit + digit + carry, +6 when > 9) means no
  dividers anywhere; the 7-segment shows the same digits (`seven_segment` per nibble, blank leading zeros).
  BCD numbers compare correctly as plain binary (high score).

## Sound on the buzzer

The shield's buzzer (ARDUINO_IO[12] in the lib layout) takes a square wave: count to `half = 25e6 / (2 * f)` and
toggle. Set `half` once per frame from the highest-priority running effect: death (falling warble), a tune (table
of {half, frames}, a 1-frame gap between notes), ghost eaten (rising sweep), power, dot ("waka": two pitches,
alternating order per dot). The Pac-Man intro: B4 B5 F#5 D#5 B5 F#5 D#5 / C5 C6 G5 E5 C6 G5 E5 / again on B /
D#5 E5 F5 F5 F#5 G5 G5 G#5 A5 B5, 8 frames per 16th, 256 frames in all.

## Input

* Game pad at 50 MHz (`gamepad`, `debounce`), two flip-flops into the 25 MHz game domain (slow levels: enough).
* Start = the pad's Start or KEY0; directions: one at a time, a fixed priority.
* **USB letters** for testing (read `rx_valid` / `rx_data` in the top; debug_link already uses ? F f B b):
  u l d r steer, s start (hold the request until the next tick), p pause, i invincible, m mute.

## Testing without hands

* **Testbench** (`sim/tb_<game>.sv`): instantiate logic + draw, drive `tick` every ~600 clocks, render the screen
  like the board's capture (every 2nd scan pixel to a 320 x 240 PPM; start each line with `pxl_x = -1` so the
  memories are primed). Script: attract -> start -> READY -> moving and scoring -> 3,000 frames of random steering
  with the player invincible -> checks: no X in the state, every enemy left home, no enemy stalls for 8 frames
  while playing, the score grew, a life is lost when not invincible. Look at the PPMs (Pillow -> PNG).
* **Board**: `de10.py send s`, `send u`, ... then `de10.py screen x.png`; count pixels of a colour to check a
  message (yellow READY!, life icons). `de10.py cam` for the real LCD and the 7-segment.
* Then ask the user to play: joystick feel, sound, fun. Those only a human can judge.

## Traps met building Pac-Man

* `inside` is a SystemVerilog keyword (set membership): a signal named `inside` is a syntax error.
* A comparison is as wide as its widest operand: `(a * b) > (c * d)` with 6-bit operands overflows. Assign the
  products to wide wires first (`wire signed [11:0] p = a * b;`).
* `f(x)[7:0]` (part-select of a function call) is illegal Verilog: assign the call to a wire, then select.
* In a clocked block, two non-blocking writes to the state register in one clock: the last wins. A "chose a way,
  go to MOVE" followed by "else try the next way" overwrote the choice; give every path exactly one assignment.
* Frightened ghosts move every other frame: a "did it move this frame" test reports them stuck; test over 8 frames.
* Quartus warns 16248 "VGA_HS/VGA_VS too close to ADC pins": the board's fixed layout; harmless here.
