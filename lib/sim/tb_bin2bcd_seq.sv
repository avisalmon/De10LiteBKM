// Unit test: bin2bcd_seq gives the right 5 decimal digits for every 16-bit value.
// python scripts/sim.py lib/sim/tb_bin2bcd_seq.sv
// sim-sources: lib/rtl/bin2bcd_seq.sv
`timescale 1ns/1ns

module tb_bin2bcd_seq;

reg				clk = 0, start = 0;
reg	[15:0]	v;
wire	[19:0]	bcd;
wire				done, busy;
integer			i, errors = 0, got;

always #5 clk = ~clk;

bin2bcd_seq #(.BITS(16), .DIGITS(5)) dut(.clk(clk), .start(start), .bin(v), .bcd(bcd), .done(done), .busy(busy));

initial begin
	for (i = 0; i < 65536; i = i + 1) begin
		@(negedge clk) begin v = i; start = 1; end
		@(negedge clk) start = 0;
		@(posedge done); #1;
		got = bcd[19:16] * 10000 + bcd[15:12] * 1000 + bcd[11:8] * 100 + bcd[7:4] * 10 + bcd[3:0];
		if (got != i) begin
			errors = errors + 1;
			if (errors < 5) $display("%0d -> %h", i, bcd);
		end
	end
	$display("65536 values, %0d errors", errors);
	if (errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

endmodule
