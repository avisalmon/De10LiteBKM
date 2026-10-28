// Space Invaders screen: 320 x 240 (each pixel is 2 x 2 of the 640 x 480 scan).
//
// The arcade's monitor stands on its side: a portrait picture 224 wide and 256 tall. We show its 224 columns in the
// middle of the screen (screen x 48..271) and its lines 8..247, which are all the lines that ever hold anything:
// arcade pixel (px, py) = (lx - 48, ly + 8).
//
// Like the arcade, the picture is one bit per pixel and the colour comes from the "cellophane" overlay in front of
// the tube: a red band across the saucer's flight, a green band across the shields, the cannon and the spare ships,
// white elsewhere (the bands of MAME's layout file invaders.lay). Every layer is worked out from the game state at each pixel ("racing the beam"); the two memories
// (text, shields) answer one clock late, so they are addressed with the NEXT scan pixel (x + 1), as in Pac-Man.
// ***********************************************
`default_nettype none

module inv_draw #(
	parameter	[7:0]	SAUCER_Y = 8'd40,			// top line of the saucer
	parameter	[7:0]	SHIELD_Y = 8'd192,			// top line of the shields (16 lines)
	parameter	[7:0]	PLAYER_Y = 8'd216,			// top line of the cannon
	parameter	[7:0]	GROUND_Y = 8'd239,			// the ground line
	parameter	[7:0]	RED_Y0 = 8'd32, RED_Y1 = 8'd62,				// overlay bands: lines [Y0, Y1), as MAME's invaders.lay
	parameter	[7:0]	GREEN_Y0 = 8'd184, GREEN_Y1 = 8'd240,
	parameter	[7:0]	SHIPS_X0 = 8'd16, SHIPS_X1 = 8'd134			// green under the spare ships, from GREEN_Y1 down
	) (
	input		wire				clk,
	input		wire	[31:0]	pxl_x,
	input		wire	[31:0]	pxl_y,
	// text: 32 lines x 32 columns of characters (28 used), address {row, column}; codes 8'h80.. are icons
	output	logic	[9:0]		tb_addr,
	input		wire	[7:0]		tb_q,
	// shields: one 16-bit word per arcade column, bit r = line SHIELD_Y + r
	output	logic	[7:0]		sb_addr,
	input		wire	[15:0]	sb_q,
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
	// the saucer (24 x 8 box at line SAUCER_Y): 1 = flying, 2 = exploding, 3 = showing its score
	input		wire	[1:0]		sc_st,
	input		wire	[7:0]		sc_x,
	input		wire	[11:0]	sc_score,		// 3 BCD digits
	// the ground line, one bit per column (bombs punch holes in it)
	input		wire	[223:0]	ground,
	output	logic	[11:0]	rgb
	);

wire				visible = pxl_x < 32'd640 && pxl_y < 32'd480;
wire	[8:0]		lx = pxl_x[9:1];
wire	[7:0]		ly = pxl_y[8:1];
wire				in_field = visible && lx >= 9'd48 && lx < 9'd272;
wire	[8:0]		px9 = lx - 9'd48;
wire	[7:0]		px = px9[7:0];
wire	[7:0]		py = ly + 8'd8;

// ---- memories, addressed one scan pixel ahead (the next pixel is on the same line wherever it matters)
wire	[9:0]		nx = pxl_x[9:0] + 10'd1;
wire	[8:0]		npx = nx[9:1] - 9'd48;
assign tb_addr = {py[7:3], npx[7:3]};
assign sb_addr = npx[7:0];

// ---- the saucer's box (also where its score is printed)
wire	[7:0]		sc_dx = px - sc_x, sc_dy = py - SAUCER_Y;
wire				in_sbox = sc_dx < 8'd24 && sc_dy < 8'd8;
wire				show_score = sc_st == 2'd3 && in_sbox;

// ---- text and icons
wire	[1:0]		sc_digit = sc_dx[4:3];
wire	[3:0]		sd2 = sc_score[11:8], sd1 = sc_score[7:4], sd0 = sc_score[3:0];
wire	[3:0]		sdig = sc_digit == 2'd0 ? sd2 : sc_digit == 2'd1 ? sd1 : sd0;
wire	[7:0]		ch = !show_score ? tb_q : (sc_digit == 2'd0 && sd2 == 4'd0) ? 8'h20 : {4'h3, sdig};
wire	[2:0]		gcol = show_score ? sc_dx[2:0] : px[2:0];
wire	[2:0]		grow = show_score ? sc_dy[2:0] : py[2:0];

wire	[7:0]		fbits;
font8x8 font(.ch(ch), .row(grow), .bits(fbits));

// icons in the text: 80/81 cannon, 82-87 the invaders (10, 20, 30 points), 88-8A the saucer; 8 columns each
wire	[1:0]		ic_kind = ch[2:1] - 2'd1;
wire	[15:0]	ic_cannon, ic_inv;
wire	[23:0]	ic_sauc;
inv_cannon_rom ic_c(.img(2'd0), .row(grow), .bits(ic_cannon));
inv_invader_rom ic_i(.kind(ic_kind), .frame(1'b0), .row(grow), .bits(ic_inv));
inv_saucer_rom ic_s(.img(1'b0), .row(grow), .bits(ic_sauc));
wire	[3:0]		ic_sel = ch[3:0];
wire	[7:0]		ic_c0 = ic_cannon[7:0], ic_c1 = ic_cannon[15:8], ic_i0 = ic_inv[7:0], ic_i1 = ic_inv[15:8];
wire	[7:0]		ic_s0 = ic_sauc[7:0], ic_s1 = ic_sauc[15:8], ic_s2 = ic_sauc[23:16];
logic	[7:0]		ic_bits;
always_comb
	case (ic_sel)
		4'd0: ic_bits = ic_c0;
		4'd1: ic_bits = ic_c1;
		4'd2, 4'd4, 4'd6: ic_bits = ic_i0;
		4'd3, 4'd5, 4'd7: ic_bits = ic_i1;
		4'd8: ic_bits = ic_s0;
		4'd9: ic_bits = ic_s1;
		4'd10: ic_bits = ic_s2;
		default: ic_bits = 8'h00;
	endcase
wire				text_px = ch[7] ? ic_bits[gcol] : fbits[gcol];

// ---- the game objects (shared with the logic's collision tests)
wire				rack_px, ae_px, pl_px, sh_px, sc_px, shd_px, gnd_px;
wire	[5:0]		rack_idx;
wire	[2:0]		bm_px;
inv_layers #(.SAUCER_Y(SAUCER_Y), .SHIELD_Y(SHIELD_Y), .PLAYER_Y(PLAYER_Y), .GROUND_Y(GROUND_Y)) layers(
	.x(px), .y(py), .shield_word(sb_q),
	.rack_on(rack_on), .old_x(old_x), .old_y(old_y), .new_x(new_x), .new_y(new_y), .old_frame(old_frame),
	.new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive),
	.aexp_on(aexp_on), .aexp_x(aexp_x), .aexp_y(aexp_y), .pl_on(pl_on), .pl_img(pl_img), .pl_x(pl_x),
	.sh_st(sh_st), .sh_x(sh_x), .sh_y(sh_y), .bm_st(bm_st), .bm_x(bm_x), .bm_y(bm_y), .bm_frame(bm_frame),
	.sc_st(sc_st), .sc_x(sc_x), .ground(ground),
	.rack_px(rack_px), .rack_idx(rack_idx), .ae_px(ae_px), .pl_px(pl_px), .sh_px(sh_px), .bm_px(bm_px),
	.sc_px(sc_px), .shd_px(shd_px), .gnd_px(gnd_px));

// ---- compose: one bit, coloured by the overlay band
wire				on = text_px | rack_px | ae_px | pl_px | sh_px | (|bm_px) | sc_px | shd_px | gnd_px;
always_comb begin
	rgb = 12'h000;
	if (in_field && on) begin
		if (py >= RED_Y0 && py < RED_Y1) rgb = 12'hF22;
		else if (py >= GREEN_Y0 && py < GREEN_Y1) rgb = 12'h2F2;
		else if (py >= GREEN_Y1 && px >= SHIPS_X0 && px < SHIPS_X1) rgb = 12'h2F2;
		else rgb = 12'hFFF;
	end
end

endmodule

`default_nettype wire
