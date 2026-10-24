// Unit test: sdram_ctrl against the SDRAM model (CAS 3, real read-data window), 50 MHz, DRAM clock shifted 180 deg.
// Writes 300 pseudo-random words to scattered addresses (rows 0..15, all banks), reads them back, compares.
// python scripts/sim.py lib/sim/tb_sdram_ctrl.sv
// sim-sources: lib/rtl/sdram_ctrl.sv lib/sim/sdram_model.sv
`timescale 1ns/1ps

module tb_sdram_ctrl;

reg				clk = 0, reset_n = 0;
reg				req = 0, we = 0;
reg	[24:0]	addr = 0;
reg	[15:0]	wdata = 0;
wire				ready, rvalid, init_done;
wire	[15:0]	rdata;
wire	[12:0]	A;
wire	[1:0]		BA;
wire				cas_n, cke, cs_n, ras_n, we_n, ldqm, udqm;
wire	[15:0]	DQ;
integer			model_errors, errors = 0, i, c;
reg	[24:0]	adr [0:299];
reg	[15:0]	val [0:299];

always #10 clk = ~clk;				// 50 MHz
wire dram_clk = ~clk;				// 180 degrees, as the PLL makes it on the board

sdram_ctrl #(.CLK_MHZ(50), .READ_DELAY(4)) dut(.clk(clk), .reset_n(reset_n), .rd_delay(3'd4), .req(req), .we(we), .addr(addr),
	.wdata(wdata), .ready(ready), .rvalid(rvalid), .rdata(rdata), .init_done(init_done),
	.DRAM_ADDR(A), .DRAM_BA(BA), .DRAM_CAS_N(cas_n), .DRAM_CKE(cke), .DRAM_CS_N(cs_n), .DRAM_DQ(DQ),
	.DRAM_LDQM(ldqm), .DRAM_RAS_N(ras_n), .DRAM_UDQM(udqm), .DRAM_WE_N(we_n));
sdram_model mem(.dram_clk(dram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
	.ba(BA), .a(A), .dq(DQ), .errors(model_errors));

task access(input w, input [24:0] ad, input [15:0] d);
	begin
		@(negedge clk); while (!ready) @(negedge clk);
		req = 1; we = w; addr = ad; wdata = d;
		@(negedge clk) req = 0;
	end
endtask

initial begin
	for (i = 0; i < 300; i = i + 1) begin
		c = (i * 37) % 1024;
		adr[i] = {i[1:0], 9'd0, i[3:0] ^ i[7:4], c[9:0]};		// banks 0..3, rows 0..15
		val[i] = (i * 16'h9E37) ^ 16'h5A5A;
	end
	repeat (5) @(posedge clk);
	reset_n = 1;
	wait (init_done);
	for (i = 0; i < 300; i = i + 1) access(1, adr[i], val[i]);
	for (i = 0; i < 300; i = i + 1) begin
		access(0, adr[i], 0);
		@(posedge rvalid); #1;
		if (rdata !== val[i]) begin
			errors = errors + 1;
			if (errors < 5) $display("addr %h: read %h, wrote %h", adr[i], rdata, val[i]);
		end
	end
	$display("300 words, %0d read errors, %0d protocol errors", errors, model_errors);
	if (errors == 0 && model_errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

initial begin #5_000_000; $display("FAIL: timeout"); $finish; end

endmodule
