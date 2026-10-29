// Space Invaders on the DE10-Lite with the LCD / game-pad shield
//
// Play: the joystick moves the cannon, A (or B) fires, Select or KEY1 puts in a coin, Start or KEY0 starts.
// Switches (the arcade's DIP switches), read as a game starts: SW[1:0] ships = 3 + SW[1:0]; SW[2] up = extra ship
// at 1000, not 1500. The presets ignore them (3 ships, 1500), so the board and the simulation draw the same frames.
// Sound on the shield's buzzer; the shield's status LED lights while the saucer flies.
// 7-segment: HEX3..HEX0 the score, HEX5..HEX4 the credits. LEDs: one per spare ship; LEDR7 fast-forward,
// LEDR8 paused, LEDR9 invincible.
// Over USB (scripts/de10.py send): l / r move, a fires, c coin, s start, p pause, i invincible, m mute,
// 0..9 run a preset (a reset, then a fast-forward to a known moment, then a pause); '?' status and 'F' screen
// capture come from lib debug_link (scripts/de10.py screen).
// ***********************************************
`default_nettype none

module invaders_top (
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

// ---- reset: the game starts (and fills its memories) only once the PLL is locked
logic	[1:0]		rst_s;
always @(posedge clk_25 or negedge locked)
	if (!locked) rst_s <= 2'b00;
	else         rst_s <= {rst_s[0], 1'b1};
wire				rst_n = rst_s[1];

// ---- game pad (50 MHz, the ADC needs it), debounced, then into the 25 MHz game domain
wire	[11:0]	a0, a1, a2, a3, a4, wheel;
wire				A, B, Select, Start, Right, Left, Up, Down;
gamepad pad(.clk(clk_50), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));
wire	[7:0]		btn50;
debounce #(.N(8), .STEADY(250_000)) deb(.clk(clk_50), .in({Left, Right, Up, Down, Start, Select, B, A}), .out(btn50));
logic	[7:0]		btn_m, btn;			// {Left, Right, Up, Down, Start, Select, B, A}
logic	[1:0]		key_m, key_s;
logic	[2:0]		sw_m, sw_s;			// the switches move at any time: two flip-flops, like the keys
always @(posedge clk_25) begin
	btn_m <= btn50; btn <= btn_m;
	key_m <= ~KEY;  key_s <= key_m;
	sw_m  <= SW[2:0]; sw_s <= sw_m;
end

// ---- frame tick: the start of vertical sync, inside the blanking time
logic				vs_d;
always @(posedge clk_25) vs_d <= VGA_VS;
wire				tick = vs_d && !VGA_VS;
logic	[15:0]	frame_n;
always @(posedge clk_25) if (tick) frame_n <= frame_n + 16'd1;

// ---- commands over USB: l r a c s p i m, 0..9; each "press" is held for a few frames so the game sees it
wire	[7:0]		rx_data;
wire				rx_valid;
logic	[4:0]		u_left, u_right;		// frames still held
logic	[1:0]		u_fire, u_coin, u_start;
logic				u_pause, u_preset, invincible, muted;
logic	[3:0]		u_num;
always @(posedge clk_25) begin
	u_pause <= 1'b0; u_preset <= 1'b0;
	if (tick) begin
		if (u_left  != 5'd0) u_left  <= u_left  - 5'd1;
		if (u_right != 5'd0) u_right <= u_right - 5'd1;
		if (u_fire  != 2'd0) u_fire  <= u_fire  - 2'd1;
		if (u_coin  != 2'd0) u_coin  <= u_coin  - 2'd1;
		if (u_start != 2'd0) u_start <= u_start - 2'd1;
	end
	if (rx_valid)
		case (rx_data)
			"l": begin u_left <= 5'd16; u_right <= 5'd0; end
			"r": begin u_right <= 5'd16; u_left <= 5'd0; end
			"a": u_fire <= 2'd3;
			"c": u_coin <= 2'd2;
			"s": u_start <= 2'd2;
			"p": u_pause <= 1'b1;
			"i": invincible <= ~invincible;
			"m": muted <= ~muted;
			"0", "1", "2", "3", "4", "5", "6", "7", "8", "9": begin u_preset <= 1'b1; u_num <= rx_data[3:0]; end
			default: ;
		endcase
end
initial begin
	u_left = 5'd0; u_right = 5'd0; u_fire = 2'd0; u_coin = 2'd0; u_start = 2'd0;
	u_pause = 1'b0; u_preset = 1'b0; invincible = 1'b0; muted = 1'b0; u_num = 4'd0; frame_n = 16'd0;
end

// ---- the game
wire	[9:0]		tb_addr;
wire	[7:0]		tb_q, sb_addr;
wire	[15:0]	sb_q;
wire				rack_on, old_frame, new_frame, fill, aexp_on, pl_on;
wire	[7:0]		old_x, old_y, new_x, new_y, aexp_x, aexp_y, pl_x, sh_x, sh_y, sc_x;
wire	[5:0]		cursor, bm_st, bm_frame;
wire	[54:0]	alive;
wire	[1:0]		pl_img, sh_st, sc_st, march_note;
wire	[23:0]	bm_x, bm_y;
wire	[11:0]	sc_score;
wire	[223:0]	ground;
wire	[15:0]	score;
wire	[7:0]		credits;
wire	[3:0]		lives;
wire				in_game, ffwd, paused;
wire				snd_die, snd_ufo_hit, snd_extra, snd_hit, snd_shot, snd_march, snd_ufo;

inv_logic game(.clk(clk_25), .rst_n(rst_n), .tick(tick),
	.in_left(btn[7] | (u_left != 5'd0)), .in_right(btn[6] | (u_right != 5'd0)),
	.in_fire(btn[0] | btn[1] | (u_fire != 2'd0)), .in_coin(btn[2] | key_s[1] | (u_coin != 2'd0)),
	.in_start(btn[3] | key_s[0] | (u_start != 2'd0)), .invincible(invincible), .pause_tgl(u_pause),
	.dip_ships(sw_s[1:0]), .dip_bonus(sw_s[2]), .preset_go(u_preset), .preset_num(u_num),
	.tb_addr(tb_addr), .tb_q(tb_q), .sb_addr(sb_addr), .sb_q(sb_q),
	.rack_on(rack_on), .old_x(old_x), .old_y(old_y), .new_x(new_x), .new_y(new_y), .old_frame(old_frame),
	.new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive),
	.aexp_on(aexp_on), .aexp_x(aexp_x), .aexp_y(aexp_y), .pl_on(pl_on), .pl_img(pl_img), .pl_x(pl_x),
	.sh_st(sh_st), .sh_x(sh_x), .sh_y(sh_y), .bm_st(bm_st), .bm_x(bm_x), .bm_y(bm_y), .bm_frame(bm_frame),
	.sc_st(sc_st), .sc_x(sc_x), .sc_score(sc_score), .ground(ground),
	.score(score), .hiscore(), .credits(credits), .lives(lives), .in_game(in_game), .ffwd(ffwd), .paused(paused),
	.busy(), .snd_die(snd_die), .snd_ufo_hit(snd_ufo_hit), .snd_extra(snd_extra), .snd_hit(snd_hit),
	.snd_shot(snd_shot), .snd_march(snd_march), .march_note(march_note), .snd_ufo(snd_ufo));

inv_draw draw(.clk(clk_25), .pxl_x(pxl_x), .pxl_y(pxl_y), .tb_addr(tb_addr), .tb_q(tb_q), .sb_addr(sb_addr), .sb_q(sb_q),
	.rack_on(rack_on), .old_x(old_x), .old_y(old_y), .new_x(new_x), .new_y(new_y), .old_frame(old_frame),
	.new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive),
	.aexp_on(aexp_on), .aexp_x(aexp_x), .aexp_y(aexp_y), .pl_on(pl_on), .pl_img(pl_img), .pl_x(pl_x),
	.sh_st(sh_st), .sh_x(sh_x), .sh_y(sh_y), .bm_st(bm_st), .bm_x(bm_x), .bm_y(bm_y), .bm_frame(bm_frame),
	.sc_st(sc_st), .sc_x(sc_x), .sc_score(sc_score), .ground(ground), .rgb(rgb));

// ---- sound, LEDs, 7-segment
wire				buzz;
inv_sound sound(.clk(clk_25), .tick(tick), .mute(muted | ffwd | paused), .snd_die(snd_die),
	.snd_ufo_hit(snd_ufo_hit), .snd_extra(snd_extra), .snd_hit(snd_hit), .snd_shot(snd_shot),
	.snd_march(snd_march), .march_note(march_note), .snd_ufo(snd_ufo), .buzz(buzz));
assign ARDUINO_IO = {2'b00, sc_st != 2'd0, buzz, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

wire	[3:0]		spare = (!in_game || lives == 4'd0) ? 4'd0 : (lives > 4'd7) ? 4'd6 : lives - 4'd1;
wire	[7:0]		spare_leds = (8'd1 << spare) - 8'd1;					// one LED per spare ship
assign LEDR = {invincible, paused, ffwd, spare_leds[6:0]};

wire	[23:0]	shown = {credits, score};
wire	[7:0]		seg [0:5];
genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : digits
		seven_segment dec(.in_hex(shown[4*gi +: 4]), .out_to_ss(seg[gi]));
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

// ---- USB: the debug link (status '?', screen 'F') on the JTAG UART; our letters are read from the same stream
wire	[7:0]		tx_data;
wire				tx_valid, tx_ready;
debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(btn), .key_pressed(key_s), .SW(SW), .wheel(wheel), .frame(frame_n),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule
