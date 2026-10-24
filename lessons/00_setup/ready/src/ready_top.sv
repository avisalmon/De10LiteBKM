// Lesson 0 board check: proves Quartus, the cable and the board work together
//
// LEDR:   one light runs back and forth.
// HEX:    "rEAdY" on HEX5..HEX1 (HEX0 blank).
// Screen: eight colour bars and "READY" in big letters, on the LCD shield and on VGA.
// USB:    the PC can read the screen back (lib/rtl/debug_link.sv, scripts/de10.py screen).
// No buttons, no switches: if you see all three, the whole chain works.
// ***********************************************

module ready_top (
	input						MAX10_CLK1_50,
	output		[9:0]		LEDR,
	output		[7:0]		HEX0,
	output		[7:0]		HEX1,
	output		[7:0]		HEX2,
	output		[7:0]		HEX3,
	output		[7:0]		HEX4,
	output		[7:0]		HEX5,
	output		[3:0]		VGA_R,
	output		[3:0]		VGA_G,
	output		[3:0]		VGA_B,
	output					VGA_HS,
	output					VGA_VS,
	output		[15:0]	ARDUINO_IO
	);

wire				clk_25, clk_100;
wire	[31:0]	pxl_x, pxl_y;
wire	[7:0]		lcd_db;
wire				lcd_reset, lcd_wr, lcd_d_c, lcd_rd;
wire	[7:0]		tx_data, rx_data;
wire				tx_valid, tx_ready, rx_valid;

pll25 pll(.areset(1'b0), .inclk0(MAX10_CLK1_50), .c0(clk_25), .c1(), .c2(clk_100), .locked());

// ---- the picture: colour bars on top, "READY" (8x8 font drawn x8) below
wire	[9:0]		x = pxl_x[9:0];
wire	[8:0]		y = pxl_y[8:0];
localparam TX = 160, TY = 336;								// text box: 5 letters x 64 = 320 wide, 64 high
localparam [8*5-1:0] WORD = "READY";

wire	[9:0]		tx = x - TX;
wire	[8:0]		ty = y - TY;
wire				in_text = (x >= TX) && (x < TX + 320) && (y >= TY) && (y < TY + 64);
wire	[2:0]		letter = tx[9:6];
wire	[7:0]		ch = in_text ? WORD[8*(4 - letter) +: 8] : 8'h20;
wire	[7:0]		glyph;
font8x8 font(.ch(ch), .row(ty[5:3]), .bits(glyph));
wire				text_on = in_text && glyph[tx[5:3]];

reg	[11:0]	rgb;
always @(*) begin
	rgb = text_on ? 12'hFFF : 12'h113;						// white letters on dark blue
	if (y < 288)
		case (x / 80)										// 8 bars of 80 pixels
			0: rgb = 12'hFFF;	// white
			1: rgb = 12'hFF0;	// yellow
			2: rgb = 12'h0FF;	// cyan
			3: rgb = 12'h0F0;	// green
			4: rgb = 12'hF0F;	// magenta
			5: rgb = 12'hF00;	// red
			6: rgb = 12'h00F;	// blue
			default: rgb = 12'h000;	// black
		endcase
end

Screens_dispaly screens(
	.clk_25(clk_25), .clk_100(clk_100),
	.Red_level(rgb[11:8]), .Green_level(rgb[7:4]), .Blue_level(rgb[3:0]),
	.pxl_x(pxl_x), .pxl_y(pxl_y),
	.Red(VGA_R), .Green(VGA_G), .Blue(VGA_B), .h_sync(VGA_HS), .v_sync(VGA_VS),
	.lcd_db(lcd_db), .lcd_reset(lcd_reset), .lcd_wr(lcd_wr), .lcd_d_c(lcd_d_c), .lcd_rd(lcd_rd));

assign ARDUINO_IO = {2'b00, 1'b0, 1'b0, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// ---- screen read-back over USB, so the chat can see what you see
debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(8'h00), .key_pressed(2'b00), .SW(10'h000), .wheel(12'h000), .frame(16'h0000),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .rx_data(rx_data), .rx_valid(rx_valid),
	.beep());
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

// ---- 7-segment: "rEAdY "
seg7_char s5(.ch("R"), .dp(1'b0), .seg(HEX5));
seg7_char s4(.ch("E"), .dp(1'b0), .seg(HEX4));
seg7_char s3(.ch("A"), .dp(1'b0), .seg(HEX3));
seg7_char s2(.ch("D"), .dp(1'b0), .seg(HEX2));
seg7_char s1(.ch("Y"), .dp(1'b0), .seg(HEX1));
seg7_char s0(.ch(" "), .dp(1'b0), .seg(HEX0));

// ---- LEDs: a light running back and forth, one step every ~84 ms
reg	[9:0]		run = 10'b1;
reg				dir = 0;
reg	[21:0]	t = 0;
always @(posedge clk_25) begin
	t <= t + 1'b1;
	if (t == 0) begin
		if (!dir) begin run <= run << 1; if (run[8]) dir <= 1; end
		else      begin run <= run >> 1; if (run[1]) dir <= 0; end
	end
end
assign LEDR = run;

endmodule
