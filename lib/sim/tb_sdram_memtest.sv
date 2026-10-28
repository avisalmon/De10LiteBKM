// Testbench for sdram_memtest (lib/rtl/sdram_memtest.sv): the engine on the burst controller and the SDRAM model,
// driven through its register bus the way the PC drives it through jtag_regs (one write pulse, reads a clock late).
// Checks, at 100 MHz with DRAM_CLK 45 degrees behind clk and rd_delay 3 (the default out of reset is 4, the value
// the board needs: the testbench checks it, then sets 3 for the bare-chip model, see gotcha 40):
//   * a write + read run of every pattern: pass, 0 errors, the word counts, the clocks against the ideal
//     L + 5 / L + 4 per burst (refresh pauses allowed for), the bus-use counter; and the model's memory against
//     the pattern computed here (the write pass must put the right word at the right address, not just agree
//     with its own read pass)
//   * a read-only run after a write (nothing written, same result), a small burst size
//   * two words corrupted in the model: ERRORS 2, ERR_ADDR / ERR_LAST, ERR_DATA, ERR_BITS
//   * rd_delay 4 at this phase samples the wrong clock: the engine must report errors, with no model error
//   * abort during a long write: the run ends with whole bursts, no read pass
//   * a start while running is ignored; the model reports no protocol or timing error anywhere
// python scripts/sim.py lib/sim/tb_sdram_memtest.sv                  (about 0.5 ms of simulated time)
// sim-sources: lib/rtl/sdram_memtest.sv lib/rtl/sdram_burst_ctrl.sv lib/sim/sdram_model.sv
`timescale 1ns/1ps

module tb_sdram_memtest;

localparam ROW_BITS = 6;
localparam WORDS = 4 << (ROW_BITS + 10);
localparam REFRESH_CLOCKS = 97;								// a refresh every 97 clocks: pauses in every pass
localparam real P_NS = 1.25;

reg				clk = 0;
always #5 clk = ~clk;
reg				dram_clk = 0;
always @(clk) dram_clk <= #(P_NS) clk;
reg				rst_n = 0;

// register bus
reg	[4:0]		reg_addr = 0;
reg	[31:0]	reg_wdata = 0;
reg				reg_we = 0;
wire	[31:0]	reg_rdata;
// engine <-> controller
wire	[2:0]		rd_delay;
wire				cmd_valid, cmd_ready, cmd_we, wvalid, wready, rvalid, done, init_done, stat_busy, stat_refresh;
wire	[24:0]	cmd_addr;
wire	[10:0]	cmd_len;
wire	[15:0]	wdata, rdata;
wire				running, finished, pass;
wire	[31:0]	errors_out;
// pins
wire	[12:0]	A;
wire	[1:0]		BA;
wire				cas_n, cke, cs_n, ras_n, we_n, ldqm, udqm;
wire	[15:0]	DQ;
integer			model_errors;

sdram_memtest #(.VERSION(16'h00A5)) eng(.clk(clk), .rst_n(rst_n),
	.reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_we(reg_we), .reg_rdata(reg_rdata),
	.rd_delay(rd_delay), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
	.cmd_len(cmd_len), .wdata(wdata), .wvalid(wvalid), .wready(wready), .rdata(rdata), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh),
	.running(running), .finished(finished), .pass(pass), .errors(errors_out));
sdram_burst_ctrl #(.CLK_MHZ(100), .REFRESH_CLOCKS(REFRESH_CLOCKS)) ctl(.clk(clk), .rst_n(rst_n), .rd_delay(rd_delay),
	.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
	.wdata(wdata), .wvalid(wvalid), .wready(wready), .rdata(rdata), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh),
	.DRAM_ADDR(A), .DRAM_BA(BA), .DRAM_CAS_N(cas_n), .DRAM_CKE(cke), .DRAM_CS_N(cs_n), .DRAM_DQ(DQ),
	.DRAM_LDQM(ldqm), .DRAM_RAS_N(ras_n), .DRAM_UDQM(udqm), .DRAM_WE_N(we_n));
sdram_model #(.ROW_BITS(ROW_BITS)) mem(.dram_clk(dram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
	.we_n(we_n), .ba(BA), .a(A), .dq(DQ), .errors(model_errors));

// ---- register names ----
localparam [4:0] R_STATUS = 0, R_CTRL = 1, R_RD_DELAY = 2, R_BASE = 3, R_LEN = 4, R_BURST = 5, R_MODE = 6, R_SEED = 7,
	R_ERRORS = 8, R_ERR_ADDR = 9, R_ERR_DATA = 10, R_ERR_BITS = 11, R_WR_CLOCKS = 12, R_RD_CLOCKS = 13, R_WORDS = 14,
	R_REFRESHES = 15, R_BUSY_CLKS = 16, R_ERR_LAST = 17, R_WR_WORDS = 18;

integer			errors = 0;
task fail(input [8*80-1:0] what, input [31:0] got, input [31:0] want);
	begin
		errors = errors + 1;
		$display("FAIL at %0t: %0s: got %0d (%h), want %0d (%h)", $time, what, got, got, want, want);
	end
endtask

task wr(input [4:0] a, input [31:0] v);
	begin
		@(negedge clk);
		reg_addr = a; reg_wdata = v; reg_we = 1;
		@(negedge clk);
		reg_we = 0;
	end
endtask

task rd(input [4:0] a, output [31:0] v);
	begin
		@(negedge clk);
		reg_addr = a;
		@(negedge clk);
		@(negedge clk);
		v = reg_rdata;
	end
endtask

task wait_finished(input integer max_clocks);
	integer n;
	reg [31:0] s;
	begin
		n = 0;
		s = 0;
		while (!s[2] && n < max_clocks) begin
			rd(R_STATUS, s);
			n = n + 3;
		end
		if (!s[2]) fail("run did not finish", s, 32'h4);
	end
endtask

// ---- the pattern, computed here ----
function [ROW_BITS+11:0] aidx(input [24:0] a);
	aidx = {a[24:23], a[ROW_BITS+9:10], a[9:0]};
endfunction
reg	[31:0]	x;
function [31:0] xorshift(input [31:0] s);
	reg [31:0] a, b;
	begin
		a = s ^ (s << 13);
		b = a ^ (a >> 17);
		xorshift = b ^ (b << 5);
	end
endfunction

// check the model's memory over base .. base + len - 1 against pattern pat with seed
task check_memory(input [1:0] pat, input [24:0] base, input integer len, input [31:0] seed, input [15:0] flip_mask,
	input [24:0] flip_at);
	integer i, bad;
	reg [24:0] a;
	reg [15:0] want;
	begin
		x = (seed == 0) ? 32'd1 : seed;
		bad = 0;
		for (i = 0; i < len; i = i + 1) begin
			a = base + i;
			case (pat)
				2'd0: want = a[15:0] ^ a[24:9] ^ seed[15:0];
				2'd1: want = seed[15:0];
				2'd2: want = x[15:0];
				default: want = a[0] ? ~seed[15:0] : seed[15:0];
			endcase
			if (a == flip_at) want = want ^ flip_mask;
			if (mem.mem[aidx(a)] !== want) begin
				if (bad < 3) $display("  memory[%h] = %h, pattern %0d wants %h", a, mem.mem[aidx(a)], pat, want);
				bad = bad + 1;
			end
			x = xorshift(x);
		end
		if (bad != 0) fail("model memory vs pattern", bad, 0);
	end
endtask

// expected word for a corrupt-check
function [15:0] pat0(input [24:0] a, input [31:0] seed);
	pat0 = a[15:0] ^ a[24:9] ^ seed[15:0];
endfunction

reg	[31:0]	s, v, v2, nb, ideal, refs;
integer			p, len, bursts, t0;
localparam [24:0] BASE0 = 25'h000_0400;

initial begin
	repeat (5) @(posedge clk);
	rst_n = 1;

	// before init_done a start is ignored
	rd(R_STATUS, s);
	if (s[0]) fail("init_done early", s, 0);
	if (s[31:16] !== 16'h00A5) fail("VERSION", s[31:16], 16'h00A5);
	if (s[10:8] !== 3'd4) fail("rd_delay default (the board's value)", s[10:8], 4);
	wr(R_RD_DELAY, 3);												// the bare-chip model wants 3 (gotcha 40)
	rd(R_STATUS, s);
	if (s[10:8] !== 3'd3) fail("rd_delay set to 3", s[10:8], 3);
	wr(R_CTRL, 1);
	rd(R_STATUS, s);
	if (s[1]) fail("started before init", s, 0);
	t0 = $time;
	@(posedge init_done);
	$display("init_done after %0d us", ($time - t0) / 1000);

	// ---- every pattern: write + read, 2500 words in bursts of 1024 ----
	len = 2500; bursts = 3;
	for (p = 0; p < 4; p = p + 1) begin
		wr(R_BASE, BASE0 + p * 4096);
		wr(R_LEN, len);
		wr(R_BURST, 0);
		wr(R_MODE, {p[1:0], 4'b0011});
		wr(R_SEED, 32'h1234_5600 + p);
		rd(R_MODE, v);
		if (v[5:4] !== p[1:0]) fail("MODE readback", v, p);
		wr(R_CTRL, 1);
		rd(R_STATUS, s);
		if (!s[1]) fail("running after start", s, 2);
		wait_finished(50_000);
		rd(R_STATUS, s);
		if (!s[3]) fail("pass bit", s, 8);
		rd(R_ERRORS, v); if (v !== 0) fail("ERRORS", v, 0);
		rd(R_WORDS, v); if (v !== len) fail("WORDS", v, len);
		rd(R_WR_WORDS, v); if (v !== len) fail("WR_WORDS", v, len);
		rd(R_REFRESHES, refs);
		rd(R_WR_CLOCKS, v);
		ideal = len + 5 * bursts;
		if (v < ideal) fail("WR_CLOCKS below ideal", v, ideal);
		if (v > ideal + refs * 12 + 20) fail("WR_CLOCKS too slow", v, ideal + refs * 12 + 20);
		rd(R_RD_CLOCKS, v2);
		ideal = len + 4 * bursts;
		if (v2 < ideal) fail("RD_CLOCKS below ideal", v2, ideal);
		if (v2 > ideal + refs * 12 + 20) fail("RD_CLOCKS too slow", v2, ideal + refs * 12 + 20);
		rd(R_BUSY_CLKS, nb);
		if (nb !== 2 * len) fail("BUSY_CLKS", nb, 2 * len);
		$display("pattern %0d: write %0d clocks, read %0d clocks for %0d words in %0d bursts, %0d refreshes",
			p, v, v2, len, bursts, refs);
		check_memory(p[1:0], BASE0 + p * 4096, len, 32'h1234_5600 + p, 16'h0, 25'h1FF_FFFF);
	end
	if (errors_out !== 0) fail("errors port", errors_out, 0);

	// ---- read-only run over pattern 3's range: nothing written ----
	wr(R_BASE, BASE0 + 3 * 4096);
	wr(R_MODE, 6'b11_0010);
	wr(R_CTRL, 1);
	wait_finished(50_000);
	rd(R_ERRORS, v); if (v !== 0) fail("read-only ERRORS", v, 0);
	rd(R_WR_WORDS, v); if (v !== 0) fail("read-only WR_WORDS", v, 0);
	rd(R_WR_CLOCKS, v); if (v !== 0) fail("read-only WR_CLOCKS", v, 0);
	rd(R_WORDS, v); if (v !== len) fail("read-only WORDS", v, len);
	rd(R_BUSY_CLKS, nb); if (nb !== len) fail("read-only BUSY_CLKS", nb, len);

	// ---- small bursts: 100 words in bursts of 16 (7 bursts), pattern 0 (row 17: no alias of the ranges above) ----
	wr(R_BASE, BASE0 + 25'h4000);
	wr(R_LEN, 100);
	wr(R_BURST, 16);
	wr(R_MODE, 6'b00_0011);
	wr(R_SEED, 32'h0000_0077);
	wr(R_CTRL, 1);
	wait_finished(20_000);
	rd(R_ERRORS, v); if (v !== 0) fail("burst16 ERRORS", v, 0);
	rd(R_WORDS, v); if (v !== 100) fail("burst16 WORDS", v, 100);
	rd(R_RD_CLOCKS, v2);
	if (v2 < 100 + 4 * 7) fail("burst16 RD_CLOCKS below ideal", v2, 128);
	if (v2 > 100 + 7 * 7 + 60) fail("burst16 RD_CLOCKS too slow", v2, 209);
	$display("bursts of 16: read %0d clocks for 100 words in 7 bursts", v2);
	check_memory(2'd0, BASE0 + 25'h4000, 100, 32'h0000_0077, 16'h0, 25'h1FF_FFFF);

	// ---- corrupt two words of pattern 0's range, read only ----
	mem.mem[aidx(BASE0 + 777)] = mem.mem[aidx(BASE0 + 777)] ^ 16'h0101;
	mem.mem[aidx(BASE0 + 2000)] = mem.mem[aidx(BASE0 + 2000)] ^ 16'h8000;
	wr(R_BASE, BASE0);
	wr(R_LEN, len);
	wr(R_BURST, 0);
	wr(R_MODE, 6'b00_0010);
	wr(R_SEED, 32'h1234_5600);
	wr(R_CTRL, 1);
	wait_finished(50_000);
	rd(R_STATUS, s); if (s[3]) fail("pass bit with errors", s, 0);
	rd(R_ERRORS, v); if (v !== 2) fail("corrupt ERRORS", v, 2);
	rd(R_ERR_ADDR, v); if (v !== BASE0 + 777) fail("ERR_ADDR", v, BASE0 + 777);
	rd(R_ERR_LAST, v); if (v !== BASE0 + 2000) fail("ERR_LAST", v, BASE0 + 2000);
	rd(R_ERR_DATA, v);
	if (v !== {pat0(BASE0 + 777, 32'h1234_5600), pat0(BASE0 + 777, 32'h1234_5600) ^ 16'h0101})
		fail("ERR_DATA", v, {pat0(BASE0 + 777, 32'h1234_5600), pat0(BASE0 + 777, 32'h1234_5600) ^ 16'h0101});
	rd(R_ERR_BITS, v); if (v !== 16'h8101) fail("ERR_BITS", v, 16'h8101);
	if (errors_out !== 2) fail("errors port", errors_out, 2);
	// repair, and a write + read run clears the error registers
	mem.mem[aidx(BASE0 + 777)] = mem.mem[aidx(BASE0 + 777)] ^ 16'h0101;
	mem.mem[aidx(BASE0 + 2000)] = mem.mem[aidx(BASE0 + 2000)] ^ 16'h8000;
	wr(R_MODE, 6'b00_0011);
	wr(R_CTRL, 1);
	wait_finished(50_000);
	rd(R_ERRORS, v); if (v !== 0) fail("ERRORS after repair", v, 0);
	rd(R_ERR_BITS, v); if (v !== 0) fail("ERR_BITS cleared", v, 0);
	rd(R_ERR_ADDR, v); if (v !== 0) fail("ERR_ADDR cleared", v, 0);

	// ---- rd_delay 4 at this phase: the wrong clock, errors but no model error ----
	wr(R_RD_DELAY, 4);
	rd(R_STATUS, s); if (s[10:8] !== 3'd4) fail("rd_delay readback", s[10:8], 4);
	wr(R_MODE, 6'b00_0010);
	wr(R_CTRL, 1);
	wait_finished(50_000);
	rd(R_ERRORS, v); if (v == 0) fail("rd_delay 4 should miss the window", v, 1);
	$display("rd_delay 4 at %0.2f ns: %0d of %0d words wrong (expected: the window is at rd_delay 3)", P_NS, v, len);
	wr(R_RD_DELAY, 3);
	wr(R_CTRL, 1);
	wait_finished(50_000);
	rd(R_ERRORS, v); if (v !== 0) fail("rd_delay 3 again", v, 0);

	// ---- abort a long write (200,000 words): whole bursts, then stop, no read pass ----
	wr(R_BASE, 0);
	wr(R_LEN, 200_000);
	wr(R_BURST, 0);
	wr(R_MODE, 6'b00_0011);
	wr(R_CTRL, 1);
	repeat (3000) @(posedge clk);
	rd(R_STATUS, s); if (!s[1]) fail("running before abort", s, 2);
	wr(R_CTRL, 1);													// a start while running: ignored
	wr(R_CTRL, 2);
	wait_finished(10_000);
	rd(R_STATUS, s); if (s[1]) fail("running after abort", s, 0);
	rd(R_WR_WORDS, v);
	if (v == 0 || v >= 200_000) fail("WR_WORDS after abort", v, 3072);
	if (v % 1024 != 0) fail("abort left a partial burst", v, 0);
	rd(R_WORDS, v2); if (v2 !== 0) fail("abort ran the read pass", v2, 0);
	$display("abort after 3000 clocks: %0d words written", v);
	check_memory(2'd0, 25'd0, v, 32'h1234_5600, 16'h0, 25'h1FF_FFFF);
	// the engine is usable after the abort
	wr(R_LEN, 1024);
	wr(R_CTRL, 1);
	wait_finished(20_000);
	rd(R_ERRORS, v); if (v !== 0) fail("run after abort", v, 0);
	rd(R_WORDS, v); if (v !== 1024) fail("WORDS after abort", v, 1024);

	if (model_errors != 0) fail("model protocol/timing errors", model_errors, 0);
	if (errors == 0) $display("PASS: sdram_memtest: 4 patterns, read-only, small bursts, corruption, rd_delay, abort");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

initial begin
	#2_000_000;
	$display("FAIL: timeout");
	$finish;
end

endmodule
