// Binary to decimal digits, one bit per clock (double dabble, sequential)
//
// Pulse start with bin; BITS clocks later done pulses and bcd holds the digits (bcd[3:0] = ones).
// Use it when the result goes into a register on a fast clock (text for the PC, ...): the combinational
// bin2bcd or a "/ 10" chain can be too slow for 50 MHz (example 07 failed timing by 15 ns before this).
// ***********************************************

module bin2bcd_seq #(
	parameter BITS = 16,
	parameter DIGITS = 5
)(
	input							clk,
	input							start,
	input		[BITS-1:0]		bin,
	output reg	[4*DIGITS-1:0]	bcd = 0,
	output reg					done = 0,
	output						busy
	);

reg	[BITS-1:0]		sh = 0;
reg	[4*DIGITS-1:0]	d = 0;
reg	[$clog2(BITS+1)-1:0]	n = 0;
reg						active = 0;

assign busy = active;

// add 3 to every digit that is 5 or more (before the shift)
function automatic [4*DIGITS-1:0] adjust(input [4*DIGITS-1:0] v);
	integer k;
	begin
		adjust = v;
		for (k = 0; k < DIGITS; k = k + 1)
			if (v[4*k +: 4] >= 5) adjust[4*k +: 4] = v[4*k +: 4] + 4'd3;
	end
endfunction

wire	[4*DIGITS-1:0]	a = adjust(d);

always @(posedge clk) begin
	done <= 0;
	if (!active) begin
		if (start) begin
			sh <= bin;
			d <= 0;
			n <= 0;
			active <= 1;
		end
	end
	else begin
		d <= {a[4*DIGITS-2:0], sh[BITS-1]};
		sh <= sh << 1;
		n <= n + 1'b1;
		if (n == BITS - 1) begin
			active <= 0;
			bcd <= {a[4*DIGITS-2:0], sh[BITS-1]};
			done <= 1;
		end
	end
end

endmodule
