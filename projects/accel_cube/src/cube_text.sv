// The text panel of the accelerometer cube: 16 columns x 14 rows of 16 x 16 pixel characters (the 8x8 font at
// 2x) to the right of the cube, and the one-line report sent over USB. Pure combinational: given a row and a
// column it returns the character and the row's colour. Mirrors panel_text() / fmt_mg() / fmt_deg() in
// assets/model.py character for character.
// ***********************************************
`default_nettype none

module cube_text (
	input		wire	[3:0]				row,				// text row 0..13 (y / 16)
	input		wire	[3:0]				col,				// text column 0..15 ((x - 384) / 16)
	input		wire	[6:0][15:0]		bcd4,				// x, y, z, |a|, peak in mg; pitch, roll in 0.1 degree (BCD)
	input		wire	[2:0][19:0]		bcd5,				// |ax|, |ay|, |az| in Q4 counts (BCD, the report only)
	input		wire	[4:0]				neg,				// signs: x, y, z, pitch, roll
	input		wire	[7:0]				devid,			// the ADXL345's device ID (0xE5)
	input		wire	[1:0]				mode,				// 0 live, 1 live calibrated, 2 test preset
	input		wire	[2:0]				test_n,			// the preset number in test mode
	output	wire	[7:0]				ch,				// ASCII of (row, col); 0x20 where blank
	output	wire	[11:0]			color,			// the row's text colour
	output	wire	[8*114-1:0]		report			// the USB report line, 114 characters, first in the top byte
	);

localparam [7:0] SP = 8'h20;

function automatic [7:0] dg(input [3:0] d);			// a BCD digit as ASCII
	dg = 8'h30 + {4'b0, d};
endfunction
function automatic [7:0] hx(input [3:0] d);			// a hex digit as ASCII (upper case)
	hx = (d < 4'd10) ? 8'h30 + {4'b0, d} : 8'h37 + {4'b0, d};
endfunction
// "+1.234" / "-0.500" / " 1.000": sign, units, point, three decimals (mg as g)
function automatic [47:0] fmt_mg(input [15:0] b, input n, input sgn);
	fmt_mg = {n ? 8'h2D : (sgn ? 8'h2B : SP), dg(b[15:12]), 8'h2E, dg(b[11:8]), dg(b[7:4]), dg(b[3:0])};
endfunction
// "+180.0" / " -30.0" / "  +0.0": the sign floats to just before the first printed digit
function automatic [47:0] fmt_deg(input [15:0] b, input n);
	reg [7:0] s;
	reg [23:0] head;
	begin
		s = n ? 8'h2D : 8'h2B;
		if (b[15:12] != 4'd0) head = {s, dg(b[15:12]), dg(b[11:8])};
		else if (b[11:8] != 4'd0) head = {SP, s, dg(b[11:8])};
		else head = {SP, SP, s};
		fmt_deg = {head, dg(b[7:4]), 8'h2E, dg(b[3:0])};
	end
endfunction
// "+04096": sign and five digits (Q4 counts, the report only)
function automatic [47:0] fmt_aq(input [19:0] b, input n);
	fmt_aq = {n ? 8'h2D : 8'h2B, dg(b[19:16]), dg(b[15:12]), dg(b[11:8]), dg(b[7:4]), dg(b[3:0])};
endfunction

wire	[47:0]	sx = fmt_mg(bcd4[0], neg[0], 1'b1);
wire	[47:0]	sy = fmt_mg(bcd4[1], neg[1], 1'b1);
wire	[47:0]	sz = fmt_mg(bcd4[2], neg[2], 1'b1);
wire	[47:0]	smag = fmt_mg(bcd4[3], 1'b0, 1'b0);
wire	[47:0]	speak = fmt_mg(bcd4[4], 1'b0, 1'b0);
wire	[47:0]	spitch = fmt_deg(bcd4[5], neg[3]);
wire	[47:0]	sroll = fmt_deg(bcd4[6], neg[4]);
wire	[127:0]	row13 = (mode == 2'd2) ? {"TEST ", dg({1'b0, test_n}), {10{SP}}} :
                      (mode == 2'd1) ? "LIVE CAL        " : "LIVE            ";

logic	[127:0]	rs;											// the 16 characters of the row
always_comb case (row)
	4'd0:  rs = {"ADXL345  ID ", hx(devid[7:4]), hx(devid[3:0]), SP, SP};
	4'd2:  rs = {"X   ", sx, " G    "};
	4'd4:  rs = {"Y   ", sy, " G    "};
	4'd6:  rs = {"Z   ", sz, " G    "};
	4'd8:  rs = {"MAG ", smag, " G    "};
	4'd9:  rs = {"PEAK", speak, " G    "};
	4'd10: rs = {"PITCH ", spitch, " DEG"};
	4'd11: rs = {"ROLL  ", sroll, " DEG"};
	4'd13: rs = row13;								// row 12 stays blank: an accelerometer has no yaw
	default: rs = {16{SP}};
endcase
wire	[3:0]		rcol = 4'd15 - col;
assign ch = rs[8 * rcol +: 8];

// row colours (model ROW_COLOR, LIVE_COLOR, TEST_COLOR)
assign color = (row == 4'd0) ? 12'hFE8 : (row == 4'd2) ? 12'hF99 : (row == 4'd4) ? 12'h9F9 :
               (row == 4'd6) ? 12'h99F : (row == 4'd10 || row == 4'd11) ? 12'hCCF :
               (row == 4'd13) ? ((mode == 2'd2) ? 12'hFC8 : 12'h9F9) : 12'hEEE;

// the report: "AQ +00000 +00000 +04096 X+0.000 Y+0.000 Z+1.000 MAG 1.000 PEAK 1.000 PITCH  +0.0 ..."
assign report = {"AQ ", fmt_aq(bcd5[0], neg[0]), SP, fmt_aq(bcd5[1], neg[1]), SP, fmt_aq(bcd5[2], neg[2]),
                 " X", sx, " Y", sy, " Z", sz, " MAG", smag, " PEAK", speak,
                 " PITCH", spitch, " ROLL", sroll,
                 " ID ", hx(devid[7:4]), hx(devid[3:0]), SP, row13};

endmodule

`default_nettype wire
