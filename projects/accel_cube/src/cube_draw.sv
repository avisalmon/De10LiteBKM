// Per-pixel drawing of the accelerometer cube: a 4-stage pipeline clocked with the pixels, no frame buffer.
// It looks 4 pixels ahead along the scan (so the registered colour is the one of the pixel the screen asks
// for in the same clock), multiplies the coordinates into the edge functions of the cube's faces and of the
// widget's line segments, and picks the colour by priority: cube face (edge-darkened) or sky gradient,
// separator, widget (segments, then the X Y Z labels), text panel (glyph, bars, ticks). Mirrors pixel() in
// assets/model.py pixel for pixel.
// Layout: x < 384 the cube; 384..385 the separator; x >= 386: y < 224 the text panel (16 columns of 16 px),
// y >= 224 the vector widget.
// ***********************************************
`default_nettype none

module cube_draw (
	input		wire						clk,				// 25 MHz pixel clock
	input		wire						rst,
	input		wire	[31:0]			pxl_x,
	input		wire	[31:0]			pxl_y,
	// the frame, from cube_math (stable during the visible lines)
	input		wire	[2:0]				slot_valid,
	input		wire	[2:0][11:0]		slot_rgb,
	input		wire	[11:0][15:0]	e_dx,
	input		wire	[11:0][15:0]	e_dy,
	input		wire	[11:0][31:0]	e_c,
	input		wire	[11:0][23:0]	e_t,
	input		wire	[7:0]				sg_valid,
	input		wire	[7:0]				sg_dash,
	input		wire	[7:0][11:0]		sg_rgb,
	input		wire	[7:0][17:0]		sg_dx,
	input		wire	[7:0][17:0]		sg_dy,
	input		wire	[7:0][31:0]		sg_c,
	input		wire	[7:0][23:0]		sg_t,
	input		wire	[7:0][9:0]		sg_xmin,
	input		wire	[7:0][9:0]		sg_xmax,
	input		wire	[7:0][9:0]		sg_ymin,
	input		wire	[7:0][9:0]		sg_ymax,
	input		wire	[6:0][15:0]		bcd4,
	input		wire	[2:0][19:0]		bcd5,
	input		wire	[4:0]				neg,
	input		wire	[2:0][9:0]		bar_len,
	input		wire	[2:0]				bar_neg,
	input		wire	[7:0]				devid,
	input		wire	[1:0]				mode,				// 0 live, 1 live calibrated, 2 test
	input		wire	[2:0]				test_n,
	output	logic	[11:0]			rgb,				// the colour of (pxl_x, pxl_y), registered
	output	wire	[8*114-1:0]		report			// the USB report line (from cube_text)
	);

// ---- layout (model.py: screen layout). Keep in step with the model.
localparam [9:0] PANEL_X = 10'd384, BAR_X = 10'd512;
localparam [8:0] WID_Y = 9'd224;
localparam [11:0] PANEL_BG = 12'h112, SEP_COLOR = 12'h445, TICK_COLOR = 12'h999, CENTER_COLOR = 12'hAAA;
localparam [11:0] BAR0 = 12'hC44, BAR1 = 12'h4C4, BAR2 = 12'h44C;
localparam [11:0] AXIS0 = 12'hF44, AXIS1 = 12'h4F4, AXIS2 = 12'h66F;
localparam [9:0] LB0_X = 10'd585, LB0_Y = 10'd322;		// the X Y Z labels of the widget (px)
localparam [9:0] LB1_X = 10'd460, LB1_Y = 10'd307;
localparam [9:0] LB2_X = 10'd516, LB2_Y = 10'd272;

// ---- stage 0: the pixel 4 clocks ahead. The column holds 639 for 161 clocks in the horizontal blanking
// and jumps to 0 together with the next row; the row holds 479 through the vertical blanking.
logic	[7:0]		hold_cnt;								// clocks spent at column 639 so far
wire	[9:0]		px = pxl_x[9:0];
wire	[8:0]		py = pxl_y[8:0];
wire	[8:0]		hp = {1'b0, hold_cnt} + 9'd4;
wire				wrap = (px == 10'd639) && (hp > 9'd160);
wire	[10:0]	px4 = {1'b0, px} + 11'd4;
wire	[8:0]		hpw = hp - 9'd161;
wire	[9:0]		nx = (px == 10'd639) ? (wrap ? {1'b0, hpw} : 10'd639) : ((px4 > 11'd639) ? 10'd639 : px4[9:0]);
wire	[8:0]		ny = wrap ? ((py == 9'd479) ? 9'd0 : py + 9'd1) : py;
logic	[9:0]		x0, x1;
logic	[8:0]		y0, y1;

always_ff @(posedge clk) begin
	if (rst) begin
		hold_cnt <= 8'd0;
		x0 <= 10'd0;
		y0 <= 9'd0;
	end
	else begin
		hold_cnt <= (px == 10'd639) ? hold_cnt + 8'd1 : 8'd0;
		x0 <= nx;
		y0 <= ny;
	end
end

// ---- stage 1: the products of the edge functions, and the text character under the pixel
logic	signed	[26:0]	fxd [0:11];						// x * dy and y * dx of the 12 face edges
logic	signed	[26:0]	fyd [0:11];
logic	signed	[28:0]	sxd [0:7];						// the same for the 8 widget segments
logic	signed	[28:0]	syd [0:7];
wire	[5:0]		tcol0 = x0[9:4] - 6'd24;				// text column, (x - 384) / 16
wire	[7:0]		ch0;
wire	[11:0]	tcol_rgb0;
logic	[7:0]		ch1;
logic	[11:0]	tcol_rgb1;
integer i, j;

cube_text text (
	.row(y0[7:4]), .col(tcol0[3:0]), .bcd4(bcd4), .bcd5(bcd5), .neg(neg), .devid(devid), .mode(mode),
	.test_n(test_n), .ch(ch0), .color(tcol_rgb0), .report(report));

always_ff @(posedge clk) begin
	for (i = 0; i < 12; i = i + 1) begin
		fxd[i] <= $signed({1'b0, x0}) * $signed(e_dy[i]);
		fyd[i] <= $signed({1'b0, y0}) * $signed(e_dx[i]);
	end
	for (j = 0; j < 8; j = j + 1) begin
		sxd[j] <= $signed({1'b0, x0}) * $signed(sg_dy[j]);
		syd[j] <= $signed({1'b0, y0}) * $signed(sg_dx[j]);
	end
	x1 <= x0;
	y1 <= y0;
	ch1 <= ch0;
	tcol_rgb1 <= tcol_rgb0;
end

// ---- stage 2: inside / on-the-edge flags of every face edge, segment hits, glyph dots, bars and ticks
wire	[11:0]	f_in_c, f_ln_c;							// E >= 0; E <= T (the darker edge line)
wire	[7:0]		s_hit_c;
genvar gi;
generate
	for (gi = 0; gi < 12; gi = gi + 1) begin : face
		wire signed [27:0] d = fxd[gi] - fyd[gi];
		wire signed [32:0] e = $signed({d, 4'b0}) + $signed({e_c[gi][31], e_c[gi]});
		assign f_in_c[gi] = !e[32];
		assign f_ln_c[gi] = (e <= $signed({9'b0, e_t[gi]}));
	end
	for (gi = 0; gi < 8; gi = gi + 1) begin : seg
		wire signed [29:0] d = sxd[gi] - syd[gi];
		wire signed [34:0] e = $signed({d, 4'b0}) + $signed({sg_c[gi][31], sg_c[gi]});
		wire signed [34:0] t = $signed({11'b0, sg_t[gi]});
		wire inbox = (x1 >= sg_xmin[gi]) && (x1 <= sg_xmax[gi]) &&
		             ({1'b0, y1} >= sg_ymin[gi]) && ({1'b0, y1} <= sg_ymax[gi]);
		assign s_hit_c[gi] = sg_valid[gi] && inbox && (e <= t) && (e >= -t) && (!sg_dash[gi] || (x1[2] ^ y1[2]));
	end
endgenerate

// the text glyph (8x8 font at 2x: font row y[3:1], font column x[3:1]) and the widget's X Y Z labels (1x)
wire	[7:0]		gbits, lb0, lb1, lb2;
wire	[9:0]		l0x = x1 - LB0_X, l1x = x1 - LB1_X, l2x = x1 - LB2_X;
wire	[9:0]		l0y = {1'b0, y1} - LB0_Y, l1y = {1'b0, y1} - LB1_Y, l2y = {1'b0, y1} - LB2_Y;
font8x8 glyph (.ch(ch1), .row(y1[3:1]), .bits(gbits));
font8x8 labx (.ch("X"), .row(l0y[2:0]), .bits(lb0));
font8x8 laby (.ch("Y"), .row(l1y[2:0]), .bits(lb1));
font8x8 labz (.ch("Z"), .row(l2y[2:0]), .bits(lb2));
wire				glyph_c = gbits[x1[3:1]];
wire	[2:0]		lab_c = {(l2x < 10'd8) && (l2y < 10'd8) && lb2[l2x[2:0]],
                      (l1x < 10'd8) && (l1y < 10'd8) && lb1[l1x[2:0]],
                      (l0x < 10'd8) && (l0y < 10'd8) && lb0[l0x[2:0]]};

// the bars of rows 3, 5, 7 (x, y, z), their end ticks (+-1 g) and the centre line
wire	[3:0]		trow = y1[7:4];
wire	[3:0]		yy = y1[3:0];
wire				barrow = (trow == 4'd3) || (trow == 4'd5) || (trow == 4'd7);
wire	[1:0]		bi = trow[2:1] - 2'd1;
wire	[9:0]		blen = bar_len[bi];
wire				bneg = bar_neg[bi];
wire	[10:0]	xend = {1'b0, x1} + {1'b0, blen};
wire				bar_c = barrow && (yy >= 4'd4) && (yy < 4'd12) &&
                     (bneg ? ((x1 < BAR_X) && (xend >= {1'b0, BAR_X}))
                           : ((x1 >= BAR_X) && ({1'b0, x1} < {1'b0, BAR_X} + {1'b0, blen})));
wire				mid = barrow && (yy >= 4'd2) && (yy < 4'd14);
wire				tick_c = mid && ((x1 == BAR_X - 10'd57) || (x1 == BAR_X - 10'd56) ||
                              (x1 == BAR_X + 10'd55) || (x1 == BAR_X + 10'd56));
wire				cen_c = mid && ((x1 == BAR_X - 10'd1) || (x1 == BAR_X));

logic	[11:0]	f_in, f_ln;
logic	[7:0]		s_hit;
logic	[2:0]		lab2;
logic				glyph2, bar2, tick2, cen2, cube2, sep2, wid2;
logic	[11:0]	grad2, bcol2, tcol_rgb2;

always_ff @(posedge clk) begin
	f_in <= f_in_c;
	f_ln <= f_ln_c;
	s_hit <= s_hit_c;
	lab2 <= lab_c;
	glyph2 <= glyph_c;
	bar2 <= bar_c;
	tick2 <= tick_c;
	cen2 <= cen_c;
	cube2 <= (x1 < PANEL_X);
	sep2 <= (x1[9:1] == 9'd192);								// 384, 385
	wid2 <= (y1 >= WID_Y);
	grad2 <= {4'h0, 3'b000, y1[8], 1'b0, 1'b1, y1[8], y1[7]};		// four soft sky bands
	bcol2 <= (bi == 2'd0) ? BAR0 : (bi == 2'd1) ? BAR1 : BAR2;
	tcol_rgb2 <= tcol_rgb1;
end

// ---- stage 3: the colour, by priority
function automatic [11:0] dim(input [11:0] c);		// the edge line: every channel / 4
	dim = {2'b00, c[11:10], 2'b00, c[7:6], 2'b00, c[3:2]};
endfunction
wire	[11:0]	c0 = slot_rgb[0], c1 = slot_rgb[1], c2 = slot_rgb[2];
wire	[2:0]		hit = {slot_valid[2] && (&f_in[11:8]), slot_valid[1] && (&f_in[7:4]), slot_valid[0] && (&f_in[3:0])};
wire	[2:0]		ln = {|f_ln[11:8], |f_ln[7:4], |f_ln[3:0]};

always_ff @(posedge clk) begin
	if (rst)
		rgb <= 12'h000;
	else if (cube2) begin
		if (hit[0])      rgb <= ln[0] ? dim(c0) : c0;
		else if (hit[1]) rgb <= ln[1] ? dim(c1) : c1;
		else if (hit[2]) rgb <= ln[2] ? dim(c2) : c2;
		else             rgb <= grad2;
	end
	else if (sep2)
		rgb <= SEP_COLOR;
	else if (wid2) begin
		if (s_hit[0])      rgb <= sg_rgb[0];
		else if (s_hit[1]) rgb <= sg_rgb[1];
		else if (s_hit[2]) rgb <= sg_rgb[2];
		else if (s_hit[3]) rgb <= sg_rgb[3];
		else if (s_hit[4]) rgb <= sg_rgb[4];
		else if (s_hit[5]) rgb <= sg_rgb[5];
		else if (s_hit[6]) rgb <= sg_rgb[6];
		else if (s_hit[7]) rgb <= sg_rgb[7];
		else if (lab2[0])  rgb <= AXIS0;
		else if (lab2[1])  rgb <= AXIS1;
		else if (lab2[2])  rgb <= AXIS2;
		else               rgb <= PANEL_BG;
	end
	else
		rgb <= glyph2 ? tcol_rgb2 : cen2 ? CENTER_COLOR : tick2 ? TICK_COLOR : bar2 ? bcol2 : PANEL_BG;
end

endmodule

`default_nettype wire
