// Pac-Man on the DE10-Lite with the LCD / game-pad shield
//
// Play: the joystick steers (the last direction is remembered, so you can turn before the corner); Start or
// KEY0 starts. Sound on the shield's buzzer. 7-segment: the score. LEDs: spare lives; LEDR9 = invincible.
// Over USB (scripts/de10.py send): u/l/d/r steer, s starts, p pauses, i invincible, m mutes; '?' status and
// 'F' screen capture come from lib debug_link (scripts/de10.py screen).
// ***********************************************
`default_nettype none

module pacman_top (
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

// ---- game pad (50 MHz, the ADC needs it), debounced, then into the 25 MHz game domain
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

// ---- commands over USB: u l d r s p i m
wire	[7:0]		rx_data;
wire				rx_valid;
logic				usb_want, usb_start_req, paused, invincible, muted;
logic	[1:0]		usb_dir;
always @(posedge clk_25) begin
	usb_want <= 1'b0;
	if (tick) usb_start_req <= 1'b0;				// held until the next frame, so the game sees it
	if (rx_valid)
		case (rx_data)
			"u": begin usb_want <= 1'b1; usb_dir <= 2'd0; end
			"l": begin usb_want <= 1'b1; usb_dir <= 2'd1; end
			"d": begin usb_want <= 1'b1; usb_dir <= 2'd2; end
			"r": begin usb_want <= 1'b1; usb_dir <= 2'd3; end
			"s": usb_start_req <= 1'b1;
			"p": paused <= ~paused;
			"i": invincible <= ~invincible;
			"m": muted <= ~muted;
			default: ;
		endcase
end
initial begin paused = 1'b0; invincible = 1'b0; muted = 1'b0; usb_start_req = 1'b0; usb_dir = 2'd1; end

// the stick: one direction at a time (up, left, down, right first)
wire				stick = btn[5] | btn[7] | btn[4] | btn[6];
wire	[1:0]		stick_dir = btn[5] ? 2'd0 : btn[7] ? 2'd1 : btn[4] ? 2'd2 : 2'd3;

// ---- the game
wire	[9:0]		rb_addr;
wire	[1:0]		rb_q, pac_dir, pac_mouth;
wire	[7:0]		pac_x, pac_y, level_bcd, frame, g_dir;
wire	[3:0]		death_phase, g_fright, lives;
wire				dying_anim, pac_show, ghosts_show, fright_flash, show_ready, show_gameover, show_push, maze_white;
wire	[31:0]	g_x, g_y;
wire	[11:0]	g_state;
wire	[23:0]	score, hiscore;
wire				snd_dot, snd_power, snd_ghost, snd_death, snd_intro, fright_on;

pac_logic game(.clk(clk_25), .rst_n(locked), .tick(tick),
	.want_set(stick | usb_want), .want_dir(stick ? stick_dir : usb_dir),
	.start(btn[3] | key_s[0] | usb_start_req), .invincible(invincible), .pause(paused),
	.rb_addr(rb_addr), .rb_q(rb_q),
	.pac_x(pac_x), .pac_y(pac_y), .pac_dir(pac_dir), .pac_mouth(pac_mouth), .death_phase(death_phase),
	.dying_anim(dying_anim), .pac_show(pac_show), .g_x(g_x), .g_y(g_y), .g_dir(g_dir), .g_state(g_state),
	.g_fright(g_fright), .ghosts_show(ghosts_show), .fright_flash(fright_flash), .score(score), .hiscore(hiscore),
	.lives(lives), .level_bcd(level_bcd), .show_ready(show_ready), .show_gameover(show_gameover),
	.show_push(show_push), .maze_white(maze_white), .frame(frame),
	.snd_dot(snd_dot), .snd_power(snd_power), .snd_ghost(snd_ghost), .snd_death(snd_death), .snd_intro(snd_intro),
	.fright_on(fright_on));

pac_draw draw(.clk(clk_25), .pxl_x(pxl_x), .pxl_y(pxl_y), .rb_addr(rb_addr), .rb_q(rb_q),
	.pac_x(pac_x), .pac_y(pac_y), .pac_dir(pac_dir), .pac_mouth(pac_mouth), .death_phase(death_phase),
	.dying_anim(dying_anim), .pac_show(pac_show), .g_x(g_x), .g_y(g_y), .g_dir(g_dir), .g_state(g_state),
	.g_fright(g_fright), .ghosts_show(ghosts_show), .fright_flash(fright_flash), .score(score), .hiscore(hiscore),
	.lives(lives), .level_bcd(level_bcd), .show_ready(show_ready), .show_gameover(show_gameover),
	.show_push(show_push), .maze_white(maze_white), .frame(frame), .rgb(rgb));

// ---- sound, LEDs, 7-segment
wire				buzz;
pac_sound sound(.clk(clk_25), .tick(tick), .mute(muted), .snd_dot(snd_dot), .snd_power(snd_power),
	.snd_ghost(snd_ghost), .snd_death(snd_death), .snd_intro(snd_intro), .buzz(buzz));
assign ARDUINO_IO = {2'b00, fright_on, buzz, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

wire	[3:0]		spare = (lives == 0) ? 4'd0 : (lives > 4'd6) ? 4'd5 : lives - 1'b1;
assign LEDR = {invincible, paused, 3'b000, 5'(6'b1 << spare) - 5'd1};		// one LED per spare life

wire	[7:0]		seg [0:5];
genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : digits
		wire [7:0] s;
		seven_segment dec(.in_hex(score[4*gi +: 4]), .out_to_ss(s));
		assign seg[gi] = (gi > 1 && score[23:4*gi] == 0) ? 8'hFF : s;		// blank leading zeros
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

// ---- USB: the debug link (status '?', screen 'F') on the JTAG UART; our letters are read from the same stream
wire	[7:0]		tx_data;
wire				tx_valid, tx_ready;
debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(btn), .key_pressed(key_s), .SW(SW), .wheel(wheel), .frame({8'd0, frame}),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule
