// Every game object's pixel at one point (x, y), each layer separately. The screen (inv_draw) asks at the beam's
// position; the game logic (inv_logic) asks at its probe point for collisions and the rack's edge test, so both
// always agree on what is where. Arcade coordinates: portrait, 224 x 256, y = 0 at the top.
// All combinational, except shield_word: the shield RAM's word for column x, which the caller reads.
// ***********************************************
`default_nettype none

module inv_layers #(
	parameter	[7:0]	SAUCER_Y = 8'd40,			// top line of the saucer
	parameter	[7:0]	SHIELD_Y = 8'd192,			// top line of the shields (16 lines)
	parameter	[7:0]	PLAYER_Y = 8'd216,			// top line of the cannon
	parameter	[7:0]	GROUND_Y = 8'd239			// the ground line
	) (
	input		wire	[7:0]		x, y,
	input		wire	[15:0]	shield_word,
	// the rack (see inv_rack_pixel)
	input		wire				rack_on,
	input		wire	[7:0]		old_x, old_y, new_x, new_y,
	input		wire				old_frame, new_frame,
	input		wire	[5:0]		cursor,
	input		wire				fill,
	input		wire	[54:0]	alive,
	// an invader's explosion (16 x 8, top-left corner)
	input		wire				aexp_on,
	input		wire	[7:0]		aexp_x, aexp_y,
	// the cannon (16 x 8 at line PLAYER_Y): image 0 = the cannon, 1 and 2 = its explosion
	input		wire				pl_on,
	input		wire	[1:0]		pl_img,
	input		wire	[7:0]		pl_x,
	// the player's shot: 1 = flying (1 x 4, top end at sh_y), 2 = bursting (8 x 8, top-left)
	input		wire	[1:0]		sh_st,
	input		wire	[7:0]		sh_x, sh_y,
	// three bombs, slot = kind (twister, plunger, zigzag): 1 = falling (3 x 8), 2 = bursting (6 x 8); top-left
	input		wire	[5:0]		bm_st,
	input		wire	[23:0]	bm_x, bm_y,
	input		wire	[5:0]		bm_frame,
	// the saucer (24 x 8 box at line SAUCER_Y): 1 = flying, 2 = exploding (3 = its score: text, drawn by inv_draw)
	input		wire	[1:0]		sc_st,
	input		wire	[7:0]		sc_x,
	// the ground line, one bit per column (bombs punch holes in it)
	input		wire	[223:0]	ground,
	output	wire				rack_px,
	output	wire	[5:0]		rack_idx,
	output	wire				ae_px, pl_px, sh_px,
	output	wire	[2:0]		bm_px,
	output	wire				sc_px, shd_px, gnd_px
	);

// ---- the rack
wire				rack_lit;
inv_rack_pixel rack(.x(x), .y(y), .old_x(old_x), .old_y(old_y), .old_frame(old_frame), .new_x(new_x), .new_y(new_y),
	.new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive), .lit(rack_lit), .index(rack_idx));
assign rack_px = rack_on && rack_lit;

// ---- an invader's explosion
wire	[7:0]		ae_dx = x - aexp_x, ae_dy = y - aexp_y;
wire	[15:0]	ae_bits;
inv_invader_rom ae_rom(.kind(2'd3), .frame(1'b0), .row(ae_dy[2:0]), .bits(ae_bits));
assign ae_px = aexp_on && ae_dx < 8'd16 && ae_dy < 8'd8 && ae_bits[ae_dx[3:0]];

// ---- the cannon
wire	[7:0]		pl_dx = x - pl_x, pl_dy = y - PLAYER_Y;
wire	[15:0]	pl_bits;
inv_cannon_rom pl_rom(.img(pl_img), .row(pl_dy[2:0]), .bits(pl_bits));
assign pl_px = pl_on && pl_dx < 8'd16 && pl_dy < 8'd8 && pl_bits[pl_dx[3:0]];

// ---- the player's shot
wire	[7:0]		sh_dx = x - sh_x, sh_dy = y - sh_y;
wire	[7:0]		shb_bits;
inv_burst_rom shb_rom(.img(1'b0), .row(sh_dy[2:0]), .bits(shb_bits));
assign sh_px = (sh_st == 2'd1 && sh_dx == 8'd0 && sh_dy < 8'd4) ||
					(sh_st == 2'd2 && sh_dx < 8'd8 && sh_dy < 8'd8 && shb_bits[sh_dx[2:0]]);

// ---- the bombs
genvar b;
generate for (b = 0; b < 3; b = b + 1) begin : bomb
	localparam [1:0] KIND = (b == 0) ? 2'd0 : (b == 1) ? 2'd1 : 2'd2;
	wire	[1:0]		st = bm_st[2*b +: 2];
	wire	[7:0]		dx = x - bm_x[8*b +: 8], dy = y - bm_y[8*b +: 8];
	wire	[2:0]		bits;
	wire	[7:0]		bb;
	inv_bomb_rom rom(.kind(KIND), .frame(bm_frame[2*b +: 2]), .row(dy[2:0]), .bits(bits));
	inv_burst_rom brom(.img(1'b1), .row(dy[2:0]), .bits(bb));
	assign bm_px[b] = (st == 2'd1 && dx < 8'd3 && dy < 8'd8 && bits[dx[1:0]]) ||
							(st == 2'd2 && dx < 8'd8 && dy < 8'd8 && bb[dx[2:0]]);
end endgenerate

// ---- the saucer
wire	[7:0]		sc_dx = x - sc_x, sc_dy = y - SAUCER_Y;
wire	[23:0]	sc_bits;
inv_saucer_rom sc_rom(.img(sc_st == 2'd2), .row(sc_dy[2:0]), .bits(sc_bits));
assign sc_px = (sc_st == 2'd1 || sc_st == 2'd2) && sc_dx < 8'd24 && sc_dy < 8'd8 && sc_bits[sc_dx[4:0]];

// ---- shields and ground
wire	[7:0]		shd_dy = y - SHIELD_Y;
assign shd_px = shd_dy < 8'd16 && shield_word[shd_dy[3:0]];
assign gnd_px = y == GROUND_Y && x < 8'd224 && ground[x];

endmodule

`default_nettype wire
