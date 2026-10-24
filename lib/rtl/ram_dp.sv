// Simple dual-port RAM in M9K: one write port and one read port, each with its own clock
//
// The usual frame-buffer / FIFO / clock-crossing memory: write side and read side can run on different clocks
// (e.g. 50 MHz logic writes, the 25 MHz pixel clock reads). rd_q = the word at rd_addr one rd_clk later.
// Reading an address in the same moment it is written from the other clock gives old or new data (never
// garbage bits from both); design so that it does not matter (a picture pixel, a flag written last...).
// ***********************************************

module ram_dp #(
	parameter WIDTH = 12,
	parameter AW = 15,
	parameter DEPTH = 1 << AW,		// fewer words than 2^AW saves block memory
	parameter INIT_FILE = ""
)(
	input							wr_clk,
	input		[AW-1:0]			wr_addr,
	input		[WIDTH-1:0]		wr_d,
	input							we,
	input							rd_clk,
	input		[AW-1:0]			rd_addr,
	output reg	[WIDTH-1:0]	rd_q
	);

reg [WIDTH-1:0] mem [0:DEPTH-1];

initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

always @(posedge wr_clk)
	if (we)
		mem[wr_addr] <= wr_d;

always @(posedge rd_clk)
	rd_q <= mem[rd_addr];

endmodule
