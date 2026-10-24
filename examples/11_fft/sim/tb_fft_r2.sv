// Unit test: our FFT on the test signal; writes sim/diy_dump.txt in the board's dump format.
// python scripts/sim.py examples/11_fft/sim/tb_fft_r2.sv
// python examples/11_fft/sim/fft_data.py check examples/11_fft/sim/diy_dump.txt     (accuracy vs numpy)
// sim-sources: ../src/fft_r2.sv
`timescale 1ns/1ns

module tb_fft_r2;

reg				clk = 0, in_valid = 0;
reg signed [15:0]	in_re = 0, in_im = 0;
wire				out_valid, busy;
wire	[7:0]		out_k;
wire signed [15:0]	out_re, out_im;
reg	[31:0]	x [0:255];
integer			i, f, got = 0, t0, t1;

always #10 clk = ~clk;

fft_r2 #(.TWIDDLE_FILE("../assets/twiddle.hex")) dut(.clk(clk), .in_valid(in_valid), .in_re(in_re), .in_im(in_im),
	.out_valid(out_valid), .out_k(out_k), .out_re(out_re), .out_im(out_im), .busy(busy));

always @(posedge clk) if (out_valid) begin
	if (out_k != got) $display("out of order: k=%0d expected %0d", out_k, got);
	$fwrite(f, "%04X%04X\n", out_re & 16'hFFFF, out_im & 16'hFFFF);
	got = got + 1;
end

initial begin
	$readmemh("../assets/input.hex", x);
	f = $fopen("diy_dump.txt", "w");
	$fwrite(f, "DIY SCALE=8\n");
	repeat (3) @(posedge clk);
	t0 = $time;
	for (i = 0; i < 256; i = i + 1) begin
		@(negedge clk) begin in_valid = 1; {in_re, in_im} = x[i]; end
	end
	@(negedge clk) in_valid = 0;
	wait (got == 256);
	t1 = $time;
	$fclose(f);
	$display("256 results in %0d clocks", (t1 - t0) / 20);
	$display("PASS");
	$finish;
end

initial begin #2_000_000; $display("FAIL: timeout, %0d results", got); $finish; end

endmodule
