// Pac-Man screen: 320 x 240 (each pixel is 2 x 2 of the 640 x 480 scan), maze in the middle 224 columns,
// score panel left, lives panel right.
//
// Screen pixel (lx, ly) -> maze pixel (mx, my) = (lx - 48, ly + 4): the maze is 248 rows, the screen 240, so
// 4 rows of the outer wall are cut at the top and the bottom. Memories (wall picture ROM, dot RAM) answer one
// clock late, so they are addressed with the NEXT scan pixel (x + 1). Layers, front to back:
// ghosts, Pac-Man, text, dots, walls.
// ***********************************************
`default_nettype none

module pac_draw #(parameter WALLS = "assets/walls.bin") (
	input		wire				clk,
	input		wire	[31:0]	pxl_x,
	input		wire	[31:0]	pxl_y,
	output	logic	[9:0]		rb_addr,		// dot RAM {row, col}
	input		wire	[1:0]		rb_q,
	input		wire	[7:0]		pac_x, pac_y,
	input		wire	[1:0]		pac_dir,
	input		wire	[1:0]		pac_mouth,
	input		wire	[3:0]		death_phase,
	input		wire				dying_anim,
	input		wire				pac_show,
	input		wire	[31:0]	g_x, g_y,
	input		wire	[7:0]		g_dir,
	input		wire	[11:0]	g_state,
	input		wire	[3:0]		g_fright,
	input		wire				ghosts_show,
	input		wire				fright_flash,
	input		wire	[23:0]	score, hiscore,
	input		wire	[3:0]		lives,
	input		wire	[7:0]		level_bcd,
	input		wire				show_ready, show_gameover, show_push, maze_white,
	input		wire	[7:0]		frame,
	output	logic	[11:0]	rgb
	);

wire				visible = pxl_x < 32'd640 && pxl_y < 32'd480;
wire	[8:0]		lx = pxl_x[9:1];
wire	[7:0]		ly = pxl_y[8:1];
wire	[9:0]		nx = pxl_x[9:0] + 10'd1;
wire	[8:0]		nmx = nx[9:1] - 9'd48;
wire	[8:0]		my = {1'b0, ly} + 9'd4;

// ---- memories, addressed one scan pixel ahead
logic	[1:0]		walls [0:61439];
initial $readmemb(WALLS, walls);		// binary file: 2-bit entries
logic	[1:0]		wq;
always @(posedge clk) wq <= walls[{ly, nmx[7:0]}];
assign rb_addr = {my[7:3], nmx[7:3]};

// ---- the current pixel
wire	[8:0]		mx = lx - 9'd48;
wire				in_maze = visible && lx >= 9'd48 && lx < 9'd272;
wire	[2:0]		u = mx[2:0], v = my[2:0];
wire signed [4:0] u2 = $signed({1'b0, u, 1'b0}) - 5'sd7, v2 = $signed({1'b0, v, 1'b0}) - 5'sd7;	// -7..7, odd
wire				dot_px = (rb_q == 2'd1) && (u == 3'd3 || u == 3'd4) && (v == 3'd3 || v == 3'd4);
wire				pow_px = (rb_q == 2'd2) && (u2 * u2 + v2 * v2 <= 50) && (frame[3] || show_ready);

// ---- Pac-Man: a 13-pixel circle with a wedge cut out; dying = the wedge opens from the top to all of him
wire signed [10:0] pdx = (($signed({2'b0, mx}) - $signed({3'b0, pac_x})) <<< 1) + 11'sd1;
wire signed [10:0] pdy = (($signed({2'b0, my}) - $signed({3'b0, pac_y})) <<< 1) + 11'sd1;
wire				p_box = pdx >= -11'sd13 && pdx <= 11'sd13 && pdy >= -11'sd13 && pdy <= 11'sd13;
wire signed [5:0] pdx6 = pdx[5:0], pdy6 = pdy[5:0];
wire				p_disc = (pdx6 * pdx6 + pdy6 * pdy6) <= 169;
wire	[1:0]		pdir = dying_anim ? 2'd0 : pac_dir;
logic signed [5:0] ma, mb;					// along the mouth / across it
always_comb
	case (pdir)
		2'd3: begin ma =  pdx6; mb = pdy6; end
		2'd1: begin ma = -pdx6; mb = pdy6; end
		2'd0: begin ma = -pdy6; mb = pdx6; end
		default: begin ma = pdy6; mb = pdx6; end
	endcase
logic signed [5:0] mc, ms_;			// cos, sin of the half-opening x 16
always_comb
	if (dying_anim)
		case (death_phase)
			4'd0:  begin mc = 6'sd15;  ms_ = 6'sd4;  end
			4'd1:  begin mc = 6'sd14;  ms_ = 6'sd8;  end
			4'd2:  begin mc = 6'sd11;  ms_ = 6'sd11; end
			4'd3:  begin mc = 6'sd8;   ms_ = 6'sd14; end
			4'd4:  begin mc = 6'sd4;   ms_ = 6'sd15; end
			4'd5:  begin mc = 6'sd0;   ms_ = 6'sd16; end
			4'd6:  begin mc = -6'sd4;  ms_ = 6'sd15; end
			4'd7:  begin mc = -6'sd8;  ms_ = 6'sd14; end
			4'd8:  begin mc = -6'sd11; ms_ = 6'sd11; end
			4'd9:  begin mc = -6'sd14; ms_ = 6'sd8;  end
			4'd10: begin mc = -6'sd15; ms_ = 6'sd4;  end
			default: begin mc = -6'sd16; ms_ = 6'sd0; end
		endcase
	else
		case (pac_mouth)
			2'd0:    begin mc = 6'sd16; ms_ = 6'sd0;  end		// closed
			2'd1:    begin mc = 6'sd15; ms_ = 6'sd7;  end		// 25 degrees each side
			default: begin mc = 6'sd11; ms_ = 6'sd11; end		// 45
		endcase
wire signed [5:0] mb_abs = (mb < 0) ? -mb : mb;
// the pixel's angle from the mouth axis is below the half-opening <=> a*sin > |b|*cos
wire signed [11:0] m_lhs = ma * ms_, m_rhs = mb_abs * mc;	// 12 bits: the products reach 13 x 16
wire				in_mouth = m_lhs > m_rhs;
wire				pac_px = in_maze && pac_show && p_box && p_disc && !in_mouth;

// ---- ghosts (Blinky in front)
wire	[3:0]		gh;
wire	[11:0]	gc [1:4];
genvar gi;
generate
	for (gi = 1; gi <= 4; gi = gi + 1) begin : ghosts
		ghost_sprite #(.COLOR(gi == 1 ? 12'hF00 : gi == 2 ? 12'hFBF : gi == 3 ? 12'h0FF : 12'hFB5)) g(
			.mx(mx), .my(my), .gx(g_x[8*gi-8 +: 8]), .gy(g_y[8*gi-8 +: 8]), .dir(g_dir[2*gi-2 +: 2]),
			.st(g_state[3*gi-3 +: 3]), .fright(g_fright[gi-1]), .flash(fright_flash), .anim(frame[3]),
			.hit(gh[gi-1]), .rgb(gc[gi]));
	end
endgenerate

// ---- text: side panels on the screen's 8 x 8 grid, messages on the maze's tile grid (row 17)
wire	[5:0]		scol = lx[8:3];
wire	[4:0]		srow = ly[7:3];
wire	[4:0]		tcol = mx[7:3], trow = my[7:3];
logic	[7:0]		ch;
logic	[11:0]	tcolor;

function automatic [7:0] str6(input [47:0] s, input [2:0] i);
	str6 = s[8*(5-i) +: 8];
endfunction
function automatic [7:0] str10(input [79:0] s, input [3:0] i);
	str10 = s[8*(9-i) +: 8];
endfunction
// digit i (0 = leftmost) of a 6-digit BCD number, leading zeros blank (the last two always shown, like the arcade)
function automatic [7:0] num6(input [23:0] n, input [2:0] i);
	logic [3:0] d;
	logic lead;
	begin
		d = n[4*(5-i) +: 4];
		case (i)
			3'd0: lead = 1'b1;
			3'd1: lead = n[23:20] == 0;
			3'd2: lead = n[23:16] == 0;
			3'd3: lead = n[23:12] == 0;
			default: lead = 1'b0;
		endcase
		num6 = (lead && d == 0) ? 8'h20 : 8'h30 + d;
	end
endfunction

always_comb begin
	ch = 8'h20; tcolor = 12'hFFF;
	if (in_maze) begin
		if (trow == 5'd17) begin
			if (show_ready && tcol >= 5'd11 && tcol <= 5'd16) begin
				ch = str6("READY!", tcol - 5'd11); tcolor = 12'hFF0;
			end else if (show_gameover && tcol >= 5'd9 && tcol <= 5'd18) begin
				ch = str10("GAME  OVER", tcol - 5'd9); tcolor = 12'hF00;
			end else if (show_push && tcol >= 5'd9 && tcol <= 5'd18) begin
				ch = str10("PUSH START", tcol - 5'd9); tcolor = 12'h0FF;
			end
		end
	end else if (scol < 6'd6) begin
		case (srow)
			5'd1: ch = str6("  1UP ", scol[2:0]);
			5'd2: ch = num6(score, scol[2:0]);
			5'd5: ch = str6(" HIGH ", scol[2:0]);
			5'd6: ch = num6(hiscore, scol[2:0]);
			5'd9: ch = str6("LEVEL ", scol[2:0]);
			5'd10: ch = (scol == 6'd3) ? ((level_bcd[7:4] == 0) ? 8'h20 : 8'h30 + level_bcd[7:4]) :
			            (scol == 6'd4) ? 8'h30 + level_bcd[3:0] : 8'h20;
			default: ;
		endcase
	end else if (scol >= 6'd34 && scol < 6'd40) begin
		case (srow)
			5'd1: ch = str6("LIVES ", scol - 6'd34);
			5'd20: begin ch = str6(" PAC  ", scol - 6'd34); tcolor = 12'hFF0; end
			5'd21: begin ch = str6(" MAN  ", scol - 6'd34); tcolor = 12'hFF0; end
			default: ;
		endcase
	end
end

wire	[2:0]		grow = in_maze ? my[2:0] : ly[2:0];
wire	[2:0]		gcol = in_maze ? mx[2:0] : lx[2:0];
wire	[7:0]		fbits;
font8x8 font(.ch(ch), .row(grow), .bits(fbits));
wire				text_px = visible && fbits[gcol];

// spare lives: small Pac-Men facing left on panel row 3
wire signed [4:0] iu = $signed({1'b0, lx[2:0], 1'b0}) - 5'sd7, iv = $signed({1'b0, ly[2:0], 1'b0}) - 5'sd7;
wire				icon_px = visible && srow == 5'd3 && scol >= 6'd34 && lives > 4'd1 && (scol - 6'd34) < ({2'b0, lives} - 6'd1) &&
							 scol < 6'd40 && (iu * iu + iv * iv <= 49) && !(iu < 0 && (iv < 0 ? -iv : iv) <= -iu);

// ---- compose
always_comb begin
	rgb = 12'h000;
	if (!visible) rgb = 12'h000;
	else if (in_maze && ghosts_show && gh[0]) rgb = gc[1];
	else if (in_maze && ghosts_show && gh[1]) rgb = gc[2];
	else if (in_maze && ghosts_show && gh[2]) rgb = gc[3];
	else if (in_maze && ghosts_show && gh[3]) rgb = gc[4];
	else if (pac_px) rgb = 12'hFF0;
	else if (text_px) rgb = tcolor;
	else if (icon_px) rgb = 12'hFF0;
	else if (in_maze && (dot_px || pow_px)) rgb = 12'hFCB;
	else if (in_maze && wq == 2'd1) rgb = maze_white ? 12'hFFF : 12'h22D;
	else if (in_maze && wq == 2'd2) rgb = 12'hFBF;
end

endmodule
