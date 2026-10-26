// The lab's screen: 320 x 240 (each pixel is 2 x 2 of the 640 x 480 scan)
//
// Top: the wave as a scope trace (x 32..287, y 16..112, one memory entry per column = the span from sample n
// to sample n + 1). Bottom: two spectrum panels of 128 bars, our FFT (x 16..143) and the IP (x 176..303),
// bars rising from y 228. Text rows: settings (0, 1), panel titles and times (15, 16), the IP warning
// (20, 21), the frequency axis (29). The memories answer one clock late, so they are addressed with the
// NEXT scan pixel (x + 1). Layers, back to front: grid, axes, bars, trace, text.
// Python twin: sim/lab_model.py (text_cells, render).
// ***********************************************
`default_nettype none

module lab_draw (
	input		wire				clk,
	input		wire	[31:0]	pxl_x,
	input		wire	[31:0]	pxl_y,
	// memory writes from the engine
	input		wire				sc_we,
	input		wire	[7:0]		sc_addr,
	input		wire	[13:0]	sc_d,				// {lo y, hi y}
	input		wire				bd_we,
	input		wire	[6:0]		bd_addr,
	input		wire	[6:0]		bd_d,
	input		wire				bi_we,
	input		wire	[6:0]		bi_addr,
	input		wire	[6:0]		bi_d,
	// what the frame was made with (published), and the live hold / sound
	input		wire	[2:0]		shape,
	input		wire				win,
	input		wire				lin,
	input		wire				ip_ok,
	input		wire	[9:0]		fq,
	input		wire				hold,
	input		wire				sound,
	// numbers as decimal digits (lab_digits)
	input		wire	[23:0]	hz_bcd,
	input		wire	[11:0]	bin_bcd,
	input		wire	[19:0]	dclk_bcd,
	input		wire	[23:0]	dus_bcd,
	input		wire	[19:0]	iclk_bcd,
	input		wire	[23:0]	ius_bcd,
	output	logic	[11:0]	rgb
	);

localparam [11:0] BLACK = 12'h000, WHITE = 12'hFFF, YELLOW = 12'hFF0, GREY = 12'hAAA, RED = 12'hF00;
localparam [11:0] GRID = 12'h333, AXIS = 12'h555, TRACE = 12'h0F0, BAR_D = 12'h0FF, BAR_I = 12'hF80;

wire				visible = pxl_x < 32'd640 && pxl_y < 32'd480;
wire	[8:0]		X = pxl_x[9:1];
wire	[7:0]		Y = pxl_y[8:1];
wire	[9:0]		nx = pxl_x[9:0] + 10'd1;
wire	[8:0]		nX = nx[9:1];

// ---- memories: written by the engine, read one scan pixel ahead
logic	[13:0]	scope_mem [0:255];
logic	[6:0]		bars_d [0:127];
logic	[6:0]		bars_i [0:127];
integer i;
initial begin
	for (i = 0; i < 256; i = i + 1) scope_mem[i] = 14'd0;
	for (i = 0; i < 128; i = i + 1) begin bars_d[i] = 7'd0; bars_i[i] = 7'd0; end
end

wire	[8:0]		sx = nX - 9'd32;
wire	[8:0]		dx = nX - 9'd16;
wire	[8:0]		ix = nX - 9'd176;
logic	[13:0]	sc_q;
logic	[6:0]		bd_q, bi_q;
always @(posedge clk) begin
	if (sc_we) scope_mem[sc_addr] <= sc_d;
	sc_q <= scope_mem[sx[7:0]];
end
always @(posedge clk) begin
	if (bd_we) bars_d[bd_addr] <= bd_d;
	bd_q <= bars_d[dx[6:0]];
end
always @(posedge clk) begin
	if (bi_we) bars_i[bi_addr] <= bi_d;
	bi_q <= bars_i[ix[6:0]];
end

// ---- text: 40 x 30 cells of 8 x 8, each row a 40-character string (column 0 in the top byte)
wire	[4:0]		trow = Y[7:3];
wire	[5:0]		tcol = X[8:3];

function automatic [7:0] dg(input [3:0] d);
	dg = {4'h3, d};
endfunction

// digit i of a BCD number; a leading zero is a space, except at digit lo and below
function automatic [7:0] numch(input [23:0] v, input integer di, input integer lo);
	numch = (di > lo && (v >> (4 * di)) == 24'd0) ? 8'h20 : {4'h3, v[4 * di +: 4]};
endfunction

function automatic [63:0] shape_s(input [2:0] s);
	case (s)
		3'd0:    shape_s = "SINE    ";
		3'd1:    shape_s = "SQUARE  ";
		3'd2:    shape_s = "TRIANGLE";
		3'd3:    shape_s = "SAW     ";
		3'd4:    shape_s = "SPIKES  ";
		3'd5:    shape_s = "NOISE   ";
		default: shape_s = "        ";
	endcase
endfunction

function automatic [23:0] frac3(input [2:0] f);		// eighths of a bin as .000 .. .875
	case (f)
		3'd0:    frac3 = "000";
		3'd1:    frac3 = "125";
		3'd2:    frac3 = "250";
		3'd3:    frac3 = "375";
		3'd4:    frac3 = "500";
		3'd5:    frac3 = "625";
		3'd6:    frac3 = "750";
		default: frac3 = "875";
	endcase
endfunction

// one panel's time: " ccccc CLK uuuu.uuUS" (20 characters)
function automatic [159:0] half(input [19:0] c, input [23:0] u);
	half = {" ", numch({4'd0, c}, 4, 0), numch({4'd0, c}, 3, 0), numch({4'd0, c}, 2, 0), numch({4'd0, c}, 1, 0),
		numch({4'd0, c}, 0, 0), " CLK ", numch(u, 5, 2), numch(u, 4, 2), numch(u, 3, 2), numch(u, 2, 2), ".",
		dg(u[7:4]), dg(u[3:0]), "US"};
endfunction

localparam [159:0] AXIS_TXT = {"  0     6.4K 12.8K  "};
localparam [319:0] BLANK = {40{" "}};

logic	[319:0]	rs;
always_comb
	case (trow)
		5'd0:  rs = {shape_s(shape), " ", numch(hz_bcd, 5, 1), numch(hz_bcd, 4, 1), numch(hz_bcd, 3, 1),
		             numch(hz_bcd, 2, 1), numch(hz_bcd, 1, 1), ".", dg(hz_bcd[3:0]), " HZ  BIN ",
		             numch({12'd0, bin_bcd}, 2, 0), numch({12'd0, bin_bcd}, 1, 0), numch({12'd0, bin_bcd}, 0, 0),
		             ".", frac3(fq[2:0]), "    ", hold ? "HOLD" : "    "};
		5'd1:  rs = {win ? "WIN HANN" : "WIN RECT", "  ", lin ? "LINEAR  " : "10DB/DIV", "  ",
		             sound ? "SOUND ON " : "SOUND OFF", " 1.25MS/DIV"};
		5'd15: rs = {"  OUR RTL FFT         ALTERA FFT IP     "};
		5'd16: rs = {half(dclk_bcd, dus_bcd), half(iclk_bcd, ius_bcd)};
		5'd20: rs = ip_ok ? BLANK : {{21{" "}}, "IP IS NOT RUNNING  "};
		5'd21: rs = ip_ok ? BLANK : {{21{" "}}, "(EVALUATION TIME?) "};
		5'd29: rs = {AXIS_TXT, AXIS_TXT};
		default: rs = BLANK;
	endcase

wire	[5:0]		tci = 6'd39 - tcol;
wire	[7:0]		ch = (tcol < 6'd40) ? rs[{tci, 3'b000} +: 8] : 8'h20;
wire	[7:0]		fbits;
font8x8 font(.ch(ch), .row(Y[2:0]), .bits(fbits));

wire	[5:0]		hc = (tcol >= 6'd20) ? tcol - 6'd20 : tcol;
logic	[11:0]	tcolor;
always_comb
	case (trow)
		5'd0:         tcolor = (tcol < 6'd8) ? WHITE : (tcol < 6'd16) ? YELLOW : (tcol < 6'd25) ? GREY :
		                       (tcol < 6'd32) ? YELLOW : RED;
		5'd15:        tcolor = WHITE;
		5'd16:        tcolor = (hc < 6'd7) ? YELLOW : (hc < 6'd11) ? GREY : (hc < 6'd18) ? YELLOW : GREY;
		5'd20, 5'd21: tcolor = RED;
		default:      tcolor = GREY;
	endcase

// ---- graphics
// scope grid: dotted lines every 32 columns and at y 16, 40, 88, 112; the zero line at y 64
wire				s_cols = X >= 9'd32 && X <= 9'd288;
wire				g_vert = Y >= 8'd16 && Y <= 8'd112 && !Y[0] && s_cols && X[4:0] == 5'd0;
wire				g_horz = s_cols && !X[0] && (Y == 8'd16 || Y == 8'd40 || Y == 8'd88 || Y == 8'd112);
wire				g_zero = s_cols && !X[0] && Y == 8'd64;

// spectrum panels: dotted lines every 10 dB (every 18 rows in linear) and every 32 bins, the axis at y 228
wire				pin0 = X >= 9'd16 && X <= 9'd143;
wire				pin1 = X >= 9'd176 && X <= 9'd303;
logic				gy;
always_comb
	if (lin)
		case (Y)
			8'd138, 8'd156, 8'd174, 8'd192, 8'd210: gy = 1'b1;
			default: gy = 1'b0;
		endcase
	else
		case (Y)
			8'd138, 8'd148, 8'd158, 8'd168, 8'd178, 8'd188, 8'd198, 8'd208, 8'd218: gy = 1'b1;
			default: gy = 1'b0;
		endcase
wire				in_bars = Y >= 8'd138 && Y <= 8'd227;
wire				p_horz = (pin0 || pin1) && !X[0] && gy;
wire				p_axis = (pin0 || pin1) && Y == 8'd228;
wire				p_vert = in_bars && !Y[0] && (X == 9'd48 || X == 9'd80 || X == 9'd112 ||
							 X == 9'd208 || X == 9'd240 || X == 9'd272);

wire				bar_d = in_bars && pin0 && ({1'b0, Y} + {2'b0, bd_q} >= 9'd228);
wire				bar_i = in_bars && pin1 && ip_ok && ({1'b0, Y} + {2'b0, bi_q} >= 9'd228);

wire	[6:0]		lo = sc_q[13:7], hi = sc_q[6:0];
wire				trace = X >= 9'd32 && X <= 9'd287 && Y >= 8'd16 && Y <= 8'd112 &&
							{1'b0, lo} <= Y && Y <= {1'b0, hi};

logic	[11:0]	c;
always_comb begin
	c = BLACK;
	if (g_vert || g_horz) c = GRID;
	if (g_zero) c = AXIS;
	if (p_horz || p_vert) c = GRID;
	if (p_axis) c = AXIS;
	if (bar_d) c = BAR_D;
	if (bar_i) c = BAR_I;
	if (trace) c = TRACE;
	if (fbits[X[2:0]]) c = tcolor;
	rgb = visible ? c : BLACK;
end

endmodule

`default_nettype wire
