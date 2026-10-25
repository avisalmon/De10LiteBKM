// Lesson 1: the board hunt, a tour of every input on the DE10-Lite and the shield
//
// The LCD (and VGA) gives one challenge at a time: switches, keys, joystick, A, B, Start, the wheel. When the
// board sees it done, it beeps and moves on. You are not writing anything yet: this design is the course's.
// LEDR:   follows the switches.            HEX:   "St 05" = step 5, "donE" at the end.
// Buzzer: the success beep, and while B is held.  Status LED: while any game-pad button is held.
// USB:    "HUNT STEP 05 OK" per step, "HUNT COMPLETE" at the end (scripts/de10.py log); 'F' reads the screen.
// ***********************************************

module hunt_top (
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

wire				clk_25, clk_50, clk_100;
wire	[31:0]	pxl_x, pxl_y;
wire	[3:0]		r, g, b;
wire	[7:0]		lcd_db;
wire				lcd_reset, lcd_wr, lcd_d_c, lcd_rd;

pll25 pll(.areset(1'b0), .inclk0(MAX10_CLK1_50), .c0(clk_25), .c1(clk_50), .c2(clk_100), .locked());

Screens_dispaly screens(
	.clk_25(clk_25), .clk_100(clk_100), .Red_level(r), .Green_level(g), .Blue_level(b),
	.pxl_x(pxl_x), .pxl_y(pxl_y),
	.Red(VGA_R), .Green(VGA_G), .Blue(VGA_B), .h_sync(VGA_HS), .v_sync(VGA_VS),
	.lcd_db(lcd_db), .lcd_reset(lcd_reset), .lcd_wr(lcd_wr), .lcd_d_c(lcd_d_c), .lcd_rd(lcd_rd));

// ---- inputs (50 MHz: the game pad's ADC needs it), all debounced for 10 ms
wire	[11:0]	a0, a1, a2, a3, a4, wheel;
wire				A, B, Select, Start, Right, Left, Up, Down;
gamepad pad(.clk(clk_50), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));

wire	[7:0]		btn;									// {Left, Right, Up, Down, Start, Select, B, A}
wire	[9:0]		sw;
wire	[1:0]		key;									// 1 = pressed (the KEYs read 0 when pressed)
debounce #(.N(20), .STEADY(500_000)) deb(.clk(clk_50),
	.in({Left, Right, Up, Down, Start, Select, B, A, SW, ~KEY}), .out({btn, sw, key}));

// ---- the hunt
wire	[3:0]		step;
wire				step_done, beep;
hunt_logic hunt(.clk(clk_50), .sw(sw), .key(key), .up(btn[5]), .left(btn[7]), .a(btn[0]), .b(btn[1]),
	.start(btn[3]), .select(btn[2]), .wheel(wheel), .step(step), .step_done(step_done), .beep(beep));

// ---- screen (25 MHz); step, switches and wheel change slowly, so reading them across clocks is harmless here
hunt_screen screen(.pxl_x(pxl_x), .pxl_y(pxl_y), .step(step), .sw(sw), .wheel(wheel), .flash(beep),
	.Red(r), .Green(g), .Blue(b));

// ---- buzzer (2 kHz) and status LED
reg	[13:0]	tone_cnt = 0;
reg				tone = 0;
always @(posedge clk_50) begin
	tone_cnt <= (tone_cnt == 12_499) ? 14'd0 : tone_cnt + 1'b1;
	if (tone_cnt == 0) tone <= ~tone;
end
assign ARDUINO_IO = {2'b00, (btn != 0), (beep | btn[1]) & tone, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// ---- LEDs and 7-segment
assign LEDR = sw;
wire	[3:0]		n = (step == 13) ? 4'd13 : step + 1'b1;
wire	[7:0]		tens = (n >= 10) ? "1" : "0";
wire	[7:0]		ones = 8'h30 + ((n >= 10) ? n - 4'd10 : n);
wire				done = step == 13;
seg7_char s5(.ch(done ? "D" : "S"), .dp(1'b0), .seg(HEX5));
seg7_char s4(.ch(done ? "O" : "T"), .dp(1'b0), .seg(HEX4));
seg7_char s3(.ch(done ? "N" : " "), .dp(1'b0), .seg(HEX3));
seg7_char s2(.ch(done ? "E" : " "), .dp(1'b0), .seg(HEX2));
seg7_char s1(.ch(done ? " " : tens), .dp(1'b0), .seg(HEX1));
seg7_char s0(.ch(done ? " " : ones), .dp(1'b0), .seg(HEX0));

// ---- USB: a line per passed step (50 MHz) and the debug link (25 MHz), through one JTAG UART
wire	[7:0]		p_data, p25_data, d_data, tx_data, rx_data;
wire				p_valid, p_ready, p25_valid, p25_ready, d_valid, d_ready, tx_valid, tx_ready, rx_valid;
// step_done comes with the new step number: passing step k (1-based) leaves step = k
wire	[7:0]		dt = 8'h30 + ((step >= 10) ? 4'd1 : 4'd0);
wire	[7:0]		du = 8'h30 + ((step >= 10) ? step - 4'd10 : step);
line_printer #(.MAXLEN(32)) printer(.clk(clk_50),
	.text(step == 13 ? {"HUNT STEP 13 OK - HUNT COMPLETE", 8'h20} : {"HUNT STEP ", dt, du, " OK", 136'h0}),
	.len(step == 13 ? 7'd31 : 7'd15), .send(step_done), .busy(),
	.tx_data(p_data), .tx_valid(p_valid), .tx_ready(p_ready));

byte_cdc cdc(.wr_clk(clk_50), .wr_data(p_data), .wr_valid(p_valid), .wr_ready(p_ready),
	.rd_clk(clk_25), .rd_data(p25_data), .rd_valid(p25_valid), .rd_ready(p25_ready));

debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(btn), .key_pressed(key), .SW(sw), .wheel(wheel), .frame(16'h0000),
	.tx_data(d_data), .tx_valid(d_valid), .tx_ready(d_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());

tx_mux mux(.clk(clk_25), .a_data(p25_data), .a_valid(p25_valid), .a_ready(p25_ready),
	.b_data(d_data), .b_valid(d_valid), .b_ready(d_ready), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule
