// Example 03: RAM, single-port and dual-port
//
// Single-port: ram_bist writes and reads back an 8K x 16 RAM nonstop (~3,000 passes a second) and counts errors.
//   HEX5..HEX0 total errors (decimal; must stay 0). SW0 up = inject one wrong bit per pass (errors must climb).
//   USB: once a second "RAM BIST passes=........ errors=........ last=...." (hex).
// Dual-port: a 160x120 frame buffer. Port A (50 MHz) is written by paint.sv; port B (25 MHz) is read by the
//   screen, each pixel shown as a 4x4 block (fills 640x480). Joystick moves the cursor, A paints with the
//   wheel's colour, B erases, Select clears, Start redraws the test picture.
// The screen can be read back over USB ('F', scripts/de10.py screen).
// ***********************************************

module ram_top (
	input						MAX10_CLK1_50,
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
wire	[7:0]		lcd_db;
wire				lcd_reset, lcd_wr, lcd_d_c, lcd_rd;
reg	[11:0]	rgb;

wire			locked;
reg	[1:0]		locked_50 = 0;
pll25 pll(.areset(1'b0), .inclk0(MAX10_CLK1_50), .c0(clk_25), .c1(clk_50), .c2(clk_100), .locked(locked));
always @(posedge clk_50) locked_50 <= {locked_50[0], locked};	// synchronized into the 50 MHz domain

Screens_dispaly screens(
	.clk_25(clk_25), .clk_100(clk_100),
	.Red_level(rgb[11:8]), .Green_level(rgb[7:4]), .Blue_level(rgb[3:0]),
	.pxl_x(pxl_x), .pxl_y(pxl_y),
	.Red(VGA_R), .Green(VGA_G), .Blue(VGA_B), .h_sync(VGA_HS), .v_sync(VGA_VS),
	.lcd_db(lcd_db), .lcd_reset(lcd_reset), .lcd_wr(lcd_wr), .lcd_d_c(lcd_d_c), .lcd_rd(lcd_rd));
assign ARDUINO_IO = {4'b0000, lcd_rd, lcd_d_c, lcd_wr, lcd_reset, lcd_db};

// ---- game pad (50 MHz: the ADC IP needs it)
wire	[11:0]	a0, a1, a2, a3, a4, wheel;
wire				A, B, Select, Start, Right, Left, Up, Down;
gamepad pad(.clk(clk_50), .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),
	.A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));

// ---- dual-port frame buffer: write at 50 MHz, read at 25 MHz
wire	[14:0]	wr_addr;
wire	[11:0]	wr_d, fb_q;
wire				we, filling;
wire	[7:0]		cx;
wire	[6:0]		cy;
paint painter(.clk(clk_50), .ready(locked_50[1]), .A(A), .B(B), .Select(Select), .Start(Start), .Left(Left), .Right(Right),
	.Up(Up), .Down(Down), .wheel(wheel), .wr_addr(wr_addr), .wr_d(wr_d), .we(we), .cx(cx), .cy(cy),
	.filling(filling));

wire	[9:0]		xn = pxl_x[9:0] + 1'b1;		// the RAM answers one clock late: fetch the next pixel
wire	[6:0]		fy = pxl_y[8:2];
wire	[14:0]	rd_addr = fy * 160 + xn[9:2];
ram_dp #(.WIDTH(12), .AW(15), .DEPTH(19200)) fb(
	.wr_clk(clk_50), .wr_addr(wr_addr), .wr_d(wr_d), .we(we),
	.rd_clk(clk_25), .rd_addr(rd_addr), .rd_q(fb_q));

// cursor: a 4x4 outline around the pixel cell, black or white against the picture
wire	[9:0]		sx = {cx, 2'b00};
wire	[8:0]		sy = {cy, 2'b00};
wire				on_cell = pxl_x[9:2] == cx && pxl_y[8:2] == cy;
wire				on_edge = pxl_x[1:0] == 0 || pxl_x[1:0] == 3 || pxl_y[1:0] == 0 || pxl_y[1:0] == 3;
always_comb rgb = (on_cell && on_edge) ? (fb_q[7] ? 12'h000 : 12'hFFF) : fb_q;

// ---- single-port RAM self-test (50 MHz)
wire	[31:0]	passes, errors;
wire	[15:0]	last_errors;
wire				pass_done;
ram_bist bist(.clk(clk_50), .inject(SW[0]), .passes(passes), .errors(errors),
	.last_errors(last_errors), .pass_done(pass_done));

wire	[23:0]	err_bcd;
bin2bcd #(.BITS(20), .DIGITS(6)) err_dec(.bin(errors > 999999 ? 20'd999999 : errors[19:0]), .bcd(err_bcd));
wire	[7:0]		seg [0:5];
genvar g;
generate
	for (g = 0; g < 6; g = g + 1) begin : digits
		wire [7:0] s;
		seven_segment dec(.in_hex(err_bcd[4*g +: 4]), .out_to_ss(s));
		assign seg[g] = (g > 0 && err_bcd[23:4*g] == 0) ? 8'hFF : s;
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

reg	[24:0]	alive = 0;
always @(posedge clk_25) alive <= alive + 1'b1;
assign LEDR = {errors != 0, filling, 6'b0, alive[24], SW[0]};

// ---- USB: BIST report once a second (50 MHz) + screen read-back (25 MHz), one JTAG UART at 25 MHz
function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction

reg	[25:0]	tick = 0;
reg				report = 0;
always @(posedge clk_50) begin
	tick <= (tick == 49_999_999) ? 26'd0 : tick + 1'b1;
	report <= (tick == 0);
end
// report crosses to 25 MHz: stretch it (2 clocks at 50 MHz = 1 clock at 25 MHz, same PLL) and snapshot the counters
reg	[1:0]		report_s = 0;
reg	[31:0]	p_q, e_q;
reg	[15:0]	l_q;
reg				send = 0;
always @(posedge clk_50) if (tick == 49_999_990) begin p_q <= passes; e_q <= errors; l_q <= last_errors; end
always @(posedge clk_25) begin
	report_s <= {report_s[0], tick < 26'd8};
	send <= report_s == 2'b01;
end

wire [8*56-1:0] text = {"RAM BIST passes=",
	hx(p_q[31:28]), hx(p_q[27:24]), hx(p_q[23:20]), hx(p_q[19:16]), hx(p_q[15:12]), hx(p_q[11:8]), hx(p_q[7:4]), hx(p_q[3:0]),
	" errors=", hx(e_q[31:28]), hx(e_q[27:24]), hx(e_q[23:20]), hx(e_q[19:16]), hx(e_q[15:12]), hx(e_q[11:8]), hx(e_q[7:4]), hx(e_q[3:0]),
	" last=", hx(l_q[15:12]), hx(l_q[11:8]), hx(l_q[7:4]), hx(l_q[3:0]), {6{8'h20}}};	// 50 chars + padding to 56

wire	[7:0]		p_data, d_data, tx_data, rx_data;
wire				p_valid, p_ready, d_valid, d_ready, tx_valid, tx_ready, rx_valid;

line_printer #(.MAXLEN(56)) printer(.clk(clk_25), .text(text), .len(7'd50), .send(send), .busy(),
	.tx_data(p_data), .tx_valid(p_valid), .tx_ready(p_ready));

debug_link #(.STEP(2)) debug(
	.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
	.buttons(8'h00), .key_pressed(2'b00), .SW(10'h000), .wheel(12'h000), .frame(16'h0000),
	.tx_data(d_data), .tx_valid(d_valid), .tx_ready(d_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());

tx_mux mux(.clk(clk_25), .a_data(p_data), .a_valid(p_valid), .a_ready(p_ready),
	.b_data(d_data), .b_valid(d_valid), .b_ready(d_ready),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

endmodule
