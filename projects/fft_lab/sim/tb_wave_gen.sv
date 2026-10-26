// Unit test: wave_gen against the model, every sample of every frame, with random output stalls
// python projects/fft_lab/sim/lab_model.py expect      (writes sim/expect_wave.hex: per frame a header
//        0xC5000000 | win << 16 | shape << 12 | fq, then 256 samples; one generator runs through all frames)
// python scripts/sim.py projects/fft_lab/sim/tb_wave_gen.sv
// sim-sources: ../src/wave_gen.sv
`timescale 1ns/1ns

module tb_wave_gen;

logic				clk = 0, start = 0, win = 0, ready = 0;
logic	[2:0]		shape = 0;
logic	[9:0]		fq = 0;
wire				valid, busy;
wire	[7:0]		n;
wire signed [15:0]	x;
logic	[31:0]	ex [0:8191];
logic	[31:0]	h;
logic				waited = 0;
logic	[7:0]		wait_n;
logic	[15:0]	wait_x;
integer			c, fd, nw = 0, frames = 0, got, errs = 0, stalls = 0, holds_bad = 0;

always #20 clk = ~clk;

wave_gen #(.SINE_FILE("../assets/sine.hex"), .HANN_FILE("../assets/hann.hex")) dut(
	.clk(clk), .start(start), .shape(shape), .fq(fq), .win(win), .ready(ready),
	.valid(valid), .n(n), .x(x), .busy(busy));

always @(negedge clk) ready = ($random & 3) != 0;		// the sink stalls about one clock in four

// a sample that waits (valid && !ready) must stay the same until it moves
always @(posedge clk) begin
	if (waited && valid && (n !== wait_n || x !== wait_x)) holds_bad = holds_bad + 1;
	waited = valid && !ready;
	wait_n = n; wait_x = x;
	if (valid && !ready) stalls = stalls + 1;
end

initial begin
	for (c = 0; c < 8192; c = c + 1) ex[c] = 32'hx;
	fd = $fopen("expect_wave.hex", "r");
	if (fd) begin
		while (nw < 8192 && $fscanf(fd, "%h\n", ex[nw]) == 1) nw = nw + 1;
		$fclose(fd);
	end
	while (ex[frames * 257][31:24] === 8'hC5) frames = frames + 1;
	if (frames == 0) begin $display("FAIL: no frames in expect_wave.hex (run lab_model.py expect)"); $finish; end
	repeat (3) @(negedge clk);
	for (c = 0; c < frames; c = c + 1) begin
		h = ex[c * 257];
		while (busy) @(negedge clk);
		@(negedge clk) begin start = 1; shape = h[14:12]; fq = h[9:0]; win = h[16]; end
		@(negedge clk) begin start = 0; shape = 3'd7; fq = 10'h3FF; win = 0; end	// latched: changes must not leak
		got = 0;
		while (got < 256) begin
			@(posedge clk);
			if (valid && ready) begin
				if (n !== got[7:0] || x !== ex[c * 257 + 1 + got][15:0]) begin
					errs = errs + 1;
					if (errs <= 10)
						$display("FAIL: frame %0d (shape %0d fq %0d win %0d) sample %0d: n=%0d x=%0d, model x=%0d",
							c, h[14:12], h[9:0], h[16], got, n, x, $signed(ex[c * 257 + 1 + got][15:0]));
				end
				got = got + 1;
			end
		end
	end
	repeat (5) @(negedge clk);
	if (busy) begin $display("FAIL: still busy after the last frame"); errs = errs + 1; end
	if (holds_bad) begin $display("FAIL: %0d waiting samples changed before they moved", holds_bad); errs = errs + 1; end
	if (errs == 0)
		$display("PASS: wave_gen: %0d frames x 256 samples equal the model (%0d stalled clocks)", frames, stalls);
	else
		$display("FAIL: wave_gen: %0d errors", errs);
	$finish;
end

endmodule
