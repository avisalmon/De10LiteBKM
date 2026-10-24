// Binary to decimal digits (double dabble), combinational
//
// bin2bcd #(.BITS(20), .DIGITS(6)) u(.bin(x), .bcd(d));  d[3:0] = ones, d[7:4] = tens, ...
// Fine for display values (up to ~24 bits at 25-50 MHz); for wider values use a sequential divider.
// ***********************************************

module bin2bcd #(
	parameter BITS = 20,
	parameter DIGITS = 6
)(
	input		[BITS-1:0]		bin,
	output	[4*DIGITS-1:0]	bcd
	);

logic [4*DIGITS-1:0] d;

always_comb begin
	d = 0;
	for (int i = BITS - 1; i >= 0; i--) begin
		for (int k = 0; k < DIGITS; k++)
			if (d[4*k +: 4] >= 5)
				d[4*k +: 4] = d[4*k +: 4] + 4'd3;
		d = {d[4*DIGITS-2:0], bin[i]};
	end
end

assign bcd = d;

endmodule
