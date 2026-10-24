// Lesson 0 simulation check: the smallest useful circuit, an AND gate
// ***********************************************

module and_gate (
	input		a,
	input		b,
	output	y
	);

assign y = a & b;

endmodule
