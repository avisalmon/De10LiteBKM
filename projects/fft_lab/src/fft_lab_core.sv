// FFT lab, everything but the board: controls, engine (wave -> both FFTs -> bars), digits, screen, report
//
// One clock (25 MHz, the pixel clock). tick = one frame (start of vertical sync): the engine makes the next
// frame and publishes it inside the blanking time, unless hold is on. The testbench (sim/tb_fft_lab.sv) drives
// this module directly; fft_lab_top adds the PLL, the screens, the game pad, the USB link, LEDs and 7-segment.
// ***********************************************
`default_nettype none

module fft_lab_core #(
	parameter TWIDDLE_FILE = "assets/twiddle.hex",
	parameter SINE_FILE = "assets/sine.hex",
	parameter HANN_FILE = "assets/hann.hex",
	parameter MAG_FILE = "assets/mag_rom.bin",
	parameter WATCHDOG = 20000,
	parameter [10:0] IP_RESET_CLOCKS = 11'd1000,
	parameter WHEEL_DIV = 25000,
	parameter SETTLE = 512
)(
	input		wire				clk,
	input		wire				rst_hold,		// the PLL is not locked yet
	input		wire				tick,
	input		wire	[31:0]	pxl_x,
	input		wire	[31:0]	pxl_y,
	input		wire	[7:0]		btn,				// {Left, Right, Up, Down, Start, Select, B, A}, pressed = 1
	input		wire	[1:0]		key,				// pressed = 1
	input		wire	[11:0]	wheel,
	input		wire	[7:0]		rx_data,
	input		wire				rx_valid,
	output	wire	[7:0]		p_data,			// the report line, to tx_mux
	output	wire				p_valid,
	input		wire				p_ready,
	output	wire	[11:0]	rgb,
	output	wire	[9:0]		leds,
	output	wire	[47:0]	hex,				// {HEX5, ..., HEX0}, active low
	output	wire				buzz,
	output	wire				status_led
	);

// ---- the controls
wire	[2:0]		shape;
wire	[9:0]		fq;
wire				win, lin, hold, sound, ip_restart, report;
wire				follow;							// the wheel sets the frequency: for the testbench only
lab_ctrl #(.WHEEL_DIV(WHEEL_DIV), .SETTLE(SETTLE)) ctrl(
	.clk(clk), .tick(tick), .btn(btn), .key(key), .wheel(wheel), .rx_data(rx_data), .rx_valid(rx_valid),
	.shape(shape), .fq(fq), .win(win), .lin(lin), .hold(hold), .sound(sound), .follow(follow),
	.ip_restart(ip_restart), .report(report));

// ---- the engine
wire				sc_we, bd_we, bi_we;
wire	[7:0]		sc_addr;
wire	[13:0]	sc_d;
wire	[6:0]		bd_addr, bd_d, bi_addr, bi_d;
wire				pub, r_win, r_lin, r_ip_ok;
wire				r_ip_dead, eng_busy;			// for the testbench only
wire	[2:0]		r_shape;
wire	[9:0]		r_fq;
wire	[16:0]	r_dclk, r_iclk;
wire	[6:0]		r_dpk, r_dpx, r_ipk, r_ipx;
wire signed [5:0]	r_iexp;
lab_engine #(.TWIDDLE_FILE(TWIDDLE_FILE), .SINE_FILE(SINE_FILE), .HANN_FILE(HANN_FILE), .MAG_FILE(MAG_FILE),
	.WATCHDOG(WATCHDOG), .IP_RESET_CLOCKS(IP_RESET_CLOCKS)) eng(
	.clk(clk), .rst_hold(rst_hold), .start(tick && !hold), .shape(shape), .fq(fq), .win(win), .lin(lin),
	.ip_restart(ip_restart),
	.sc_we(sc_we), .sc_addr(sc_addr), .sc_d(sc_d),
	.bd_we(bd_we), .bd_addr(bd_addr), .bd_d(bd_d), .bi_we(bi_we), .bi_addr(bi_addr), .bi_d(bi_d),
	.pub(pub), .r_shape(r_shape), .r_fq(r_fq), .r_win(r_win), .r_lin(r_lin), .r_dclk(r_dclk), .r_iclk(r_iclk),
	.r_dpk(r_dpk), .r_dpx(r_dpx), .r_ipk(r_ipk), .r_ipx(r_ipx), .r_iexp(r_iexp), .r_ip_ok(r_ip_ok),
	.r_ip_dead(r_ip_dead), .busy(eng_busy));

// ---- the numbers as digits
wire	[15:0]	fq_bcd;
wire	[23:0]	hz_bcd, dus_bcd, ius_bcd;
wire	[11:0]	bin_bcd, dpk_bcd, dpx_bcd, ipk_bcd, ipx_bcd;
wire	[19:0]	dclk_bcd, iclk_bcd;
wire	[7:0]		exp_bcd;
wire				dig_busy;
lab_digits dig(.clk(clk), .pub(pub), .fq(r_fq), .dclk(r_dclk), .iclk(r_iclk), .dpk(r_dpk), .dpx(r_dpx),
	.ipk(r_ipk), .ipx(r_ipx), .iexp(r_iexp),
	.fq_bcd(fq_bcd), .hz_bcd(hz_bcd), .bin_bcd(bin_bcd), .dclk_bcd(dclk_bcd), .dus_bcd(dus_bcd),
	.iclk_bcd(iclk_bcd), .ius_bcd(ius_bcd), .dpk_bcd(dpk_bcd), .dpx_bcd(dpx_bcd), .ipk_bcd(ipk_bcd),
	.ipx_bcd(ipx_bcd), .exp_bcd(exp_bcd), .busy(dig_busy));

// ---- the screen
lab_draw draw(.clk(clk), .pxl_x(pxl_x), .pxl_y(pxl_y),
	.sc_we(sc_we), .sc_addr(sc_addr), .sc_d(sc_d),
	.bd_we(bd_we), .bd_addr(bd_addr), .bd_d(bd_d), .bi_we(bi_we), .bi_addr(bi_addr), .bi_d(bi_d),
	.shape(r_shape), .win(r_win), .lin(r_lin), .ip_ok(r_ip_ok), .fq(r_fq), .hold(hold), .sound(sound),
	.hz_bcd(hz_bcd), .bin_bcd(bin_bcd), .dclk_bcd(dclk_bcd), .dus_bcd(dus_bcd), .iclk_bcd(iclk_bcd),
	.ius_bcd(ius_bcd), .rgb(rgb));

// ---- the report line (USB letter R), sent when the digits are complete
function automatic [7:0] dg(input [3:0] d);
	dg = {4'h3, d};
endfunction

wire	[8*126-1:0]	rep_text = {"FFTLAB SHAPE=", dg({1'b0, r_shape}),
	" N=", dg(fq_bcd[15:12]), dg(fq_bcd[11:8]), dg(fq_bcd[7:4]), dg(fq_bcd[3:0]),
	" HZ=", dg(hz_bcd[23:20]), dg(hz_bcd[19:16]), dg(hz_bcd[15:12]), dg(hz_bcd[11:8]), dg(hz_bcd[7:4]),
	".", dg(hz_bcd[3:0]),
	" WIN=", dg({3'd0, r_win}), " LIN=", dg({3'd0, r_lin}), " HOLD=", dg({3'd0, hold}),
	" OUR_CLK=", dg(dclk_bcd[19:16]), dg(dclk_bcd[15:12]), dg(dclk_bcd[11:8]), dg(dclk_bcd[7:4]), dg(dclk_bcd[3:0]),
	" OUR_PK=", dg(dpk_bcd[11:8]), dg(dpk_bcd[7:4]), dg(dpk_bcd[3:0]),
	"/", dg(dpx_bcd[11:8]), dg(dpx_bcd[7:4]), dg(dpx_bcd[3:0]),
	" IP_CLK=", dg(iclk_bcd[19:16]), dg(iclk_bcd[15:12]), dg(iclk_bcd[11:8]), dg(iclk_bcd[7:4]), dg(iclk_bcd[3:0]),
	" IP_PK=", dg(ipk_bcd[11:8]), dg(ipk_bcd[7:4]), dg(ipk_bcd[3:0]),
	"/", dg(ipx_bcd[11:8]), dg(ipx_bcd[7:4]), dg(ipx_bcd[3:0]),
	" IP_EXP=", r_iexp[5] ? "-" : "+", dg(exp_bcd[7:4]), dg(exp_bcd[3:0]),
	" IP_OK=", dg({3'd0, r_ip_ok})};

logic				rep_pend = 1'b0;
wire				prn_busy;
wire				rep_send = rep_pend && !dig_busy && !prn_busy;
always @(posedge clk)
	if (report) rep_pend <= 1'b1;
	else if (rep_send) rep_pend <= 1'b0;

line_printer #(.MAXLEN(126)) prn(.clk(clk), .text(rep_text), .len(7'd126), .send(rep_send), .busy(prn_busy),
	.tx_data(p_data), .tx_valid(p_valid), .tx_ready(p_ready));

// ---- LEDs (live settings), 7-segment (the frame's frequency in Hz), buzzer (a square wave at the live frequency)
assign leds = {sound, hold, lin, win, 6'b000001 << shape};
assign status_led = !r_ip_ok;

genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : digit
		wire [7:0] s;
		seven_segment dec(.in_hex(hz_bcd[4*gi +: 4]), .out_to_ss(s));
		assign hex[8*gi +: 8] = (gi > 1 && hz_bcd[23:4*gi] == 0) ? 8'hFF : (gi == 1) ? (s & 8'h7F) : s;
	end
endgenerate

logic	[31:0]	nco = 32'd0;
always @(posedge clk) nco <= nco + fq * 32'd2147;		// 2^32 x 12.5 Hz / 25 MHz = 2147.5 per step of fq
assign buzz = sound && nco[31];

endmodule

`default_nettype wire
