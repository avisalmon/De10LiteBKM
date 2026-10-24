// One ghost, 14 x 14, centred on (gx - 0.5, gy - 0.5) in maze pixels. Pure combinational from the pixel.
// Body: two skirt frames; eyes look where it goes; frightened: blue with a wavy mouth (white/red when flashing);
// eaten (EYES / ENTER): only the eyes travel home.
// ***********************************************
`default_nettype none

module ghost_sprite #(parameter logic [11:0] COLOR = 12'hF00) (
	input		wire	[8:0]		mx,			// maze pixel of the screen pixel
	input		wire	[8:0]		my,
	input		wire	[7:0]		gx, gy,
	input		wire	[1:0]		dir,			// 0 up, 1 left, 2 down, 3 right
	input		wire	[2:0]		st,			// 0 HOUSE, 1 LEAVE, 2 ACTIVE, 3 EYES, 4 ENTER
	input		wire				fright,
	input		wire				flash,
	input		wire				anim,			// skirt frame
	output	logic				hit,
	output	logic	[11:0]	rgb
	);

wire signed [10:0] col_s = $signed({2'b0, mx}) - $signed({3'b0, gx}) + 11'sd7;
wire signed [10:0] row_s = $signed({2'b0, my}) - $signed({3'b0, gy}) + 11'sd7;
wire				in_box = col_s >= 0 && col_s < 14 && row_s >= 0 && row_s < 14;
wire	[3:0]		c = col_s[3:0], r = row_s[3:0];

function automatic [13:0] body_row(input [3:0] rr, input fa);		// bit 13 = column 0
	case (rr)
		4'd0:  body_row = 14'b00000111100000;
		4'd1:  body_row = 14'b00011111111000;
		4'd2:  body_row = 14'b00111111111100;
		4'd3, 4'd4, 4'd5: body_row = 14'b01111111111110;
		4'd12: body_row = fa ? 14'b11011100111011 : 14'b11110111101111;
		4'd13: body_row = fa ? 14'b10001100110001 : 14'b01100011000110;
		default: body_row = 14'b11111111111111;
	endcase
endfunction

wire	[13:0]	brow = body_row(r, anim);
wire				body = in_box && brow[4'd13 - c];
wire				eyes_only = (st == 3'd3) || (st == 3'd4);
wire				scared = fright && !eyes_only;

// normal eyes: two 4 x 5 whites shifted toward the direction, 2 x 2 pupils at the leading edge
wire signed [4:0] ex = (dir == 2'd1) ? -5'sd1 : (dir == 2'd3) ? 5'sd1 : 5'sd0;
wire signed [4:0] ey = (dir == 2'd0) ? -5'sd1 : (dir == 2'd2) ? 5'sd1 : 5'sd0;
wire signed [4:0] cs = $signed({1'b0, c}), rs = $signed({1'b0, r});
wire signed [4:0] wy = rs - 5'sd3 - ey;					// row inside the white, 0..4
wire signed [4:0] wl = cs - 5'sd2 - ex, wr = cs - 5'sd8 - ex;	// column inside the left / right white, 0..3
wire				in_wy = wy >= 0 && wy <= 4;
wire				white_l = in_wy && wl >= 0 && wl <= 3;
wire				white_r = in_wy && wr >= 0 && wr <= 3;
wire signed [4:0] wc = white_l ? wl : wr;
logic				pupil;
always_comb
	case (dir)
		2'd3: pupil = (wc >= 2) && (wy >= 1 && wy <= 2);
		2'd1: pupil = (wc <= 1) && (wy >= 1 && wy <= 2);
		2'd0: pupil = (wc >= 1 && wc <= 2) && (wy <= 1);
		default: pupil = (wc >= 1 && wc <= 2) && (wy >= 3);
	endcase

// frightened face
wire				f_eye = (r == 4'd5 || r == 4'd6) && (c == 4'd4 || c == 4'd5 || c == 4'd8 || c == 4'd9);
wire				f_mouth = (c >= 4'd1 && c <= 4'd12) &&
								 ((r == 4'd9 && (c[1:0] == 2'd1 || c[1:0] == 2'd2)) ||
								  (r == 4'd10 && (c[1:0] == 2'd3 || c[1:0] == 2'd0)));

always_comb begin
	hit = 1'b0; rgb = 12'h000;
	if (in_box) begin
		if (scared) begin
			if (f_eye || f_mouth) begin hit = body; rgb = flash ? 12'hF00 : 12'hFCB; end
			else if (body) begin hit = 1'b1; rgb = flash ? 12'hFFF : 12'h22F; end
		end else if (white_l || white_r) begin
			hit = 1'b1; rgb = pupil ? 12'h22F : 12'hFFF;
		end else if (body && !eyes_only) begin
			hit = 1'b1; rgb = COLOR;
		end
	end
end

endmodule
