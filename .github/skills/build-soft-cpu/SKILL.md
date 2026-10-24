---
name: build-soft-cpu
description: >
  Put a small RISC-V (RV32I) CPU with RAM, a memory-mapped text screen and I/O registers into the DE10-Lite, write
  programs for it in C or assembly with the BKM's own Python toolchain (assembler, small C compiler, instruction-set
  simulator), prove the hardware against the simulator instruction by instruction, and load new programs over
  JTAG in seconds without rebuilding. Proven: projects/riscv_tetris (Tetris in C on the soft CPU).
  TRIGGER: "CPU", "soft CPU", "soft core", "RISC-V", "riscv", "RV32I", "processor", "SoC", "run C on the FPGA",
  "write a program for the FPGA", "assembler", "compiler", "instruction set", "memory mapped", "MMIO", "text mode",
  "text screen", "Nios alternative", "microcontroller on the FPGA".
---

# Build a soft CPU and program it in C

Proven on the board (2026-10-24): `projects/riscv_tetris`. A multi-cycle RV32I CPU (3.1-3.4 clocks per instruction
at 25 MHz, about 7.5 MIPS), 32 KB RAM, an 80 x 60 text screen with 16 colours, 10 I/O registers, and Tetris written
in C. The whole toolchain is three Python files in the project (`tools/asm.py`, `tools/cc.py`, `tools/rv32sim.py`):
no gcc download, and every piece is small enough to read. 10,658 LEs (21 %), 76 % of the block memory (most of it
the debug screen capture), timing met.

## Reuse it (copy, don't rewrite)

```text
projects/riscv_tetris/src/rv32_cpu.sv      the CPU: one bus, req/ack, trace port
                      src/soc_ram.sv       32 KB RAM, byte enables; IMPL "IP" = altsyncram editable over JTAG, "SIM" = array
                      src/rv32_soc.sv      address decode, the text RAM, the I/O registers, the UART
                      src/text_screen.sv   80 x 60 cells from the text RAM + font8x8 + block glyphs + palette
                      src/riscv_tetris_top.sv   board wiring, USB letters -> keys / CPU hold / reset
                      tools/memmap.py      THE memory map (one place): writes sw/soc.h; tests check the Verilog agrees
                      tools/asm.py cc.py rv32sim.py build.py load.py trace_compare.py play_test.py
                      sw/crt0.s lib.h      start-up, __mul / __div / __mod, putc / puts / putnum, screen and key helpers
                      sim/tb_soc.sv        runs a program on the RTL, writes the trace, the UART text and the screen
```
For a new design: copy `src/rv32_*.sv`, `soc_ram.sv`, `text_screen.sv`, `tools/`, `sw/crt0.s`, `sw/lib.h`; change
`tools/memmap.py` (add registers), `rv32_soc.sv` (decode them) and the top; keep `tests/test_riscv_tetris.py`'s
shape as the project's test.

## The bus and the CPU

* One port: `bus_req` with `addr / we / wdata / be` held until `bus_ack`; the slave acks one clock later; a read's
  data is valid in the ack clock; a write happens in the first req clock (`first = req && !ack`). The CPU drops req
  after the ack, so a slave's `ack <= first` is all the handshake it needs. Any RAM / register with one clock of
  latency fits; a slow slave just delays its ack.
* States FETCH -> EXEC -> (MEM) -> FETCH. No pipeline, no hazards, no CSRs, no interrupts: software polls
  FRAME / BUTTONS. ecall / ebreak / illegal -> `halted` (LEDR9 blinks). Misaligned access is not supported: the
  compiler never emits one.
* Registers in flip-flops, reset to 0 (so the hardware starts exactly like the simulator).
* No multiplier: `*`, `/`, `%` are `__mul` (shift-add, up to 32 steps) and `__udivmod` (restoring, 32 steps) in
  `crt0.s`; the compiler turns `x * 2^n` into a shift and `x * c` with up to three set bits into shifts and adds.

## The memory map discipline

