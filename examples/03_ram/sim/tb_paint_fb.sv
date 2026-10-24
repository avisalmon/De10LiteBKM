// Unit test: paint fills the 160x120 frame buffer at start-up (50 MHz port), the 25 MHz port reads it back.
// python scripts/sim.py examples/03_ram/sim/tb_paint_fb.sv
// sim-sources: lib/rtl/ram_dp.sv ../src/paint.sv
`timescale 1ns/1ps

module tb_paint_fb;

reg				clk50 = 0, clk25 = 0;
reg				locked = 0;			// like the PLL: low for a while after power-up
reg	[14:0]	rd_addr = 0;
wire	[14:0]	wr_addr;
wire	[11:0]	wr_d, q;
wire				we, filling;
integer			errors = 0, i, x, y;
reg	[11:0]	want;

always #10 clk50 = ~clk50;
always #20 clk25 = ~clk25;

paint p(.clk(clk50), .ready(locked), .A(1'b0), .B(1'b0), .Select(1'b0), .Start(1'b0), .Left(1'b0), .Right(1'b0), .Up(1'b0),
	.Down(1'b0), .wheel(12'h000), .wr_addr(wr_addr), .wr_d(wr_d), .we(we), .cx(), .cy(), .filling(filling));
ram_dp #(.WIDTH(12), .AW(15), .DEPTH(19200)) fb(.wr_clk(clk50), .wr_addr(wr_addr), .wr_d(wr_d), .we(we),
	.rd_clk(clk25), .rd_addr(rd_addr), .rd_q(q));

function [11:0] pattern(input integer fx, input integer fy);
	reg [7:0] x8; reg [6:0] y7;
	begin
		x8 = fx; y7 = fy;
		if (fx == 0 || fx == 159 || fy == 0 || fy == 119) pattern = 12'hFFF;
		else if (fx % 20 == 0 || fy % 20 == 0) pattern = 12'h444;
		else pattern = {x8[7:4], y7[6:3], 4'hF - x8[7:4]};
	end
endfunction

initial begin
	repeat (20) @(posedge clk50);
	locked = 1;
	wait (filling === 1'b0);
	repeat (4) @(posedge clk25);
	for (i = 0; i < 50; i = i + 1) begin
		x = (i * 37 + 3) % 160;  y = (i * 29 + 1) % 120;
		if (i < 4) begin x = (i % 2) ? 159 : 0; y = (i / 2) ? 119 : 0; end		// the four corners (white frame)
		@(negedge clk25) rd_addr = y * 160 + x;
		@(posedge clk25); #1;
		want = pattern(x, y);
		if (q !== want) begin errors = errors + 1; $display("(%0d,%0d): got %h want %h", x, y, q, want); end
	end
	$display("50 pixels checked, %0d errors", errors);
	if (errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

initial begin #10_000_000; $display("FAIL: timeout"); $finish; end

endmodule
