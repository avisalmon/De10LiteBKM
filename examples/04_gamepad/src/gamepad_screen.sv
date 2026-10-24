// Example 04 screen: every control, the raw ADC readings, the wheel bar (from the hello-world screen)
//
// 640x480. Title in 8x8 glyphs scaled x4 (32x32 cells); body scaled x2
// (16x16 cells, 40 columns x 30 rows). Pure combinational from the pixel
// position, like the arcade template's Draw_* modules. All values are latched once per frame (vsync) so a
// number never changes half way down the screen (the hello world's digits could tear).
// ***********************************************

module gamepad_screen (
	input					clk,
	input					vsync,
	input		[31:0]	pxl_x,
	input		[31:0]	pxl_y,
	input		[11:0]	a0,
	input		[11:0]	a1,
	input		[11:0]	a2,
	input		[11:0]	a3,
	input		[11:0]	a4,
	input		[11:0]	wheel,
	input		[7:0]		btn,		// {Left, Right, Up, Down, Start, Select, B, A}
	input		[1:0]		key_pressed,	// 1 = KEY pressed
	input		[9:0]		SW,
	input		[15:0]	frame,
	output	[3:0]		Red,
	output	[3:0]		Green,
	output	[3:0]		Blue
	);

localparam [11:0] BG        = 12'h113;
localparam [11:0] TITLE     = 12'hFC0;
localparam [11:0] TEXT      = 12'hFFF;
localparam [11:0] VALUE     = 12'h8EF;
localparam [11:0] BOX_IDLE  = 12'h446;
localparam [11:0] BOX_PRESS = 12'h0D2;
localparam [11:0] TRACK     = 12'h334;
localparam [11:0] BAR       = 12'h0CF;

localparam [127:0] TITLE_STR = "04 GAME PAD     ";	// 16 chars at title columns 2..17

