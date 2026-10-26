// FFT lab on the DE10-Lite with the LCD / game-pad shield: a wave, its scope trace, and its spectrum from two
// FFTs side by side, our RTL radix-2 (src/fft_r2.sv) and Altera's FFT II IP (ip/fft256), each with its time
//
// Controls: the wheel tunes the frequency; joystick Left / Right (and KEY1) the shape, Up / Down fine steps;
// A Hann window, B dB / linear, Start hold, Select sound; KEY0 defaults. LEDs: shape, window, linear, hold,
// sound. 7-segment: the frequency in Hz. The shield's status LED: the IP is not running.
// Over USB (scripts/de10.py send): S N W L H M with digits, R report line, D defaults (see lab_ctrl.sv);
// '?' status and 'F' screen capture come from lib debug_link (scripts/de10.py screen).
// ***********************************************
`default_nettype none

module fft_lab_top (
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
	output	logic	[15:0]	ARDUINO_IO
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

// ---- game pad (50 MHz, the ADC needs it), debounced, then into the 25 MHz domain
wire	[11:0]	a0, a1, a2, a3, a4, wheel;
wire				A, B, Select, Start, Right, Left, Up, Down;
gamepad pad(.clk(clk_50), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));
wire	[7:0]		btn50;
debounce #(.N(8), .STEADY(250_000)) deb(.clk(clk_50), .in({Left, Right, Up, Down, Start, Select, B, A}), .out(btn50));
logic	[7:0]		btn_m, btn;			// {Left, Right, Up, Down, Start, Select, B, A}
logic	[1:0]		key_m, key_s;
always @(posedge clk_25) begin
	btn_m <= btn50; btn <= btn_m;
	key_m <= ~KEY;  key_s <= key_m;
end

// ---- frame tick: the start of vertical sync, inside the blanking time
logic				vs_d;
always @(posedge clk_25) vs_d <= VGA_VS;
wire				tick = vs_d && !VGA_VS;
logic	[15:0]	frame = 16'd0;
always @(posedge clk_25) if (tick) frame <= frame + 1'b1;

// ---- the lab
wire	[7:0]		rx_data, p_data;
wire				rx_valid, p_valid, p_ready;
wire	[47:0]	hex;
wire				buzz, status_led;
fft_lab_core core(.clk(clk_25), .rst_hold(!locked), .tick(tick), .pxl_x(pxl_x), .pxl_y(pxl_y),
	.btn(btn), .key(key_s), .wheel(wheel), .rx_data(rx_data), .rx_valid(rx_valid),
	.p_data(p_data), .p_valid(p_valid), .p_ready(p_ready),
	.rgb(rgb), .leds(LEDR), .hex(hex), .buzz(buzz), .status_led(status_led));
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = hex;
assign ARDUINO_IO = {2'b00, status_led, buzz, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// ---- USB: the report line and the debug link (status '?', screen 'F') share the JTAG UART through tx_mux
wire	[7:0]		d_data, tx_data;
wire				d_valid, d_ready, tx_valid, tx_ready;
debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(btn), .key_pressed(key_s), .SW(SW), .wheel(wheel), .frame(frame),
	.tx_data(d_data), .tx_valid(d_valid), .tx_ready(d_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
tx_mux mux(.clk(clk_25), .a_data(p_data), .a_valid(p_valid), .a_ready(p_ready),
	.b_data(d_data), .b_valid(d_valid), .b_ready(d_ready), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule

`default_nettype wire
