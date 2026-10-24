// Unit test: ram_bist finds no errors in a good RAM, and exactly one per pass when inject is on.
// python scripts/sim.py examples/03_ram/sim/tb_ram_bist.sv
// sim-sources: lib/rtl/ram_sp.sv ../src/ram_bist.sv
`timescale 1ns/1ns

module tb_ram_bist;

reg				clk = 0, inject = 0;
wire	[31:0]	passes, errors;
wire	[15:0]	last;
wire				done;
integer			ok = 1;

always #10 clk = ~clk;

ram_bist #(.AW(8)) dut(.clk(clk), .inject(inject), .passes(passes), .errors(errors), .last_errors(last), .pass_done(done));

initial begin
	repeat (5) @(posedge done);
	$display("clean: passes %0d errors %0d", passes, errors);
	if (errors != 0) ok = 0;
	inject = 1;
	@(posedge done);								// a pass that started clean
	repeat (4) @(posedge done) begin
		#1 $display("inject: last pass errors %0d", last);
		if (last != 1) ok = 0;
	end
	if (ok) $display("PASS"); else $display("FAIL");
	$finish;
end

endmodule
