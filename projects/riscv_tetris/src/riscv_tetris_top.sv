// RISC-V Tetris on the DE10-Lite with the LCD / game-pad shield: the RV32I SoC, the 80 x 60 text screen, the pad,
// the buzzer, the 7-segment digits, and the USB link.
//
// Over USB (scripts/de10.py send): letters press a key for 6 frames: a b e(Select) s(Start) u d l r, and KEY0 = k;
// 'H' holds the CPU in reset (while tools/load.py writes a new program into the RAM over JTAG), 'R' resets and runs.
// '?' and 'F' are the lib debug link (status, screen capture). The program's UART output shares the link.
// ***********************************************
`default_nettype none

module riscv_tetris_top (
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

// ---- game pad (50 MHz), debounced, into the 25 MHz domain
wire	[11:0]	a0, a1, a2, a3, a4, wheel;
wire				A, B, Select, Start, Right, Left, Up, Down;
gamepad pad(.clk(clk_50), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));
wire	[7:0]		btn50;
debounce #(.N(8), .STEADY(250_000)) deb(.clk(clk_50), .in({Left, Right, Up, Down, Start, Select, B, A}), .out(btn50));
logic	[7:0]		btn_m, btn;
logic	[1:0]		key_m, key_s;
always @(posedge clk_25) begin
	btn_m <= btn50; btn <= btn_m;
	key_m <= ~KEY;  key_s <= key_m;
end

// ---- frame tick
logic				vs_d;
always @(posedge clk_25) vs_d <= VGA_VS;
wire				tick = vs_d && !VGA_VS;

// ---- USB letters: key presses held for 6 frames, CPU hold / reset
wire	[7:0]		rx_data;
wire				rx_valid;
logic	[2:0]		hold [0:8];				// frames left for each injected key (bit 8 = KEY0)
logic	[8:0]		usb_keys;
logic				cpu_hold, cpu_reset_req;
logic	[4:0]		reset_cnt;
initial begin cpu_hold = 1'b0; cpu_reset_req = 1'b0; reset_cnt = 5'd0; for (int i = 0; i < 9; i++) hold[i] = 3'd0; end

function automatic integer key_of(input [7:0] ch);
	case (ch)
		"a": key_of = 0; "b": key_of = 1; "e": key_of = 2; "s": key_of = 3;
		"d": key_of = 4; "u": key_of = 5; "r": key_of = 6; "l": key_of = 7; "k": key_of = 8;
		default: key_of = -1;
	endcase
endfunction

always @(posedge clk_25) begin
	cpu_reset_req <= 1'b0;
	for (int i = 0; i < 9; i++) begin
		if (tick && hold[i] != 0) hold[i] <= hold[i] - 1'b1;
		usb_keys[i] <= (hold[i] != 0);
	end
	if (rx_valid) begin
		if (rx_data == "H") cpu_hold <= 1'b1;
		else if (rx_data == "R") begin cpu_hold <= 1'b0; cpu_reset_req <= 1'b1; end
		else if (key_of(rx_data) >= 0) hold[key_of(rx_data)] <= 3'd6;
	end
	if (cpu_reset_req) reset_cnt <= 5'd31;
	else if (reset_cnt != 0) reset_cnt <= reset_cnt - 1'b1;
end

// CPU reset: the PLL lock, a USB hold, a USB reset pulse; deasserted synchronously through two flip-flops
logic	[1:0]		rst_sync;
wire				rst_cond = locked && !cpu_hold && reset_cnt == 0;
always @(posedge clk_25 or negedge locked)
	if (!locked) rst_sync <= 2'b00;
	else rst_sync <= {rst_sync[0], rst_cond};
wire				soc_rst_n = rst_sync[1];

// ---- the SoC
wire	[9:0]		buttons = {key_s[1], key_s[0] | usb_keys[8], btn | usb_keys[7:0]};
wire	[12:0]	text_addr;
wire	[15:0]	text_q;
wire	[23:0]	hex;
wire	[9:0]		leds;
wire	[15:0]	buzzer_half;
wire	[7:0]		u_data;
wire				u_valid, u_ready, exit_valid, halted, fault;
wire	[31:0]	exit_code;

rv32_soc #(.RAM_IMPL("IP"), .PROG_FILE("assets/tetris.mif")) soc(
	.clk(clk_25), .rst_n(soc_rst_n), .tick(tick), .buttons(buttons), .switches(SW),
	.text_addr(text_addr), .text_q(text_q), .hex(hex), .leds(leds), .buzzer_half(buzzer_half),
	.tx_data(u_data), .tx_valid(u_valid), .tx_ready(u_ready),
	.exit_valid(exit_valid), .exit_code(exit_code), .halted(halted), .fault(fault),
	.trace_valid(), .trace_pc(), .trace_rd(), .trace_data(), .bus_write(), .bus_addr_o(), .bus_wdata_o(), .bus_be_o());

text_screen screen(.clk(clk_25), .pxl_x(pxl_x), .pxl_y(pxl_y), .text_addr(text_addr), .text_q(text_q), .rgb(rgb));

// ---- buzzer: a square wave with the half period the program sets
logic	[15:0]	tone_cnt;
logic				buzz;
initial begin tone_cnt = 16'd0; buzz = 1'b0; end
always @(posedge clk_25)
	if (buzzer_half == 16'd0) begin tone_cnt <= 16'd0; buzz <= 1'b0; end
	else if (tone_cnt >= buzzer_half) begin tone_cnt <= 16'd0; buzz <= ~buzz; end
	else tone_cnt <= tone_cnt + 1'b1;
assign ARDUINO_IO = {2'b00, halted | fault, buzz, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// ---- LEDs and 7-segment: the program's values; LEDR9 blinks while the CPU is held or halted
assign LEDR = {(cpu_hold | halted) & pxl_y[8], leds[8:0]};
wire	[7:0]		seg [0:5];
genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : digits
		seven_segment dec(.in_hex(hex[4*gi +: 4]), .out_to_ss(seg[gi]));
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

// ---- USB: the program's UART and the debug link share the JTAG UART through tx_mux
wire	[7:0]		d_data, tx_data;
wire				d_valid, d_ready, tx_valid, tx_ready;
debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(btn), .key_pressed(key_s), .SW(SW), .wheel(wheel), .frame({15'd0, exit_valid}),
	.tx_data(d_data), .tx_valid(d_valid), .tx_ready(d_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
tx_mux mux(.clk(clk_25), .a_data(u_data), .a_valid(u_valid), .a_ready(u_ready),
	.b_data(d_data), .b_valid(d_valid), .b_ready(d_ready), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule
