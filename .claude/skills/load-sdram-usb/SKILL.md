---
name: load-sdram-usb
description: >
  Move data between the PC and the DE10-Lite's 64 MB SDRAM over the on-board USB-Blaster at the cable's limit:
  lib/rtl/sdram_loader.sv (a virtual JTAG node with a board-side CRC32) and scripts/sdram_load.py (load, read, verify,
  check, bench; the cable driven directly through Quartus's D2XX driver, or quartus_stp as the portable route).
  Measured: 64 MB written in 112 s (583 KB/s), proven by the board's CRC in 9.5 s, read back at 476 KB/s; the JTAG
  server route 547 / 319 KB/s; the JTAG UART ~82 KB/s. Worked example: examples/14_usb_sdram_loader.
  TRIGGER: "load data to the board", "upload a file", "send a file to the FPGA", "fill the SDRAM", "load parameters",
  "weights", "LLM parameters", "model weights", "fastest transfer", "USB transfer speed", "download from the board",
  "read the memory back", "virtual JTAG", "sld_virtual_jtag", "usb_blaster", "D2XX", "JTAG server slow".
---

# Load the SDRAM over USB

Proven on the board: `examples/14_usb_sdram_loader` (64 MB written, CRC-checked on the board and read back, 0 errors,
three runs: two direct, one quartus). Numbers (KB = 1024 bytes): direct route **583 KB/s** written (112 s for 64 MB), 476 KB/s read (470-540: USB
bus bound); quartus route 525-547 / 300-355 KB/s; JTAG UART text link ~82 KB/s. The board CRCs its own SDRAM at 6.7 MB/s.
The SDRAM controller itself, its pins and its bugs: `use-sdram` (example 06).

## Wire it (the design side)

```verilog
sdram_loader #(.INSTANCE(0)) loader(.clk(clk), .reset_n(reset_n),
  .req(req), .we(we), .addr(addr), .wdata(wdata), .ready(ready), .rvalid(rvalid), .rdata(rdata), .init_done(init_done),
  .user0(my_word0), .user1(my_word1),                 // two words of yours, shown by `sdram_load.py status`
  .words_written(), .reading(), .check_busy(), .busy(busy), .error(lost));
```
`--lib pll loader` (sdram_ctrl + sdram_loader) and `examples/14_usb_sdram_loader/src/extra.qsf` for the SDRAM pins;
the PLL and controller as in `use-sdram`. The loader owns sdram_ctrl's master port while `busy`; a design that also uses
the SDRAM multiplexes the port and keeps off it while the PC loads (or loads first, then starts: the usual case for
parameters and tables). Several loaders: give each its own `INSTANCE` and use `--instance`.

## Use it (the PC side)

```
python scripts/sdram_load.py status                          magic SDLD, init 1, counters, user0/1
python scripts/sdram_load.py load weights.bin [--addr WORD]  file -> SDRAM; the board CRCs what it holds (seconds)
python scripts/sdram_load.py verify weights.bin              read back over the cable and compare every byte
python scripts/sdram_load.py read out.bin --bytes N [--addr WORD]
python scripts/sdram_load.py bench [--mb 8|64]               random data: write, board CRC, read, all timed
python scripts/sdram_load.py --via quartus ...               the portable route (any OS with Quartus)
```
Addresses are 16-bit word addresses (0..0x1FFFFFF); 2 file bytes = 1 word, first byte low. Expect 64 MB: 1 min 52 s
to write, 9.5 s to prove, 2 min 18 s to read back. One cable user at a time: stop `de10.py log` / `nios2-terminal`
first (the script says `CableBusy`), and Quartus tools fail while a script holds the cable.

From Python: `from sdram_load import open_loader, load, read` (`scripts/` on sys.path); `ld = open_loader()`,
`load(ld, data, addr)`, `data, ok = read(ld, addr, nbytes)`, `ld.close()`. Lower level, any virtual JTAG node:
`from usb_blaster import UsbBlaster, SldHub` (`python scripts/usb_blaster.py` lists the cable and the nodes).

## The protocol (lib/rtl/sdram_loader.sv)

4-bit virtual IR: 1 WADDR (64-bit DR, word address; clears count/CRC/flags), 2 WRITE (n x 16 bits, address advances
across scans), 3 RADDR, 4 READ (n x 16 out), 5 STATUS (320 bits out: magic, flags, written, write CRC32, received,
sent, check CRC32, checked, user0, user1), 6 CHECK (64-bit: [24:0] first word, [57:32] count; poll STATUS bit 4).
Every data scan is a multiple of 16 bits, LSB first; the PC shifts 4 MB per scan. CRC32 = `zlib.crc32`.

## Lessons (each cost real time; gotchas 30-34)

1. **The JTAG server caps every Quartus tool at ~525-547 KB/s written / ~350 read**, whatever the scan length. The
   cable's own limit is 583 KB/s (its CPLD: ~41 clocks of 24 MHz per byte); only driving it directly reaches it.
2. **quartus_stp holds its stdout back until exit when stdout is a pipe** (Tcl `flush` does not help) but reads stdin
   promptly: answers go through a file opened with `-buffering none` that Python tails (`scripts/sdram_load.tcl`).
3. **`-no_captured_dr_value` scans are only queued**: a timed write must end with a captured scan.
4. **No framing in the cable protocol**: a lost byte turns data into commands (stalled answer FIFO, or a pulse of
   nCONFIG that reloads the flash: seen once in an unguarded sweep). `usb_blaster.py` checks for unasked-for bytes after
   every 64 KB block and at every scan end, resets the TAP and raises; every load is CRC-checked on the board.
5. **Direct cable details**: TDO is valid in the answer to the TCK-high byte; drain answers by `FT_GetQueueStatus` from
   one thread (a reader thread deadlocks the driver); the receive queue holds 64 KB, so one 64 KB block in flight.
6. **Reads are USB-bus bound** (full speed, both directions share 12 Mb/s): 470-540 KB/s with the same code; not a bug.
7. **A board shared by two chats**: `%LOCALAPPDATA%\de10lite\board.lock` ("who | what | since"), delete it and say
   "board free" when done; check it before every board command.

## Check

`python scripts/sim.py lib/sim/tb_sdram_loader.sv -D SDRAM_LOADER_SIM` (every word, an overflow and an underrun
forced; PASS), `python -m pytest tests/test_sdram_loader.py`, and on the board `sdram_load.py bench --mb 8` (OK with
the CRC32), then `--mb 64` for the whole chip.

## Faster

Not on this cable: the SDRAM side takes 10 MB/s, the cable 0.58. A USB 2.0 high-speed FIFO (FT232H / FT2232H in
245 synchronous mode, 20-30 MB/s) on the 40-pin GPIO header, with the same loader behind a byte port, is the next step.
