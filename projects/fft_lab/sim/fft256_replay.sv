// Stand-in for the Altera FFT IP in the system testbench (Icarus cannot run the IP's encrypted model)
//
// Same module name and ports as the generated fft256. It answers a frame with the outputs the real IP gave for
// the same 256 inputs, at the same latency and with the same exponent: sim/record_ip.py recorded them from the
// real IP in ModelSim (sim/ip_vectors.hex). A frame it has no recording for gets no answer (a NOTE says so),
// which is also what an IP whose evaluation time ran out may do, so the engine's watchdog is tested too.
// mode (the testbench sets it: dut.eng.ip.mode = n): 0 replay, 1 silent (never answers), 2 answers all zeros.
// ***********************************************
`default_nettype none

module fft256 #(
	parameter FILE = "ip_vectors.hex",
	parameter MAXCASES = 64,
	parameter ZERO_LATENCY = 1381			// mode 2 answers this many clocks after the first input, like the IP
)(
	input		wire				clk,
	input		wire				reset_n,
	input		wire				inverse,
	input		wire				sink_valid,
	input		wire				sink_sop,
	input		wire				sink_eop,
	input		wire	[15:0]	sink_real,
	input		wire	[15:0]	sink_imag,
	input		wire	[1:0]		sink_error,
	output	wire				sink_ready,
	input		wire				source_ready,
	output	logic	[5:0]		source_exp = 6'd0,
	output	wire	[1:0]		source_error,
	output	logic				source_sop = 1'b0,
	output	logic				source_eop = 1'b0,
	output	logic				source_valid = 1'b0,
	output	logic	[15:0]	source_real = 16'd0,
	output	logic	[15:0]	source_imag = 16'd0
	);

integer			mode = 0;

// the recording: per case {CA, exp, latency}, 256 inputs, 256 outputs
logic	[31:0]	vec [0:MAXCASES*513-1];
integer			ncases = 0, nw = 0, fd;
initial begin
	fd = $fopen(FILE, "r");
	if (fd == 0) $display("FAIL: fft256 replay: cannot open %0s (run sim/record_ip.py)", FILE);
	else begin
		while (nw < MAXCASES * 513 && $fscanf(fd, "%h\n", vec[nw]) == 1) nw = nw + 1;
		$fclose(fd);
	end
	ncases = nw / 513;
end

assign sink_ready = reset_n;
assign source_error = 2'b00;

logic	[31:0]	inb [0:255];
integer			t = 0, t0 = 0, nin = 0, due = -1, k = 0, base = 0, c, i;
logic				zero = 1'b0, same;

// an answer starts (source_sop seen by the engine) "latency" clocks after the first input, then 256 in a row
always @(posedge clk) begin
	source_valid <= 1'b0;
	source_sop <= 1'b0;
	source_eop <= 1'b0;
	if (!reset_n) begin
		nin = 0; due = -1; k = 0;
	end
	else begin
		if (sink_valid) begin
			if (sink_sop) begin nin = 0; t0 = t; end
			if (nin < 256) inb[nin] = {sink_real, sink_imag};
			nin = nin + 1;
			if (sink_eop) begin
				if (nin != 256) $display("FAIL: fft256 replay: a frame of %0d samples", nin);
				else if (due >= 0) $display("FAIL: fft256 replay: a new frame before the last answer ended");
				else if (mode == 2) begin due = t0 + ZERO_LATENCY - 1; zero = 1'b1; source_exp <= 6'd0; end
				else if (mode == 0) begin
					base = -1;
					for (c = 0; c < ncases && base < 0; c = c + 1) begin
						same = 1'b1;
						for (i = 0; i < 256 && same; i = i + 1) if (vec[513 * c + 1 + i] != inb[i]) same = 1'b0;
						if (same) base = 513 * c;
					end
					if (base < 0) $display("NOTE: fft256 replay: no recording for this frame, no answer (the watchdog acts)");
					else begin
						due = t0 + vec[base][15:0] - 1;
						zero = 1'b0;
						source_exp <= vec[base][21:16];
					end
				end
			end
		end
		if (due >= 0 && t >= due) begin
			source_valid <= 1'b1;
			source_sop <= (k == 0);
			source_eop <= (k == 255);
			{source_real, source_imag} <= zero ? 32'd0 : vec[base + 257 + k];
			k = k + 1;
			if (k == 256) begin k = 0; due = -1; end
		end
		t = t + 1;
	end
end

endmodule

`default_nettype wire