// Body text, exactly 40 characters per line
function automatic [319:0] body_line(input [4:0] r);
	case (r)
		5'd4:    body_line = "  CONTROLS, RAW ADC VALUES, THE WHEEL   ";
		5'd6:    body_line = "  GAME PAD (BOX TURNS GREEN WHEN HELD): ";
		5'd8:    body_line = "     UP   DOWN  LEFT RIGHT    KEY0      ";
		5'd10:   body_line = "     A     B    SEL  START    KEY1      ";
		5'd13:   body_line = "  ADC RAW VALUES (12 BIT):              ";
		5'd15:   body_line = "   A0 LEFT/RIGHT  0x                    ";
		5'd16:   body_line = "   A1 UP/DOWN     0x                    ";
		5'd17:   body_line = "   A2 SEL/START   0x                    ";
		5'd18:   body_line = "   A3 BUTTON A    0x                    ";
		5'd19:   body_line = "   A4 BUTTON B    0x                    ";
		5'd20:   body_line = "   A5 WHEEL       0x                    ";
		5'd24:   body_line = "  SWITCHES:                             ";
		5'd26:   body_line = "  FRAME: 0x                             ";
		5'd28:   body_line = "  B BEEPS. EVERY CHANGE GOES TO THE PC. ";
		default: body_line = {40{8'h20}};
	endcase
endfunction

function automatic [7:0] hex_char(input [3:0] n);
	hex_char = (n < 10) ? 8'h30 + n : 8'h37 + n;	// '0'..'9', 'A'..'F'
endfunction

logic	[9:0]		x;
logic	[8:0]		y;
logic				in_title;
logic	[4:0]		tcol;
logic	[7:0]		tch;
logic	[2:0]		trow;
logic	[7:0]		tbits;
logic	[5:0]		bcol;
logic	[4:0]		brow;
logic	[7:0]		bch;
logic	[319:0]	line;
logic	[11:0]	val;
logic	[7:0]		bbits;
logic				in_box;
logic				pressed;
logic				is_value;
logic	[11:0]	rgb;

// ---- values latched once per frame, while vsync is active (nothing is drawn then)
reg	[11:0]	A0, A1, A2, A3, A4, WH;
reg	[7:0]		BT;
reg	[1:0]		KP;
reg	[9:0]		SWL;
reg	[15:0]	FR;
always @(posedge clk) if (!vsync) begin
	A0 <= a0; A1 <= a1; A2 <= a2; A3 <= a3; A4 <= a4; WH <= wheel; BT <= btn; KP <= key_pressed; SWL <= SW; FR <= frame;
end
wire	A = BT[0], B = BT[1], Select = BT[2], Start = BT[3], Down = BT[4], Up = BT[5], Right = BT[6], Left = BT[7];

assign x = pxl_x[9:0];
assign y = pxl_y[8:0];

// Title
assign in_title = (y >= 16) && (y < 48);
assign tcol = x[9:5];
assign trow = (y - 9'd16) >> 2;
assign tch  = (tcol >= 2 && tcol <= 17) ? TITLE_STR[(17 - tcol)*8 +: 8] : 8'h20;

font8x8 title_font(.ch(tch), .row(trow), .bits(tbits));

// Body
assign bcol = x[9:4];
assign brow = y[8:4];
assign line = body_line(brow);

always_comb begin
	bch = (bcol < 40) ? line[(39 - bcol)*8 +: 8] : 8'h20;
	is_value = 0;

	// raw ADC values: 3 hex digits at columns 20..22 of rows 15..20
	case (brow)
		5'd15:   val = A0;
		5'd16:   val = A1;
		5'd17:   val = A2;
		5'd18:   val = A3;
		5'd19:   val = A4;
		default: val = WH;
	endcase
	if (brow >= 15 && brow <= 20 && bcol >= 20 && bcol <= 22) begin
		bch = hex_char(val[(22 - bcol)*4 +: 4]);
		is_value = 1;
	end

	// switches SW9..SW0 at columns 12..21 of row 24
	if (brow == 24 && bcol >= 12 && bcol <= 21) begin
		bch = SWL[21 - bcol] ? "1" : "0";
		is_value = 1;
	end

	// frame counter, 4 hex digits at columns 11..14 of row 26
	if (brow == 26 && bcol >= 11 && bcol <= 14) begin
		bch = hex_char(FR[(14 - bcol)*4 +: 4]);
		is_value = 1;
	end
end

font8x8 body_font(.ch(bch), .row(y[3:1]), .bits(bbits));

// Button boxes: 5 cells wide, at columns 3, 9, 15, 21, 29 of rows 8 and 10
always_comb begin
	in_box = 0;
	pressed = 0;
	if (brow == 8 || brow == 10) begin
		if      (bcol >= 3  && bcol <= 7)  begin in_box = 1; pressed = (brow == 8) ? Up    : A;      end
		else if (bcol >= 9  && bcol <= 13) begin in_box = 1; pressed = (brow == 8) ? Down  : B;      end
		else if (bcol >= 15 && bcol <= 19) begin in_box = 1; pressed = (brow == 8) ? Left  : Select; end
		else if (bcol >= 21 && bcol <= 25) begin in_box = 1; pressed = (brow == 8) ? Right : Start;  end
		else if (bcol >= 29 && bcol <= 33) begin in_box = 1; pressed = (brow == 8) ? KP[0] : KP[1]; end
	end
end

// Layers: title > wheel bar > body text > boxes > background
always_comb begin
	rgb = BG;
	if (in_box)
		rgb = pressed ? BOX_PRESS : BOX_IDLE;
	if (bbits[x[3:1]])
		rgb = (in_box && pressed) ? 12'h000 : (is_value ? VALUE : TEXT);
	if (brow == 22 && x >= 48 && x < 560)
		rgb = (x - 10'd48 < WH[11:3]) ? BAR : TRACK;
	if (in_title)
		rgb = tbits[x[4:2]] ? TITLE : BG;
end

assign Red   = rgb[11:8];
assign Green = rgb[7:4];
assign Blue  = rgb[3:0];

endmodule
