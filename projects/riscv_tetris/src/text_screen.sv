// 80 x 60 text screen on the 640 x 480 picture: 8 x 8 cells from the text RAM, the lib font, a 16-colour palette.
//
// Cell word: [7:0] character, [11:8] foreground, [15:12] background. Characters 0x20..0x7F come from font8x8
// (lower case folds to upper); 0x80.. are block glyphs drawn here: 0x80 full, 0x81 inner (6 x 6), 0x82 shaded,
// 0x83 frame. The RAM answers one clock after the address, so the cell of the NEXT pixel is requested.
// ***********************************************
`default_nettype none

module text_screen (
	input		wire				clk,
	input		wire	[31:0]	pxl_x,
	input		wire	[31:0]	pxl_y,
	output	logic	[12:0]	text_addr,
	input		wire	[15:0]	text_q,
	output	logic	[11:0]	rgb
	);

wire				visible = pxl_x < 32'd640 && pxl_y < 32'd480;
wire	[9:0]		nx  = pxl_x[9:0] + 10'd1;
wire	[6:0]		ncol = nx[9:3];
wire	[5:0]		nrow = pxl_y[8:3];
assign text_addr = {nrow, 6'd0} + {nrow, 4'd0} + ncol;		// row * 80 + col  (80 = 64 + 16)

wire	[7:0]		ch = text_q[7:0];
wire	[2:0]		u = pxl_x[2:0], v = pxl_y[2:0];
wire	[7:0]		fbits;
font8x8 font(.ch(ch), .row(v), .bits(fbits));

logic				on;
always_comb
	if (!ch[7]) on = fbits[u];
	else case (ch[1:0])
		2'd0: on = 1'b1;												// full block
		2'd1: on = (u != 3'd0 && u != 3'd7 && v != 3'd0 && v != 3'd7);	// inner block
		2'd2: on = u[0] ^ v[0];											// shade
		default: on = (u == 3'd0 || u == 3'd7 || v == 3'd0 || v == 3'd7);	// frame
	endcase

function automatic [11:0] palette(input [3:0] i);
	case (i)
		4'd0: palette = 12'h000; 4'd1: palette = 12'h00A; 4'd2: palette = 12'h0A0; 4'd3: palette = 12'h0AA;
		4'd4: palette = 12'hA00; 4'd5: palette = 12'hA0A; 4'd6: palette = 12'hA50; 4'd7: palette = 12'hAAA;
		4'd8: palette = 12'h555; 4'd9: palette = 12'h55F; 4'd10: palette = 12'h5F5; 4'd11: palette = 12'h5FF;
		4'd12: palette = 12'hF55; 4'd13: palette = 12'hF5F; 4'd14: palette = 12'hFF5; default: palette = 12'hFFF;
	endcase
endfunction

assign rgb = !visible ? 12'h000 : palette(on ? text_q[11:8] : text_q[15:12]);

endmodule
