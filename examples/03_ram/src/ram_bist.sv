// Single-port RAM self-test (BIST): write a pseudo-random pattern to every word, read it all back, compare.
//
// Runs forever: pass 1, 2, 3 ... each pass uses a new pattern (16-bit LFSR, seed = pass number), so a stuck or
// shorted bit, a wrong address or a read on the wrong clock shows up as errors. inject = 1 flips one bit of one
// word per pass on purpose: the test must then report exactly one error per pass (proves the checker works).
// ***********************************************

module ram_bist #(
	parameter AW = 13					// 8,192 words x 16 bits
)(
	input						clk,
	input						inject,
	output reg	[31:0]	passes = 0,
	output reg	[31:0]	errors = 0,		// total since power-up
	output reg	[15:0]	last_errors = 0,	// in the last pass
	output reg				pass_done = 0
	);

localparam N = 1 << AW;

reg	[AW-1:0]	addr = 0;
reg	[15:0]	lfsr = 16'h1234;		// seed of pass 0 (seed = passes + 0x1234)
reg	[15:0]	expect_q = 0;
reg	[15:0]	pass_err = 0;
reg			writing = 1;
reg			check = 0;			// rd data valid this clock
wire	[15:0]	q;

function automatic [15:0] next(input [15:0] v);	// x^16 + x^14 + x^13 + x^11 + 1
	next = {v[14:0], v[15] ^ v[13] ^ v[12] ^ v[10]};
endfunction

wire	[15:0]	wdata = (inject && addr == 100) ? lfsr ^ 16'h0040 : lfsr;

ram_sp #(.WIDTH(16), .AW(AW)) ram(.clk(clk), .addr(addr), .d(wdata), .we(writing), .q(q));

always @(posedge clk) begin
	pass_done <= 0;
	check <= !writing;
	expect_q <= lfsr;					// the value written at this address, for the compare one clock later
	if (check && q != expect_q) begin
		pass_err <= pass_err + 1'b1;
		errors <= errors + 1'b1;
	end

	lfsr <= next(lfsr);
	addr <= addr + 1'b1;
	if (addr == N - 1) begin
		if (writing) begin
			writing <= 0;
			lfsr <= passes[15:0] + 16'h1234;		// replay the same sequence for the read
		end
		else begin
			writing <= 1;
			passes <= passes + 1'b1;
			last_errors <= pass_err + ((check && q != expect_q) ? 1'b1 : 1'b0);
			pass_err <= 0;
			pass_done <= 1;
			lfsr <= passes[15:0] + 1'b1 + 16'h1234;	// new pattern for the next pass
		end
	end
end

endmodule
