// Example 02: ROMs (text, two pictures), shown on the LCD and VGA
//
// The screen is drawn from three ROMs (see rom_screen.sv). Picture B can be rewritten from the PC while the
// design runs (In-System Memory Content Editor, scripts/mem_edit.tcl), and the PC can read the screen back
// over the same USB cable ('F' command of lib/rtl/debug_link.sv, scripts/de10.py screen).
// LEDR0 blinks (design alive).
// ***********************************************

module rom_top (
	input						MAX10_CLK1_50,
	output		[9:0]		LEDR,
	output		[3:0]		VGA_R,
	output		[3:0]		VGA_G,
	output		[3:0]		VGA_B,
	output					VGA_HS,
	output					VGA_VS,
	output		[15:0]	ARDUINO_IO
	);

wire				clk_25, clk_100;
wire	[31:0]	pxl_x, pxl_y;
wire	[3:0]		r, g, b;
wire	[7:0]		lcd_db;
wire				lcd_reset, lcd_wr, lcd_d_c, lcd_rd;
wire	[7:0]		tx_data, rx_data;
wire				tx_valid, tx_ready, rx_valid;

pll25 pll(.areset(1'b0), .inclk0(MAX10_CLK1_50), .c0(clk_25), .c1(), .c2(clk_100), .locked());

Screens_dispaly screens(
	.clk_25(clk_25), .clk_100(clk_100),
	.Red_level(r), .Green_level(g), .Blue_level(b),
	.pxl_x(pxl_x), .pxl_y(pxl_y),
	.Red(VGA_R), .Green(VGA_G), .Blue(VGA_B), .h_sync(VGA_HS), .v_sync(VGA_VS),
	.lcd_db(lcd_db), .lcd_reset(lcd_reset), .lcd_wr(lcd_wr), .lcd_d_c(lcd_d_c), .lcd_rd(lcd_rd));

rom_screen screen(.clk(clk_25), .pxl_x(pxl_x), .pxl_y(pxl_y), .Red(r), .Green(g), .Blue(b));

assign ARDUINO_IO = {2'b00, 1'b0, 1'b0, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// screen read-back over USB
debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(8'h00), .key_pressed(2'b00), .SW(10'h000), .wheel(12'h000), .frame(16'h0000),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .rx_data(rx_data), .rx_valid(rx_valid),
	.beep());
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

reg [24:0] alive = 0;
always @(posedge clk_25) alive <= alive + 1'b1;
assign LEDR = {9'b0, alive[24]};

endmodule
