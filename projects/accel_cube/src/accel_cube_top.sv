// Accelerometer cube on the DE10-Lite with the LCD / game-pad shield: the board's ADXL345 read over SPI,
// shown as numbers, as a shaded 3D cube that tilts with the board, and as a 3D vector in the board's frame.
// No frame buffer: the picture is computed pixel by pixel as the screen scans (src/cube_draw.sv) from the
// frame's parameters, which one sequential engine computes in the vertical blanking (src/cube_math.sv).
// assets/model.py is the bit-exact reference of both.
//
// Controls: USB '0'..'7' test presets, 'l' live, 'c' calibrate (board flat), 'u' forget the calibration,
// 's' spin the view on/off, 'k' peak restart, 'r' report (scripts/de10.py send); KEY0 peak restart,
// KEY1 calibrate; the shield's game pad (the MAX 10 ADC, lib gamepad): A calibrate, B peak restart, Select
// forget the calibration, Start spin on/off (the shield hides KEY0 / KEY1). The switches do nothing.
// LEDs: a bubble level along x. 7-segment: the mode (preset digit, C calibrated, L live) and |a| in g.
// The shield's status LED: the engine was late for a frame.
// '?' status and 'F' screen capture come from lib debug_link (scripts/de10.py screen).
// ***********************************************
`default_nettype none

module accel_cube_top #(
	parameter HEADING = 0			// which way the board's +x points on the screen: 0, 90, 180 or 270
)(
	input		wire				MAX10_CLK1_50,
	input		wire	[1:0]		KEY,
	input		wire	[9:0]		SW,
	output	logic	[9:0]		LEDR,
	output	logic	[7:0]		HEX0,
	output	logic	[7:0]		HEX1,
	output	logic	[7:0]		HEX2,
	output	logic	[7:0]		HEX3,
	output	logic	[7:0]		HEX4,
	output	logic	[7:0]		HEX5,
	output	logic	[3:0]		VGA_R,
	output	logic	[3:0]		VGA_G,
	output	logic	[3:0]		VGA_B,
	output	logic				VGA_HS,
	output	logic				VGA_VS,
	output	logic	[15:0]	ARDUINO_IO,
	output	wire				GSENSOR_CS_N,
	output	wire				GSENSOR_SCLK,
	inout		wire				GSENSOR_SDI,
	inout		wire				GSENSOR_SDO,
	input		wire	[2:1]		GSENSOR_INT
	);

wire				clk_25, clk_50, clk_100, locked;
wire	[31:0]	pxl_x, pxl_y;
wire	[11:0]	rgb;
wire	[7:0]		lcd_db;
wire				lcd_reset, lcd_wr, lcd_d_c, lcd_rd;

pll25 pll(.areset(1'b0), .inclk0(MAX10_CLK1_50), .c0(clk_25), .c1(clk_50), .c2(clk_100), .locked(locked));

Screens_dispaly screens(
	.clk_25(clk_25), .clk_100(clk_100), .Red_level(rgb[11:8]), .Green_level(rgb[7:4]), .Blue_level(rgb[3:0]),
	.pxl_x(pxl_x), .pxl_y(pxl_y),
	.Red(VGA_R), .Green(VGA_G), .Blue(VGA_B), .h_sync(VGA_HS), .v_sync(VGA_VS),
	.lcd_db(lcd_db), .lcd_reset(lcd_reset), .lcd_wr(lcd_wr), .lcd_d_c(lcd_d_c), .lcd_rd(lcd_rd));

// ---- reset: the PLL's lock, synchronised into the pixel clock
logic	[1:0]		rst_s = 2'b11;
always @(posedge clk_25) rst_s <= {rst_s[0], !locked};
wire				rst = rst_s[1];

// ---- the accelerometer (the driver wants 50 MHz), then each sample into the 25 MHz domain:
// the sample is held while a toggle crosses; it is stable long before the next one (10 ms later)
wire				sdio_out, sdio_oe, acc_valid50;
wire	[7:0]		devid50;
wire	signed [15:0]	x50, y50, z50;
assign GSENSOR_SDI = sdio_oe ? sdio_out : 1'bz;		// 4-wire SPI: SDI is our data out, SDO the chip's
assign GSENSOR_SDO = 1'bz;
adxl345 #(.THREE_WIRE(0)) accel(.clk(clk_50), .cs_n(GSENSOR_CS_N), .sclk(GSENSOR_SCLK),
	.sdio_out(sdio_out), .sdio_oe(sdio_oe), .sdio_in(GSENSOR_SDI), .miso(GSENSOR_SDO),
	.devid(devid50), .x(x50), .y(y50), .z(z50), .valid(acc_valid50));
logic	signed [15:0]	xh, yh, zh;
logic				tog50 = 1'b0;
always @(posedge clk_50) if (acc_valid50) begin
	xh <= x50; yh <= y50; zh <= z50;
	tog50 <= !tog50;
end
logic	[2:0]		tog_s = 3'b000;
logic	[7:0]		devid_m, devid;
always @(posedge clk_25) begin
	tog_s <= {tog_s[1:0], tog50};
	devid_m <= devid50; devid <= devid_m;
end
wire				acc_valid = tog_s[2] ^ tog_s[1];

// ---- the shield's game pad through the MAX 10 ADC (the reader wants 50 MHz), debounced there, then two
// flops into the pixel clock; the wheel is only reported in the '?' status line
wire	[11:0]	a0, a1, a2, a3, a4, wheel;
wire				A, B, Select, Start, Right, Left, Up, Down;
gamepad pad(.clk(clk_50), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));
wire	[7:0]		btn50;
debounce #(.N(8), .STEADY(250_000)) deb(.clk(clk_50), .in({Left, Right, Up, Down, Start, Select, B, A}), .out(btn50));
logic	[7:0]		btn_m, btn;			// {Left, Right, Up, Down, Start, Select, B, A}

// ---- keys and switches (synchronised; the keys active high; the switches only for the '?' status line)
// and the frame tick: the start of vertical sync, in the blanking
logic	[1:0]		key_m, key_s;
logic	[9:0]		sw_m, sw_s;
logic				vs_d;
logic	[15:0]	frame = 16'd0;
always @(posedge clk_25) begin
	btn_m <= btn50;  btn <= btn_m;
	key_m <= ~KEY;  key_s <= key_m;
	sw_m <= SW;  sw_s <= sw_m;
	vs_d <= VGA_VS;
end
wire				tick = vs_d && !VGA_VS;
always @(posedge clk_25) if (tick) frame <= frame + 1'b1;
wire	[3:0]		key4 = {btn[3], btn[2], key_s[1] | btn[0], key_s[0] | btn[1]};	// spin, forget, calibrate, peak

// ---- the cube
wire	[7:0]		rx_data, p_data;
wire				rx_valid, p_valid, p_ready;
wire	[47:0]	hex;
wire				status_led;
cube_core #(.HEADING(HEADING)) core(.clk(clk_25), .rst(rst), .tick(tick), .pxl_x(pxl_x), .pxl_y(pxl_y),
	.acc_x(xh), .acc_y(yh), .acc_z(zh), .acc_valid(acc_valid), .devid(devid),
	.key(key4), .rx_data(rx_data), .rx_valid(rx_valid),
	.p_data(p_data), .p_valid(p_valid), .p_ready(p_ready),
	.rgb(rgb), .leds(LEDR), .hex(hex), .status_led(status_led));
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = hex;
assign ARDUINO_IO = {2'b00, status_led, 1'b0, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// ---- USB: the report line and the debug link (status '?', screen 'F') share the JTAG UART through tx_mux
wire	[7:0]		d_data, tx_data;
wire				d_valid, d_ready, tx_valid, tx_ready;
debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(btn), .key_pressed(key_s), .SW(sw_s), .wheel(wheel), .frame(frame),
	.tx_data(d_data), .tx_valid(d_valid), .tx_ready(d_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
tx_mux mux(.clk(clk_25), .a_data(p_data), .a_valid(p_valid), .a_ready(p_ready),
	.b_data(d_data), .b_valid(d_valid), .b_ready(d_ready), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule

`default_nettype wire
