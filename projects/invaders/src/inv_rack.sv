// The invader rack at one pixel: is an invader lit at (x, y), and which one.
//
// The arcade moves one invader per frame: invaders before the cursor have already moved to the new reference (and
// show the new animation frame), the rest are still at the old one. So every pixel has two candidates, one per
// reference. Used by the draw (every pixel) and by the game logic (collision tests): what you see is what the shot hits.
//
// Coordinates are the arcade's portrait screen: x 0..223 left to right, y 0..255 top to bottom. A reference is the
// top-left corner of the bottom-left invader's 16 x 8 cell; invader i = row * 11 + column, row 0 at the bottom,
// rows 16 pixels apart. Both x and y wrap modulo 256 like the arcade's 8-bit coordinates: the reference goes
// "negative" when the left columns are dead and the rack walks further left, and it passes line 255 (wrapping to 0)
// when the bottom rows are dead and the rack walks down; the live rows above it are still drawn, hit and turned.
// ***********************************************
`default_nettype none

module inv_rack_pixel (
	input		wire	[7:0]		x,
	input		wire	[7:0]		y,
	input		wire	[7:0]		old_x,
	input		wire	[7:0]		old_y,
	input		wire				old_frame,
	input		wire	[7:0]		new_x,
	input		wire	[7:0]		new_y,
	input		wire				new_frame,
	input		wire	[5:0]		cursor,			// invaders 0..cursor-1 are at the new reference
	input		wire				fill,				// first sweep of a wave: invaders not reached yet are not drawn
	input		wire	[54:0]	alive,
	output	logic				lit,
	output	logic	[5:0]		index				// the lit invader (the new candidate first)
	);

// one candidate: the cell under (px, py) for a reference (rx, ry) -> {ok, index, column in cell, row in cell, kind}
function automatic [15:0] rack_cell(input [7:0] px, input [7:0] py, input [7:0] rx, input [7:0] ry);
	logic [7:0] dx;
	logic [7:0] u;						// lines up from the bottom row's last line, modulo 256 like x
	logic [2:0] r;
	logic ok;
	logic [5:0] idx;
	logic [1:0] kind;
	dx = px - rx;
	u = ry + 8'd7 - py;
	r = u[6:4];
	ok = (dx < 8'd176) && (u < 8'd80) && !u[3];
	idx = ({3'b000, r} * 6'd11) + {2'b00, dx[7:4]};
	kind = (r <= 3'd1) ? 2'd0 : (r <= 3'd3) ? 2'd1 : 2'd2;
	rack_cell = {ok, idx, dx[3:0], ~u[2:0], kind};
endfunction

wire	[15:0]	c_old = rack_cell(x, y, old_x, old_y);
wire	[15:0]	c_new = rack_cell(x, y, new_x, new_y);
wire				v_old = c_old[15], v_new = c_new[15];
wire	[5:0]		i_old = c_old[14:9], i_new = c_new[14:9];
wire	[3:0]		cx_old = c_old[8:5], cx_new = c_new[8:5];
wire	[2:0]		row_old = c_old[4:2], row_new = c_new[4:2];
wire	[1:0]		k_old = c_old[1:0], k_new = c_new[1:0];

wire	[15:0]	b_old, b_new;
inv_invader_rom rom_old(.kind(k_old), .frame(old_frame), .row(row_old), .bits(b_old));
inv_invader_rom rom_new(.kind(k_new), .frame(new_frame), .row(row_new), .bits(b_new));

wire	lit_old = v_old && !fill && (i_old >= cursor) && alive[i_old] && b_old[cx_old];
wire	lit_new = v_new && (i_new < cursor) && alive[i_new] && b_new[cx_new];

assign lit = lit_old | lit_new;
assign index = lit_new ? i_new : i_old;

endmodule

`default_nettype wire
