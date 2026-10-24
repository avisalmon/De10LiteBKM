// Example 05: read the screen programmatically
//
// Shows a test card (src/test_card.sv) on the LCD and VGA. The PC reads the screen back over USB ('F', 320x240,
// scripts/de10.py screen) and can move the white box: 'H' home (64, 192), 'L' 'R' 'U' 'D' 32 pixels.
// examples/05_screen_readback/test_screen.py moves the box, captures, and compares every pixel with the frame
// the simulation renders for the same position: what you simulate is what is on the screen.
// ***********************************************

`default_nettype none

module screen_top (
	input		wire				MAX10_CLK1_50,
	output	wire	[9:0]		LEDR,
	output	wire	[3:0]		VGA_R,
	output	wire	[3:0]		VGA_G,
	output	wire	[3:0]		VGA_B,
	output	wire				VGA_HS,
	output	wire				VGA_VS,
	output	wire	[15:0]	ARDUINO_IO
	);

wire				clk_25, clk_100;
wire	[31:0]	pxl_x, pxl_y;
wire	[11:0]	rgb;
wire	[7:0]		lcd_db, tx_data, rx_data;
wire				lcd_reset, lcd_wr, lcd_d_c, lcd_rd, tx_valid, tx_ready, rx_valid;
reg	[9:0]		bx = 64;
reg	[8:0]		by = 192;

pll25 pll(.areset(1'b0), .inclk0(MAX10_CLK1_50), .c0(clk_25), .c1(), .c2(clk_100), .locked());

Screens_dispaly screens(
	.clk_25(clk_25), .clk_100(clk_100), .Red_level(rgb[11:8]), .Green_level(rgb[7:4]), .Blue_level(rgb[3:0]),
	.pxl_x(pxl_x), .pxl_y(pxl_y),
	.Red(VGA_R), .Green(VGA_G), .Blue(VGA_B), .h_sync(VGA_HS), .v_sync(VGA_VS),
	.lcd_db(lcd_db), .lcd_reset(lcd_reset), .lcd_wr(lcd_wr), .lcd_d_c(lcd_d_c), .lcd_rd(lcd_rd));
assign ARDUINO_IO = {4'b0000, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

test_card card(.pxl_x(pxl_x), .pxl_y(pxl_y), .bx(bx), .by(by), .rgb(rgb));

// commands from the PC move the box (debug_link answers '?' 'F' 'B' itself)
always @(posedge clk_25) if (rx_valid) begin
	case (rx_data)
		"H", "h": begin bx <= 64; by <= 192; end
		"L", "l": if (bx >= 32) bx <= bx - 10'd32;
		"R", "r": if (bx <= 576) bx <= bx + 10'd32;
		"U", "u": if (by >= 32) by <= by - 9'd32;
		"D", "d": if (by <= 416) by <= by + 9'd32;
		default: ;
	endcase
end

debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(8'h00), .key_pressed(2'b00), .SW(10'h000), .wheel(12'h000), .frame(16'h0000),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

assign LEDR = {bx[9:5], by[8:5] , 1'b0};

endmodule

`default_nettype wire
