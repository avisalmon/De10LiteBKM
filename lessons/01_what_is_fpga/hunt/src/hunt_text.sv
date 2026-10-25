// One line of text on the screen: LEN characters of the 8x8 font, each pixel drawn SCALE x SCALE, at (X, Y)
//
// text holds the FIRST character in its top byte, so a Verilog string literal of LEN characters works.
// on = 1 when pixel (x, y) is part of a letter.
// ***********************************************

module hunt_text #(
	parameter X = 0,
	parameter Y = 0,
	parameter LEN = 26,
	parameter SCALE = 3
)(
	input		[9:0]				x,
	input		[8:0]				y,
	input		[8*LEN-1:0]		text,
	output						on
	);

localparam CELL = 8 * SCALE;

wire	[9:0]		dx = x - X;
wire	[8:0]		dy = y - Y;
wire				in_box = (x >= X) && (x < X + LEN * CELL) && (y >= Y) && (y < Y + CELL);
wire	[6:0]		col = dx / CELL;											// which character
wire	[2:0]		px = (dx % CELL) / SCALE;								// pixel column inside the glyph
wire	[2:0]		py = dy / SCALE;											// glyph row
wire	[7:0]		ch = in_box ? text[8*(LEN - 1 - col) +: 8] : 8'h20;
wire	[7:0]		bits;

font8x8 font(.ch(ch), .row(py), .bits(bits));
assign on = in_box && bits[px];

endmodule
