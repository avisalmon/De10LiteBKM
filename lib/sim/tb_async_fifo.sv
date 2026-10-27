// Testbench for async_fifo (lib/rtl/async_fifo.sv): the dual-clock show-ahead FIFO of the stream fabric.
// Three instances, each watched by a checker that keeps its own queue of what went in and checks on every
// clock that: the show-ahead word is the oldest word whenever !empty; a pop returns it in order; the writer's
// level never reads below the true fill and the reader's never above it; nothing is pushed while full.
//   * f16: 16 x 16 on one clock. Directed: reset flags, fill with 20 pushes (16 land, full, overflow), rlevel
//     and rdata on the other side, drain in order, underflow on a pop while empty, full falls 3 clocks after
//     the first pop, reset clears the sticky flags; one word in an empty FIFO shows after exactly 3 clocks;
//     then random traffic.
//   * fch: 1024 x 16, written at 100 MHz, read at 37 MHz (the channel shape): fills to full, drains to empty,
//     then 50/50 traffic; the first word shows within 4 read clocks of its write.
//   * flane: 64 x 32, written at 63 MHz, read at 100 MHz (the write-back lane shape): same phases.
// Overflow and underflow stay 0 in the random traffic (the stimulus never pushes while full or pops while empty).
// python scripts/sim.py lib/sim/tb_async_fifo.sv                     (about 0.5 ms of simulated time)
// sim-sources: lib/rtl/async_fifo.sv
`timescale 1ns/1ps

// ---------------------------------------------------------------- the checker: one per FIFO under test
module fifo_checker #(
	parameter WIDTH = 16,
	parameter AW = 10,
	parameter DEPTH = 1 << AW,
	parameter NAME = "fifo"
)(
	input					wclk, rclk, wr_en, full, rd_en, empty,
	input	[WIDTH-1:0]	wdata, rdata,
	input	[AW:0]		wlevel, rlevel,
	output reg [31:0]	errors, pushes, pops
	);

reg	[WIDTH-1:0]	q [0:65535];						// what went in and has not come out yet
integer			head = 0, tail = 0;
reg				seen_full = 0, seen_empty_after_full = 0;

initial begin errors = 0; pushes = 0; pops = 0; end

task fail(input [8*64-1:0] what, input integer a, input integer b);
	begin
		errors = errors + 1;
		if (errors <= 8) $display("  %0s: %0s (%0d vs %0d) at %0t", NAME, what, a, b, $time);
	end
endtask

always @(posedge wclk) begin
	if (wlevel < tail - head) fail("wlevel below the true fill", wlevel, tail - head);
	if (wr_en && full) fail("push while full", wlevel, 0);
	if (wr_en && !full) begin
		q[tail[15:0]] = wdata;
		tail = tail + 1;
		pushes = pushes + 1;
	end
	if (full) seen_full = 1;
end

always @(posedge rclk) begin
	if (rlevel > tail - head) fail("rlevel above the true fill", rlevel, tail - head);
	if (!empty && tail == head) fail("not empty while truly empty", rlevel, 0);
	if (!empty && rdata !== q[head[15:0]]) fail("show-ahead word wrong", rdata, q[head[15:0]]);
	if (rd_en && !empty) begin
		head = head + 1;
		pops = pops + 1;
	end
	if (empty && seen_full) seen_empty_after_full = 1;
end

endmodule

// ---------------------------------------------------------------- the testbench
module tb_async_fifo;

integer			errors = 0;
integer			seed = 15;
integer			n, i;

task check(input cond, input [8*64-1:0] what);
	begin
		if (!cond) begin
			errors = errors + 1;
			$display("  FAIL: %0s at %0t", what, $time);
		end
	end
endtask

// clocks: 100 MHz, 37 MHz, 63 MHz
reg				clk100 = 0, clk37 = 0, clk63 = 0;
always #5 clk100 = ~clk100;
always #13.5135 clk37 = ~clk37;
always #7.9365 clk63 = ~clk63;
reg				rst_n = 0;

// --- f16: 16 x 16 on clk100, directed then random
reg				a_wr_rnd = 0, a_rd_rnd = 0, a_wr_force = 0, a_rd_force = 0;
reg	[15:0]	a_wdata = 0;
wire				a_full, a_empty, a_ovf, a_udf;
wire	[15:0]	a_rdata;
wire	[4:0]		a_wlevel, a_rlevel;
wire				a_wr_en = a_wr_force || (a_wr_rnd && !a_full);
wire				a_rd_en = a_rd_force || (a_rd_rnd && !a_empty);
wire	[31:0]	a_err, a_push, a_pop;
async_fifo #(.WIDTH(16), .DEPTH(16)) f16(
	.wclk(clk100), .wrst_n(rst_n), .wr_en(a_wr_en), .wdata(a_wdata), .full(a_full), .wlevel(a_wlevel), .overflow(a_ovf),
	.rclk(clk100), .rrst_n(rst_n), .rd_en(a_rd_en), .rdata(a_rdata), .empty(a_empty), .rlevel(a_rlevel), .underflow(a_udf));
fifo_checker #(.WIDTH(16), .AW(4), .NAME("f16")) ca(.wclk(clk100), .rclk(clk100), .wr_en(a_wr_en && !a_full), .full(a_full),
	.rd_en(a_rd_en && !a_empty), .empty(a_empty), .wdata(a_wdata), .rdata(a_rdata), .wlevel(a_wlevel), .rlevel(a_rlevel),
	.errors(a_err), .pushes(a_push), .pops(a_pop));

// --- fch: 1024 x 16, written at 100 MHz, read at 37 MHz
reg				b_wr_rnd = 0, b_rd_rnd = 0;
reg	[15:0]	b_wdata = 0;
wire				b_full, b_empty, b_ovf, b_udf;
wire	[15:0]	b_rdata;
wire	[10:0]	b_wlevel, b_rlevel;
wire				b_wr_en = b_wr_rnd && !b_full;
wire				b_rd_en = b_rd_rnd && !b_empty;
wire	[31:0]	b_err, b_push, b_pop;
async_fifo #(.WIDTH(16), .DEPTH(1024)) fch(
	.wclk(clk100), .wrst_n(rst_n), .wr_en(b_wr_en), .wdata(b_wdata), .full(b_full), .wlevel(b_wlevel), .overflow(b_ovf),
	.rclk(clk37), .rrst_n(rst_n), .rd_en(b_rd_en), .rdata(b_rdata), .empty(b_empty), .rlevel(b_rlevel), .underflow(b_udf));
fifo_checker #(.WIDTH(16), .AW(10), .NAME("fch")) cb(.wclk(clk100), .rclk(clk37), .wr_en(b_wr_en), .full(b_full),
	.rd_en(b_rd_en), .empty(b_empty), .wdata(b_wdata), .rdata(b_rdata), .wlevel(b_wlevel), .rlevel(b_rlevel),
	.errors(b_err), .pushes(b_push), .pops(b_pop));

// --- flane: 64 x 32, written at 63 MHz, read at 100 MHz
reg				c_wr_rnd = 0, c_rd_rnd = 0;
reg	[31:0]	c_wdata = 0;
wire				c_full, c_empty, c_ovf, c_udf;
wire	[31:0]	c_rdata;
wire	[6:0]		c_wlevel, c_rlevel;
wire				c_wr_en = c_wr_rnd && !c_full;
wire				c_rd_en = c_rd_rnd && !c_empty;
wire	[31:0]	c_err, c_push, c_pop;
async_fifo #(.WIDTH(32), .DEPTH(64)) flane(
	.wclk(clk63), .wrst_n(rst_n), .wr_en(c_wr_en), .wdata(c_wdata), .full(c_full), .wlevel(c_wlevel), .overflow(c_ovf),
	.rclk(clk100), .rrst_n(rst_n), .rd_en(c_rd_en), .rdata(c_rdata), .empty(c_empty), .rlevel(c_rlevel), .underflow(c_udf));
fifo_checker #(.WIDTH(32), .AW(6), .NAME("flane")) cc(.wclk(clk63), .rclk(clk100), .wr_en(c_wr_en), .full(c_full),
	.rd_en(c_rd_en), .empty(c_empty), .wdata(c_wdata), .rdata(c_rdata), .wlevel(c_wlevel), .rlevel(c_rlevel),
	.errors(c_err), .pushes(c_push), .pops(c_pop));

// random stimulus: a new decision on every clock of each side, data counts up so the order is visible
integer			a_duty_w = 0, a_duty_r = 0, b_duty_w = 0, b_duty_r = 0, c_duty_w = 0, c_duty_r = 0;	// per cent
always @(posedge clk100) begin
	a_wr_rnd <= (($random(seed) & 32'h7fffffff) % 100) < a_duty_w;
	a_rd_rnd <= (($random(seed) & 32'h7fffffff) % 100) < a_duty_r;
	if (a_wr_en && !a_full) a_wdata <= a_wdata + 1'b1;
	b_wr_rnd <= (($random(seed) & 32'h7fffffff) % 100) < b_duty_w;
	if (b_wr_en) b_wdata <= b_wdata + 1'b1;
	c_rd_rnd <= (($random(seed) & 32'h7fffffff) % 100) < c_duty_r;
end
always @(posedge clk37)
	b_rd_rnd <= (($random(seed) & 32'h7fffffff) % 100) < b_duty_r;
always @(posedge clk63) begin
	c_wr_rnd <= (($random(seed) & 32'h7fffffff) % 100) < c_duty_w;
	if (c_wr_en) c_wdata <= c_wdata + 32'h01010101;
end

// how long the first word of an empty FIFO takes to show: read clocks from the push edge until !empty
task wait_not_empty(input [7:0] which, output integer clocks);
	begin
		clocks = 0;
		while ((which == "a" && a_empty) || (which == "b" && b_empty) || (which == "c" && c_empty)) begin
			if (which == "b") @(posedge clk37); else @(posedge clk100);
			#1 clocks = clocks + 1;
			if (clocks > 20) begin check(0, "word never showed"); clocks = 99; end
		end
	end
endtask

initial begin
	$dumpfile("tb_async_fifo.vcd");
	$dumpvars(0, tb_async_fifo);
	repeat (5) @(posedge clk100);
	#1 rst_n = 1;
	@(posedge clk100); #1;
	check(a_empty && !a_full && a_wlevel == 0 && a_rlevel == 0 && !a_ovf && !a_udf, "f16 after reset");
	check(b_empty && !b_full && c_empty && !c_full, "fch/flane after reset");

	// ---- f16 directed: 20 pushes into 16 places
	$display("f16: fill, overflow, drain, underflow");
	a_wr_force = 1;
	repeat (20) @(posedge clk100);
	#1 a_wr_force = 0;
	check(a_full, "full after 16 pushes");
	check(a_wlevel == 16, "wlevel 16");
	check(a_ovf, "overflow set by the 4 extra pushes");
	check(a_push == 16, "checker counted 16 pushes");
	repeat (3) @(posedge clk100); #1;
	check(!a_empty && a_rlevel == 16, "reader sees 16");
	check(a_rdata == 16'd0, "show-ahead word is the first one");
	// drain: rd_en high for 17 clocks: 16 pops then one pop while empty
	a_rd_force = 1;
	n = 0;
	repeat (17) begin
		@(posedge clk100);
		if (!a_empty) begin
			if (a_rdata != n[15:0]) check(0, "drain order");
			n = n + 1;
		end
	end
	#1 a_rd_force = 0;
	check(n == 16, "16 words drained in order");
	check(a_empty && a_udf, "empty and underflow after the extra pop");
	check(a_pop == 16 && a_err == 0, "checker: 16 pops, no error");
	// full falls 3 clocks after a pop; the last pop was one clock ago, so wait for the other two
	check(a_full == 0 || a_wlevel <= 3, "writer at most 3 pops behind");
	repeat (3) @(posedge clk100); #1;
	check(!a_full && a_wlevel == 0, "writer sees it empty again");

	// reset clears the sticky flags
	@(posedge clk100); #1 rst_n = 0;
	repeat (3) @(posedge clk100);
	#1 rst_n = 1;
	@(posedge clk100); #1;
	check(!a_ovf && !a_udf && a_empty && !a_full, "reset cleared overflow/underflow");

	// one word into an empty FIFO shows after exactly 3 clocks (2 synchronizer flops + the binary register)
	a_wdata = 16'hBEEF;
	@(posedge clk100); #1 a_wr_force = 1;
	@(posedge clk100); #1 a_wr_force = 0;
	wait_not_empty("a", n);
	$display("f16: a word in an empty FIFO shows after %0d clocks", n);
	check(n == 3, "show-ahead latency 3 clocks on one clock");
	check(a_rdata == 16'hBEEF, "the word itself");
	@(posedge clk100); #1 a_rd_force = 1;
	@(posedge clk100); #1 a_rd_force = 0;
	a_wdata = 0;

	// ---- random traffic on all three
	$display("random traffic: fill phase");
	a_duty_w = 100; a_duty_r = 40;
	b_duty_w = 100; b_duty_r = 100;								// 100 MHz in, 37 MHz out: must fill
	c_duty_w = 100; c_duty_r = 30;									// 63 MHz in, 100 MHz out at 30 %: must fill
	// latency on the asynchronous one: first push to !empty
	@(posedge clk100);
	while (!b_wr_en) @(posedge clk100);
	wait_not_empty("b", n);
	$display("fch: first word shows after %0d read clocks", n);
	check(n <= 4, "show-ahead latency across clocks at most 4");
	repeat (6000) @(posedge clk100);
	check(cb.seen_full, "fch filled up");
	check(cc.seen_full, "flane filled up");
	check(ca.seen_full, "f16 filled up");

	$display("random traffic: drain phase");
	a_duty_w = 20; a_duty_r = 100;
	b_duty_w = 10; b_duty_r = 100;
	c_duty_w = 10; c_duty_r = 100;
	repeat (8000) @(posedge clk100);
	check(cb.seen_empty_after_full, "fch drained to empty");
	check(cc.seen_empty_after_full, "flane drained to empty");

	$display("random traffic: 50/50");
	a_duty_w = 50; a_duty_r = 50;
	b_duty_w = 50; b_duty_r = 50;
	c_duty_w = 50; c_duty_r = 50;
	repeat (10000) @(posedge clk100);

	// stop writing, let the readers empty everything
	a_duty_w = 0; b_duty_w = 0; c_duty_w = 0;
	a_duty_r = 100; b_duty_r = 100; c_duty_r = 100;
	repeat (3000) @(posedge clk100);
	check(a_empty && b_empty && c_empty, "all empty at the end");
	check(a_push == a_pop && b_push == b_pop && c_push == c_pop, "every word pushed was popped");
	check(a_err == 0 && b_err == 0 && c_err == 0, "checkers saw no error");
	check(!a_ovf && !a_udf && !b_ovf && !b_udf && !c_ovf && !c_udf, "no overflow/underflow in random traffic");
	$display("words: f16 %0d, fch %0d, flane %0d", a_pop, b_pop, c_pop);

	if (errors == 0) $display("PASS: async_fifo: fill/drain/flags, show-ahead latency 3, three shapes and clock pairs");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule
