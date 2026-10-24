// Single-port RAM in M9K block memory (inferred: Quartus' recommended coding style)
//
// One address for both write and read, one clock. q = the word at addr, one clock after addr
// ("old data" when writing the same address in the same clock). INIT_FILE: optional $readmemh file.
// ***********************************************

module ram_sp #(
	parameter WIDTH = 16,
	parameter AW = 13,				// 2^AW words
	parameter DEPTH = 1 << AW,		// fewer words than 2^AW saves block memory
	parameter INIT_FILE = ""
)(
	input							clk,
	input		[AW-1:0]			addr,
	input		[WIDTH-1:0]		d,
	input							we,
	output reg	[WIDTH-1:0]	q
	);

reg [WIDTH-1:0] mem [0:DEPTH-1];

initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

always @(posedge clk) begin
	if (we)
		mem[addr] <= d;
	q <= mem[addr];
end

endmodule
