// Example 05 picture: a test card with a box the PC can move
//
// Colour bars (top), a 16-step grey ramp (middle), a white grid every 64 pixels, the title in 8x8 text x2, and a
// 32x32 box at (bx, by). Combinational from the pixel position, like every screen in this BKM.
// ***********************************************

module test_card (
	input		[31:0]	pxl_x,
	input		[31:0]	pxl_y,
	input		[9:0]		bx,
	input		[8:0]		by,
	output	[11:0]	rgb
	);

wire	[9:0]		x = pxl_x[9:0];
wire	[8:0]		y = pxl_y[8:0];

// title: "05 SCREEN READBACK" at character row 1, columns 2..19 (16-pixel cells)
localparam [8*18-1:0] TITLE = "05 SCREEN READBACK";
wire	[5:0]		col = x[9:4];
wire	[7:0]		ch = (y[8:4] == 1 && col >= 2 && col < 20) ? TITLE[8*(19 - col) +: 8] : 8'h20;
wire	[7:0]		bits;
font8x8 font(.ch(ch), .row(y[3:1]), .bits(bits));

wire	[3:0]		bar = x / 10'd80;											// 0..7
wire	[4:0]		step = x / 10'd40;										// 0..15
logic [11:0] c;
always_comb begin
	if (y < 160)																// 8 colour bars, 80 pixels each
		case (bar)
			0: c = 12'hFFF;  1: c = 12'hFF0;  2: c = 12'h0FF;  3: c = 12'h0F0;
			4: c = 12'hF0F;  5: c = 12'hF00;  6: c = 12'h00F;  default: c = 12'h000;
		endcase
	else if (y < 320)															// grey ramp, 16 steps of 40 pixels
		c = {3{step[3:0]}};
	else
		c = 12'h124;
	if (x[5:0] == 0 || y[5:0] == 0) c = 12'h888;							// grid
	if (bits[x[3:1]]) c = 12'hFFF;											// title
	if (x >= bx && x < bx + 10'd32 && y >= by && y < by + 9'd32) c = 12'hFFF;	// the box
end
assign rgb = c;

endmodule
