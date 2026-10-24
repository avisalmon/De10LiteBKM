// Runs a program on the RTL SoC and writes the same trace the Python simulator writes, for a lock-step compare:
//   python scripts/sim.py projects/riscv_tetris/sim/tb_soc.sv -D PROG='"../build/test_c.hex"' -D TRACE='"../build/test_c_rtl.trc"'
//   python projects/riscv_tetris/tools/trace_compare.py build/test_c.trc build/test_c_rtl.trc
// Ends when the program writes EXIT (PASS if the code is 0), on a CPU fault, or after MAXCYCLES.
// Also writes the UART output to <TRACE>.uart and the text screen to <TRACE>.screen.
// sim-sources: ../src/rv32_cpu.sv ../src/soc_ram.sv ../src/rv32_soc.sv ../../../lib/rtl/ram_dp.sv
`timescale 1ns/1ns
`default_nettype none
`ifndef PROG
`define PROG "../build/test_isa.hex"
`endif
`ifndef TRACE
`define TRACE "../build/rtl.trc"
`endif
`ifndef MAXCYCLES
`define MAXCYCLES 60000000
`endif

module tb_soc;

logic clk = 0;
always #20 clk = ~clk;
logic rst_n = 0;
logic tick = 0;
logic [9:0] buttons = 0;

wire [23:0] hex;
wire [9:0] leds;
wire [15:0] buzzer_half;
wire [7:0] tx_data;
wire tx_valid, exit_valid, halted, fault, trace_valid, bus_write;
wire [31:0] exit_code, trace_pc, trace_data, bus_addr, bus_wdata;
wire [4:0] trace_rd;
wire [3:0] bus_be;
wire [15:0] text_q;

rv32_soc #(.RAM_IMPL("SIM"), .PROG_FILE(`PROG)) soc(
	.clk(clk), .rst_n(rst_n), .tick(tick), .buttons(buttons), .switches(10'h0),
	.text_addr(13'd0), .text_q(text_q), .hex(hex), .leds(leds), .buzzer_half(buzzer_half),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(1'b1),
	.exit_valid(exit_valid), .exit_code(exit_code), .halted(halted), .fault(fault),
	.trace_valid(trace_valid), .trace_pc(trace_pc), .trace_rd(trace_rd), .trace_data(trace_data),
	.bus_write(bus_write), .bus_addr_o(bus_addr), .bus_wdata_o(bus_wdata), .bus_be_o(bus_be));

integer ftrace, fuart, fscreen, cycles = 0, instrs = 0, r, c;
logic [15:0] cw;
logic [7:0] glyph;

// a frame tick every 416,667 clocks (60 Hz at 25 MHz), as on the board
integer frame_div = 0;
always @(posedge clk) begin
	frame_div <= (frame_div == 416_666) ? 0 : frame_div + 1;
	tick <= (frame_div == 416_666);
end

// the pc of the instruction being executed: the CPU's pc register before it moves on
always @(posedge clk) begin
	if (trace_valid) $fwrite(ftrace, "%08x %0d %08x\n", trace_pc, trace_rd, trace_data);
	if (bus_write) $fwrite(ftrace, "%08x W %08x %08x %x\n", soc.cpu.pc, bus_addr, bus_wdata, bus_be);
	if (tx_valid) $fwrite(fuart, "%c", tx_data);
	cycles = cycles + 1;
	if (soc.cpu.state == 2'd1) instrs = instrs + 1;		// S_EXEC: one per instruction
end

initial begin
	ftrace = $fopen(`TRACE, "w");
	fuart = $fopen({`TRACE, ".uart"}, "w");
	repeat (3) @(negedge clk);
	rst_n = 1;
	while (!exit_valid && !fault && cycles < `MAXCYCLES) @(negedge clk);
	$fclose(ftrace);
	$fclose(fuart);
	// the text screen as text
	fscreen = $fopen({`TRACE, ".screen"}, "w");
	for (r = 0; r < 60; r = r + 1) begin
		for (c = 0; c < 80; c = c + 1) begin
			cw = soc.text.mem[r * 80 + c];
			if (cw[7]) begin
				case (cw[1:0])
					2'd0: glyph = "#";
					2'd1: glyph = "+";
					2'd2: glyph = ":";
					default: glyph = "[";
				endcase
			end else if (cw[7:0] >= 8'h20 && cw[7:0] < 8'h7F) glyph = cw[7:0];
			else glyph = " ";
			$fwrite(fscreen, "%c", glyph);
		end
		$fwrite(fscreen, "\n");
	end
	$fclose(fscreen);
	$display("%0d cycles, %0d instructions (%0.2f cycles each), HEX=%06x LEDS=%03x", cycles, instrs,
	         instrs ? cycles * 1.0 / instrs : 0.0, hex, leds);
	if (fault) $display("FAIL: CPU fault (illegal instruction) at pc %08x", soc.cpu.pc);
	else if (!exit_valid) $display("FAIL: no EXIT after %0d cycles", cycles);
	else if (exit_code != 0) $display("FAIL: exit code %0d", exit_code);
	else $display("PASS");
	$finish;
end

endmodule