`tools/memmap.py` holds the addresses and writes `sw/soc.h` (`IO_FRAME`, `TEXT_AT(r, c)`, `CELL(ch, fg, bg)` ...).
`rv32_soc.sv` decodes `addr[31:28]` (0 RAM, 1 TEXT, 2 I/O) and `addr[7:2]` for the register; the test
`test_memory_map_is_the_same_in_python_and_verilog` greps the Verilog for every register's word index. Change the
map in one file, run the test, and the C header, the simulator and the Verilog cannot drift.

## The toolchain

* `tools/asm.py prog.s -o build/prog`: RV32I + pseudo-instructions, `%hi/%lo`, numeric local labels (`1:`, `1b`,
  `2f`), `.word/.byte/.asciz/.space/.align/.equ`, expressions. Writes `.hex` (8192 words, for `$readmemh` and the
  simulator), `.mif` (Quartus and the memory editor) and `.sym`.
* `tools/cc.py game.c -o game.s`: the C subset in its docstring (int / char / unsigned, pointers, 1-D and 2-D
  arrays, globals with initialisers, functions with up to 8 arguments, all control flow incl. switch, all operators
  but the comma, #include / #define with arguments / #ifdef). Everything ends in a0, temporaries on the stack: slow but
  predictable code you can read next to the C. What it does not do it refuses with a line number (struct, typedef,
  float, long, function pointers, local array initialisers).
* `tools/build.py sw/x.c [--assets]`: crt0 + C + asm -> `build/x.hex / .mif / .s / .sym`; `--assets` copies the
  image into `assets/` (the FPGA build initialises the RAM from `assets/<name>.mif`).
* `tools/rv32sim.py build/x.hex --frames N --keys "10:start,30:left*12,60:b" --screen out.txt --trace x.trc`:
  the instruction-set simulator with the text screen, the keys, FRAME / RANDOM / UART / EXIT; a scripted game of
  1,000 frames runs in 10 s because a `wait_frame` spin is skipped (off while tracing).

## Proving the hardware: lock-step

Both the simulator and `sim/tb_soc.sv` write "pc rd value" for every register write and "pc W addr value be" for
every store; `tools/trace_compare.py` must say identical (stores compared on the enabled bytes; values read from
FRAME / CYCLES / RANDOM are marked `~` by the simulator and only their pc / rd must match). Run it on the ISA test
(`sw/test_isa.s`, every instruction class), the C suite (`sw/test_c.c`, 19 checks of the compiler) and the game.
Tetris: 294,803 trace lines identical. Then the board: load, send keys, capture the screen, read the digits.

## Programs on the board in seconds

The RAM is `altsyncram` with `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=PROG`. `tools/load.py build/x.mif`: sends 'H'
(the top holds the CPU in reset), writes the RAM with `scripts/mem_edit.tcl` (In-System Memory Content Editor,
~6 s), sends 'R' (reset, run from 0). No Quartus rebuild for a software change; `crt0.s` zeroes `.bss` at start so a
reset without a reload behaves.

## The text screen

4,800 x 16-bit cells in a `ram_dp` (CPU writes, the screen reads): char, fg, bg nibbles. The screen asks for the
NEXT pixel's cell (one clock of RAM latency), `font8x8` gives the glyph row, chars 0x80..0x83 are block glyphs made
in logic (full, inner, shade, frame) for games. The USB capture is 320 x 240 (every other pixel): a checkerboard
glyph disappears in it; draw frames with the full block.

## Traps met (in the gotchas too)

* `alt ? $signed(x) >>> n : x >> n` shifts LOGICALLY: the unsigned branch makes the whole ?: unsigned and that
  context reaches the `>>>`. Compute the arithmetic shift on its own `wire signed` first.
* `cell` is a Verilog keyword (config blocks), like `design`, `instance`, `library`, `use`.
* Icarus rejects a declaration inside an unnamed `begin ... end` of a loop: declare at module scope.
* Compiler: locals must sit below the saved `ra` / `s0` in the frame (the first bug: a parameter overwrote the
  return address; the simulator's trace showed `ra` = 'o').
* Compiler: a "constant right operand" shortcut must check that the next operator binds no tighter
  (`10 + 20 * 2`), and constant folding must honour `u` suffixes (4000000000u % 7).
* The register file without reset: the lock-step trace shows `xxxxxxxx` in the first store of `s0`.
