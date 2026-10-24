// Multiply-accumulate engine: acc = sum of a[i] * b[i] for N pairs of 18-bit signed pseudo-random numbers
//
// USE_DSP = 1: the product is built in the MAX 10's embedded 18x18 multipliers (multstyle "dsp").
// USE_DSP = 0: the same product in logic elements (multstyle "logic"), for comparison.
// a and b come from two 32-bit Galois LFSRs (scripts: examples/12_dsp_multipliers/sim/mac_reference.py makes the
// same numbers), so the result is known in advance. Pipeline: product register, then accumulator: 1 pair per clock.
// ***********************************************

module mac #(
	parameter USE_DSP = 1,
	parameter N = 1_000_000
)(
	input							clk,
	input							start,
	output reg signed [47:0]	acc = 0,
	output reg					done = 0,
	output reg	[31:0]		cycles = 0
	);

reg	[31:0]	la = 32'h1234_5678, lb = 32'h9ABC_DEF1;
reg				run = 0, run_d = 0;
reg	[31:0]	n = 0;
wire signed [17:0]	a = la[17:0];
wire signed [17:0]	b = lb[17:0];
reg signed [35:0]	p = 0;

function automatic [31:0] step(input [31:0] v);		// Galois LFSR, taps 0x80200003 (x^32+x^22+x^2+x+1)
	step = v[0] ? (v >> 1) ^ 32'h80200003 : v >> 1;
endfunction

// the multiplier style is set on a module (Quartus ignored multstyle on a wire inside generate: both engines
// ended up in DSP blocks)
wire signed [35:0]	m;
generate
	if (USE_DSP) begin : prod
		mult18_dsp   mul(.a(a), .b(b), .p(m));
	end
	else begin : prod
		mult18_logic mul(.a(a), .b(b), .p(m));
	end
endgenerate
always @(posedge clk) p <= m;

always @(posedge clk) begin
	done <= 0;
	run_d <= run;
	if (start && !run) begin
		la <= 32'h1234_5678;
		lb <= 32'h9ABC_DEF1;
		n <= 0;
		run <= 1;
		acc <= 0;
		cycles <= 0;
	end
	else if (run) begin
		la <= step(la);
		lb <= step(lb);
		n <= n + 1'b1;
		if (n == N - 1) run <= 0;
	end
	if (run || run_d) cycles <= cycles + 1'b1;
	if (run_d) acc <= acc + p;				// p belongs to the pair from the clock before
	if (run_d && !run) done <= 1;
end

endmodule

(* multstyle = "dsp" *)
module mult18_dsp (input signed [17:0] a, input signed [17:0] b, output signed [35:0] p);
	assign p = a * b;
endmodule

(* multstyle = "logic" *)
module mult18_logic (input signed [17:0] a, input signed [17:0] b, output signed [35:0] p);
	assign p = a * b;
endmodule
