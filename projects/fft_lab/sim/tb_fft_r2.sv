// Unit test: our FFT (fft_r2) against the model: every output of every frame, bit for bit, in order, and its time
// python projects/fft_lab/sim/lab_model.py expect      (writes sim/expect_fft.hex: per frame a header
//        0xFF7 << 20 | clocks << 4 | paced, the 256 inputs {re, im}, then the model's 256 outputs {re, im};
//        clocks = first input to last output, inclusive; paced frames come with random gaps and are not timed)
// python scripts/sim.py projects/fft_lab/sim/tb_fft_r2.sv
// sim-sources: ../src/fft_r2.sv
`timescale 1ns/1ns

module tb_fft_r2;

logic				clk = 0, in_valid = 0;
logic signed [15:0]	in_re = 0, in_im = 0;
wire				out_valid, busy;
wire	[7:0]		out_k;
wire signed [15:0]	out_re, out_im;
logic	[31:0]	ex [0:8191];
logic	[31:0]	h, w;
integer			c, i, fd, nw = 0, frames = 0, base, got, idle, errs = 0, timed = 0, gaps = 0;
integer			t_first, clocks, t_clocks = 0;

always #20 clk = ~clk;

fft_r2 #(.TWIDDLE_FILE("../assets/twiddle.hex")) dut(.clk(clk), .in_valid(in_valid), .in_re(in_re), .in_im(in_im),
	.out_valid(out_valid), .out_k(out_k), .out_re(out_re), .out_im(out_im), .busy(busy));

initial begin
	for (c = 0; c < 8192; c = c + 1) ex[c] = 32'hx;
	fd = $fopen("expect_fft.hex", "r");
	if (fd) begin
		while (nw < 8192 && $fscanf(fd, "%h\n", ex[nw]) == 1) nw = nw + 1;
		$fclose(fd);
	end
	while (ex[frames * 513][31:20] === 12'hFF7) frames = frames + 1;
	if (frames == 0) begin $display("FAIL: no frames in expect_fft.hex (run lab_model.py expect)"); $finish; end
	repeat (3) @(negedge clk);
	for (c = 0; c < frames; c = c + 1) begin
		base = c * 513;
		h = ex[base];
		while (busy) @(negedge clk);
		// feed the 256 inputs; a paced frame skips about one clock in four and shows junk while not valid
		i = 0;
		while (i < 256) begin
			@(negedge clk);
			if (h[0] && i > 0 && ($random & 3) == 0) begin
				in_valid = 0; in_re = $random; in_im = $random; gaps = gaps + 1;
			end
			else begin
				in_valid = 1; {in_re, in_im} = ex[base + 1 + i];
				if (i == 0) t_first = $time + 20;					// the edge that takes the first input = clock 1
				i = i + 1;
			end
		end
		@(negedge clk) begin in_valid = 0; in_re = $random; in_im = $random; end
		if (!busy) begin $display("FAIL: frame %0d: not busy after its inputs", c); errs = errs + 1; end
		// the 256 outputs, in order, each equal to the model
		got = 0; idle = 0;
		while (got < 256 && idle < 20000) begin
			@(posedge clk);
			idle = idle + 1;
			if (out_valid) begin
				w = ex[base + 257 + got];
				if (out_k !== got[7:0] || out_re !== w[31:16] || out_im !== w[15:0]) begin
					errs = errs + 1;
					if (errs <= 10)
						$display("FAIL: frame %0d output %0d: k=%0d re=%0d im=%0d, model re=%0d im=%0d", c, got,
							out_k, out_re, out_im, $signed(w[31:16]), $signed(w[15:0]));
				end
				got = got + 1;
				idle = 0;
				if (got == 256) clocks = ($time - t_first) / 40 + 1;	// the edge that takes the last output
			end
		end
		if (got != 256) begin $display("FAIL: frame %0d: %0d outputs, expected 256", c, got); errs = errs + 1; end
		else if (!h[0]) begin
			timed = timed + 1;
			t_clocks = clocks;
			if (clocks != h[19:4]) begin
				$display("FAIL: frame %0d: %0d clocks from the first input to the last output, model %0d",
					c, clocks, h[19:4]);
				errs = errs + 1;
			end
		end
		repeat (2) @(negedge clk);
		if (busy) begin $display("FAIL: frame %0d: still busy after its last output", c); errs = errs + 1; end
	end
	if (errs == 0)
		$display("PASS: fft_r2: %0d frames x 256 outputs equal the model bit for bit (%0d gaps in the input); %0d frames timed, %0d clocks each",
			frames, gaps, timed, t_clocks);
	else
		$display("FAIL: fft_r2: %0d errors", errs);
	$finish;
end

endmodule
