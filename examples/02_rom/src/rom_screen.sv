// Example 02 screen: three ROMs drawn on 640x480
//
//   text ROM   inferred, $readmemh(TEXT_FILE): 40x30 characters, one ASCII byte each (assets/text.hex)
//   image A    inferred, $readmemh(IMG_A_FILE): 64x64 RGB444 picture, drawn x4 at (48,112)
//   image B    rom_ip (altsyncram IP) from IMG_B_MIF, runtime-editable instance "IMG", drawn x4 at (336,112)
// Every ROM answers one clock after its address, so addresses are computed for the NEXT pixel (x + 1).
// ***********************************************

module rom_screen #(
	parameter TEXT_FILE  = "assets/text.hex",
	parameter IMG_A_FILE = "assets/chip.hex",
	parameter IMG_B_MIF  = "assets/chip.mif"
)(
	input					clk,			// pixel clock
	input		[31:0]	pxl_x,
	input		[31:0]	pxl_y,
	output	[3:0]		Red,
	output	[3:0]		Green,
	output	[3:0]		Blue
	);

localparam AX = 48, BX = 336, IY = 112, SIZE = 256;		// 64 x 4

wire	[9:0]		x  = pxl_x[9:0];
wire	[8:0]		y  = pxl_y[8:0];
wire	[9:0]		xn = x + 1'b1;								// next pixel: what the ROMs must fetch now

// ---- text ROM: character cell (xn / 16, y / 16)
reg	[7:0]		text_rom [0:1199];
reg	[7:0]		ch = 8'h20;
initial $readmemh(TEXT_FILE, text_rom);
always @(posedge clk)
	ch <= (xn < 640) ? text_rom[y[8:4] * 40 + xn[9:4]] : 8'h20;

wire	[7:0]		glyph;
font8x8 font(.ch(ch), .row(y[3:1]), .bits(glyph));
wire				text_on = glyph[x[3:1]];

// ---- image A: inferred ROM
reg	[11:0]	img_a [0:4095];
reg	[11:0]	qa = 0;
initial $readmemh(IMG_A_FILE, img_a);
wire	[9:0]		ax = xn - AX;
wire	[8:0]		ay = y - IY;
always @(posedge clk)
	qa <= img_a[{ay[7:2], ax[7:2]}];

// ---- image B: altsyncram IP, editable over JTAG
wire	[9:0]		bx = xn - BX;
wire	[11:0]	qb;
rom_ip #(.WIDTH(12), .DEPTH(4096), .AW(12), .INIT_FILE(IMG_B_MIF),
		 .LPM_HINT("ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=IMG")) img_b (
	.clk(clk), .address({ay[7:2], bx[7:2]}), .q(qb));

// ---- which picture is under the current pixel (decided from x, not xn)
wire	in_y = (y >= IY) && (y < IY + SIZE);
wire	in_a = in_y && (x >= AX) && (x < AX + SIZE);
wire	in_b = in_y && (x >= BX) && (x < BX + SIZE);

reg	[11:0]	rgb;
always_comb begin
	rgb = 12'h113;
	if (in_a) rgb = qa;
	if (in_b) rgb = qb;
	if (text_on) rgb = 12'hFFF;
end

assign {Red, Green, Blue} = rgb;

endmodule
