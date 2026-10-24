// Example 04: the shield's game pad, wheel, buzzer and status LED (and the board's KEYs and switches)
//
// Screen: every control as a box that lights while held, the six raw ADC readings, the wheel as a bar
//   (lib hello screen layout, rebuilt on the library). 7-segment: the wheel in decimal 0..4095.
// USB: one line per change, e.g. "PRESS A   a3=02F" / "RELEASE A a3=E47" / "WHEEL 2048", plus '?' for a
//   full status line and 'F' for the screen (scripts/de10.py send / log / screen).
// Buzzer: beeps while B is held. Status LED: on while any control is held.
// ***********************************************

module gamepad_top (
	input						MAX10_CLK1_50,
	input			[1:0]		KEY,
	input			[9:0]		SW,
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

wire				clk_25, clk_50, clk_100, locked;
wire	[31:0]	pxl_x, pxl_y;
wire	[3:0]		r, g, b;
wire	[7:0]		lcd_db;
wire				lcd_reset, lcd_wr, lcd_d_c, lcd_rd;

pll25 pll(.areset(1'b0), .inclk0(MAX10_CLK1_50), .c0(clk_25), .c1(clk_50), .c2(clk_100), .locked(locked));

Screens_dispaly screens(
	.clk_25(clk_25), .clk_100(clk_100), .Red_level(r), .Green_level(g), .Blue_level(b),
	.pxl_x(pxl_x), .pxl_y(pxl_y),
	.Red(VGA_R), .Green(VGA_G), .Blue(VGA_B), .h_sync(VGA_HS), .v_sync(VGA_VS),
	.lcd_db(lcd_db), .lcd_reset(lcd_reset), .lcd_wr(lcd_wr), .lcd_d_c(lcd_d_c), .lcd_rd(lcd_rd));

// ---- game pad: 50 MHz (the ADC IP needs it); everything that uses it below runs at 50 MHz too
wire	[11:0]	a0, a1, a2, a3, a4, wheel;
wire				A, B, Select, Start, Right, Left, Up, Down;
gamepad pad(.clk(clk_50), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));

// debounce: a control counts as changed only after it has been steady for 10 ms
wire	[7:0]		raw = {Left, Right, Up, Down, Start, Select, B, A};
wire	[7:0]		btn;
debounce #(.N(8), .STEADY(500_000)) deb(.clk(clk_50), .in(raw), .out(btn));

// ---- screen (25 MHz): the values cross from 50 MHz; a stale pixel for one frame does no harm here
reg	[15:0]	frame = 0;
reg				vs_d = 0;
always @(posedge clk_25) begin
	vs_d <= VGA_VS;
	if (vs_d && !VGA_VS) frame <= frame + 1'b1;
end
gamepad_screen screen(.clk(clk_25), .pxl_x(pxl_x), .pxl_y(pxl_y), .vsync(VGA_VS),
	.a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel), .btn(btn), .key_pressed(~KEY), .SW(SW),
	.frame(frame), .Red(r), .Green(g), .Blue(b));

// ---- buzzer (2 kHz while B) and status LED (any control held)
reg	[13:0]	tone_cnt = 0;
reg				tone = 0;
always @(posedge clk_50) begin
	tone_cnt <= (tone_cnt == 12_499) ? 14'd0 : tone_cnt + 1'b1;
	if (tone_cnt == 0) tone <= ~tone;
end
assign ARDUINO_IO = {2'b00, (btn != 0), btn[1] & tone, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// ---- 7-segment: wheel in decimal
wire	[15:0]	wbcd;
wire	[7:0]		seg [0:3];
bin2bcd #(.BITS(12), .DIGITS(4)) wdec(.bin(wheel), .bcd(wbcd));
genvar gi;
generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : digits
		wire [7:0] s;
		seven_segment dec(.in_hex(wbcd[4*gi +: 4]), .out_to_ss(s));
		assign seg[gi] = (gi > 0 && wbcd[15:4*gi] == 0) ? 8'hFF : s;
	end
endgenerate
assign {HEX3, HEX2, HEX1, HEX0} = {seg[3], seg[2], seg[1], seg[0]};
assign HEX5 = 8'hFF;
assign HEX4 = 8'hFF;
assign LEDR = {btn[7:4], ~KEY, btn[3:0]};

// ---- USB: event lines (50 MHz) + debug link (25 MHz) through one JTAG UART
wire	[7:0]		e_data, d_data, tx_data, rx_data;
wire				e_valid, e_ready, d_valid, d_ready, tx_valid, tx_ready, rx_valid;
gamepad_events events(.clk(clk_50), .btn(btn), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.tx_data(e_data), .tx_valid(e_valid), .tx_ready(e_ready));

debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(btn), .key_pressed(~KEY), .SW(SW), .wheel(wheel), .frame(frame),
	.tx_data(d_data), .tx_valid(d_valid), .tx_ready(d_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());

// the event sender runs at 50 MHz: hand its bytes to the 25 MHz link through a small dual-clock FIFO
wire	[7:0]		e25_data;
wire				e25_valid, e25_ready;
byte_cdc cdc(.wr_clk(clk_50), .wr_data(e_data), .wr_valid(e_valid), .wr_ready(e_ready),
	.rd_clk(clk_25), .rd_data(e25_data), .rd_valid(e25_valid), .rd_ready(e25_ready));

tx_mux mux(.clk(clk_25), .a_data(e25_data), .a_valid(e25_valid), .a_ready(e25_ready),
	.b_data(d_data), .b_valid(d_valid), .b_ready(d_ready), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule
