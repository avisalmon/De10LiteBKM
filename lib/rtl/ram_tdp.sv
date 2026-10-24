// True dual-port RAM in M9K: two independent read/write ports, each with its own clock
//
// Port A and port B can both read and write any address. Each q is the word at its address one clock later.
// Do not write the same address from both ports at the same time (the result is undefined).
// ***********************************************

module ram_tdp #(
	parameter WIDTH = 16,
	parameter AW = 12
)(
	input							clk_a,
	input		[AW-1:0]			addr_a,
	input		[WIDTH-1:0]		d_a,
	input							we_a,
	output reg	[WIDTH-1:0]	q_a,
	input							clk_b,
	input		[AW-1:0]			addr_b,
	input		[WIDTH-1:0]		d_b,
	input							we_b,
	output reg	[WIDTH-1:0]	q_b
	);

reg [WIDTH-1:0] mem [0:(1<<AW)-1];

always @(posedge clk_a) begin
	if (we_a) begin
		mem[addr_a] <= d_a;
		q_a <= d_a;
	end
	else
		q_a <= mem[addr_a];
end

always @(posedge clk_b) begin
	if (we_b) begin
		mem[addr_b] <= d_b;
		q_b <= d_b;
	end
	else
		q_b <= mem[addr_b];
end

endmodule
