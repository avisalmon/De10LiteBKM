// Debounce N inputs: an output follows its input only after the input has been steady for STEADY clocks
//
// STEADY = 500_000 at 50 MHz = 10 ms (buttons bounce for a few ms). Inputs pass a 2-flop synchronizer first,
// so they may come from any clock or straight from a pin.
// ***********************************************

module debounce #(
	parameter N = 1,
	parameter STEADY = 500_000
)(
	input						clk,
	input			[N-1:0]	in,
	output reg	[N-1:0]	out = 0
	);

reg	[N-1:0]	s1 = 0, s2 = 0;
always @(posedge clk) begin
	s1 <= in;
	s2 <= s1;
end

genvar i;
generate
	for (i = 0; i < N; i = i + 1) begin : bit_
		reg [$clog2(STEADY+1)-1:0] n = 0;
		always @(posedge clk) begin
			if (s2[i] == out[i])
				n <= 0;
			else if (n == STEADY - 1) begin
				out[i] <= s2[i];
				n <= 0;
			end
			else
				n <= n + 1'b1;
		end
	end
endgenerate

endmodule
