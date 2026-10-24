// Unit test: freq_counter must report 25 MHz as 25000 kHz and 10 MHz as 10000 kHz (no PLL needed).
// python scripts/sim.py examples/01_pll_clocks/sim/tb_freq_counter.sv
// sim-sources: lib/rtl/freq_counter.sv
`timescale 1ps/1ps

module tb_freq_counter;

reg		ref_clk = 0, c25 = 0, c10 = 0;
wire	[19:0]	k25, k10;
wire			v25, v10;
integer			errors = 0;

always #10000 ref_clk = ~ref_clk;		// 50 MHz
always #20000 c25 = ~c25;					// 25 MHz
always #50000 c10 = ~c10;					// 10 MHz

freq_counter f25(.ref_clk(ref_clk), .meas_clk(c25), .khz(k25), .valid(v25));
freq_counter f10(.ref_clk(ref_clk), .meas_clk(c10), .khz(k10), .valid(v10));

initial begin
	$dumpfile("tb_freq_counter.vcd");
	$dumpvars(0, tb_freq_counter);
	repeat (2) @(posedge v25);		// the first result can start mid-gate
	@(posedge v25);
	$display("25 MHz -> %0d kHz, 10 MHz -> %0d kHz", k25, k10);
	if (k25 != 25000) errors = errors + 1;
	if (k10 != 10000) errors = errors + 1;
	if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule
