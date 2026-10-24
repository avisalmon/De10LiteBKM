// Unit test: both MAC styles give the Python reference result for 1,000 pairs (mac_reference.py 1000).
// python scripts/sim.py examples/12_dsp_multipliers/sim/tb_mac.sv
// sim-sources: ../src/mac.sv
`timescale 1ns/1ns

module tb_mac;

reg				clk = 0, start = 0;
wire signed [47:0]	acc_d, acc_l;
wire				done_d, done_l;
wire	[31:0]	cyc_d, cyc_l;
localparam [47:0] EXPECT = 48'hFFDBBCBDE1C7;		// mac_reference.py 1000

always #5 clk = ~clk;

mac #(.USE_DSP(1), .N(1000)) md(.clk(clk), .start(start), .acc(acc_d), .done(done_d), .cycles(cyc_d));
mac #(.USE_DSP(0), .N(1000)) ml(.clk(clk), .start(start), .acc(acc_l), .done(done_l), .cycles(cyc_l));

initial begin
	repeat (3) @(posedge clk);
	@(negedge clk) start = 1;
	@(negedge clk) start = 0;
	@(posedge done_d); #1;
	$display("dsp   acc=%012h cycles=%0d", acc_d, cyc_d);
	$display("logic acc=%012h cycles=%0d", acc_l, cyc_l);
	$display("expected  %012h", EXPECT);
	if (acc_d == EXPECT && acc_l == EXPECT) $display("PASS"); else $display("FAIL");
	$finish;
end

endmodule
