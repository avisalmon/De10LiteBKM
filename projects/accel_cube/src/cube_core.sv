// The accelerometer cube without the pins: the two live vectors (the filtered gravity for the cube, the raw
// sample for the arrow and the numbers, in the board frame the HEADING parameter chooses, minus the
// calibration offsets), the eight test presets, the controls (USB letters, KEYs), the per-frame math engine,
// the pixel pipeline, the report line, the LEDs and the 7-segment digits. Everything here runs at the
// 25 MHz pixel clock.
//
// Controls: USB '0'..'7' show test preset n (the pictures assets/model.py renders), 'l' back to the live
// sensor, 'c' calibrates (take the current filtered reading as flat: the board must lie still and level),
// 'u' forgets the calibration, 's' toggles the slow spin of the view, 'k' restarts the peak, 'r' sends the
// report line; KEY0 restarts the peak (and clears the "late" LED), KEY1 calibrates. Calibrating also
// leaves test mode and restarts the peak. The offsets live in registers only: a power cycle forgets them.
// ***********************************************
`default_nettype none

module cube_core #(
	parameter HEADING = 0			// which way the board's +x points on the screen: 0, 90, 180 or 270
)(
	input		wire						clk,				// 25 MHz
	input		wire						rst,
	input		wire						tick,				// frame tick, inside the vertical blanking
	input		wire	[31:0]			pxl_x,
	input		wire	[31:0]			pxl_y,
	input		wire	signed	[15:0]	acc_x,			// ADXL345 samples, 1 g = 256, already in this clock domain
	input		wire	signed	[15:0]	acc_y,
	input		wire	signed	[15:0]	acc_z,
	input		wire						acc_valid,		// one clock per sample (100 Hz)
	input		wire	[7:0]				devid,
	input		wire	[1:0]				key,				// synchronised, 1 = pressed: 0 peak restart, 1 calibrate
	input		wire	[7:0]				rx_data,			// letters from the PC
	input		wire						rx_valid,
	output	wire	[7:0]				p_data,			// the report line, to tx_mux
	output	wire						p_valid,
	input		wire						p_ready,
	output	wire	[11:0]			rgb,
	output	logic	[9:0]				leds,
	output	wire	[47:0]			hex,				// {HEX5, ..., HEX0}
	output	logic						status_led		// the math engine was late for a frame (KEY0 clears)
	);

localparam signed [15:0] VIEW_YAW = 16'sd5461, SPIN_STEP = 16'sd91;	// model.py constants (BAM16)
localparam [7:0] ADXL_ID = 8'hE5;

function automatic [7:0] dg(input [3:0] d);
	dg = 8'h30 + {4'b0, d};
endfunction
function automatic signed [15:0] sat16(input signed [20:0] v);	// Q4 counts never beyond +-8 g
	sat16 = (v > 21'sd32767) ? 16'sd32767 : (v < -21'sd32768) ? 16'sh8000 : v[15:0];
endfunction
// the board frame: which way the board's +x points on the screen (HEADING), applied to both vectors
function automatic signed [15:0] head_x(input signed [15:0] x, input signed [15:0] y);
	head_x = (HEADING == 90) ? -y : (HEADING == 180) ? -x : (HEADING == 270) ? y : x;
endfunction
function automatic signed [15:0] head_y(input signed [15:0] x, input signed [15:0] y);
	head_y = (HEADING == 90) ? x : (HEADING == 180) ? -y : (HEADING == 270) ? -x : y;
endfunction

// ---- the filtered acceleration: an exponential average (1/8 per sample) in raw counts x 256
logic	signed	[23:0]	fx, fy, fz;
wire	signed	[23:0]	ex = $signed({acc_x, 8'b0}) - fx;
wire	signed	[23:0]	ey = $signed({acc_y, 8'b0}) - fy;
wire	signed	[23:0]	ez = $signed({acc_z, 8'b0}) - fz;
wire	signed	[23:0]	ex8 = ex >>> 3, ey8 = ey >>> 3, ez8 = ez >>> 3;
always_ff @(posedge clk) begin
	if (rst) begin
		fx <= 24'sd0; fy <= 24'sd0; fz <= 24'sd0;
	end
	else if (acc_valid) begin
		fx <= fx + ex8; fy <= fy + ey8; fz <= fz + ez8;
	end
end
// rounding to Q4 hides the filter's dead zone: with a constant input fx settles within 7 of acc x 256
wire	signed	[23:0]	fxr = fx + 24'sd8, fyr = fy + 24'sd8, fzr = fz + 24'sd8;
wire	signed	[19:0]	fxq = fxr[23:4], fyq = fyr[23:4], fzq = fzr[23:4];	// Q4 counts (1 g = 4096)

// ---- the two live vectors, both minus the calibration offsets (taken in the sensor frame, see below):
// g = the filtered reading, the direction of gravity (the cube, pitch, roll, the LED bubble);
// a = the latest raw sample, what the board feels right now, shakes included (the arrow, bars, numbers)
logic	signed	[19:0]	ox, oy, oz;
wire	signed	[20:0]	gx21 = {fxq[19], fxq} - {ox[19], ox};
wire	signed	[20:0]	gy21 = {fyq[19], fyq} - {oy[19], oy};
wire	signed	[20:0]	gz21 = {fzq[19], fzq} - {oz[19], oz};
wire	signed	[20:0]	ax21 = {acc_x[15], acc_x, 4'b0} - {ox[19], ox};
wire	signed	[20:0]	ay21 = {acc_y[15], acc_y, 4'b0} - {oy[19], oy};
wire	signed	[20:0]	az21 = {acc_z[15], acc_z, 4'b0} - {oz[19], oz};
wire	signed	[15:0]	gxs = sat16(gx21), gys = sat16(gy21), gzs = sat16(gz21);
wire	signed	[15:0]	axs = sat16(ax21), ays = sat16(ay21), azs = sat16(az21);

// ---- the test presets (model.py PRESETS): {ax, ay, az} in Q4 counts
function automatic [47:0] preset(input [2:0] n);
	case (n)
		3'd0: preset = {16'sd0, 16'sd0, 16'sd4096};
		3'd1: preset = {-16'sd2048, 16'sd0, 16'sd3547};
		3'd2: preset = {16'sd0, 16'sd2048, 16'sd3547};
		3'd3: preset = {16'sd0, 16'sd0, -16'sd4096};
		3'd4: preset = {16'sd4096, 16'sd0, 16'sd0};
		3'd5: preset = {16'sd2365, 16'sd2365, 16'sd2365};
		3'd6: preset = {16'sd4800, -16'sd3200, 16'sd6400};
		default: preset = {16'sd0, 16'sd200, 16'sd300};
	endcase
endfunction

// ---- controls
logic				test, cal, spin_on, peak_clr, want_report, late;
logic	[2:0]		test_n;
logic	[1:0]		key_d;
logic	signed	[15:0]	spin;
wire				busy, done_nc;
wire	[1:0]		key_rise = key & ~key_d;
wire				is_digit = rx_valid && (rx_data >= "0") && (rx_data <= "7");
wire				is_live = rx_valid && (rx_data == "l" || rx_data == "L");
wire				is_cal = rx_valid && (rx_data == "c" || rx_data == "C");
wire				is_uncal = rx_valid && (rx_data == "u" || rx_data == "U");
wire				is_spin = rx_valid && (rx_data == "s" || rx_data == "S");
wire				is_peak = rx_valid && (rx_data == "k" || rx_data == "K");
wire				is_report = rx_valid && (rx_data == "r" || rx_data == "R");
wire				do_cal = is_cal || key_rise[1];
wire				p_busy, rep_send;
wire	[47:0]	pre = preset(test_n);
wire	signed	[15:0]	gx = test ? $signed(pre[47:32]) : head_x(gxs, gys);
wire	signed	[15:0]	gy = test ? $signed(pre[31:16]) : head_y(gxs, gys);
wire	signed	[15:0]	gz = test ? $signed(pre[15:0]) : gzs;
wire	signed	[15:0]	ax = test ? $signed(pre[47:32]) : head_x(axs, ays);
wire	signed	[15:0]	ay = test ? $signed(pre[31:16]) : head_y(axs, ays);
wire	signed	[15:0]	az = test ? $signed(pre[15:0]) : azs;
wire	signed	[15:0]	psi = test ? VIEW_YAW : spin;
wire	[1:0]		mode = test ? 2'd2 : {1'b0, cal};

always_ff @(posedge clk) begin
	key_d <= key;
	if (rst) begin
		test <= 1'b0; test_n <= 3'd0; cal <= 1'b0; spin_on <= 1'b0; peak_clr <= 1'b1; want_report <= 1'b0;
		late <= 1'b0; spin <= VIEW_YAW;
		ox <= 20'sd0; oy <= 20'sd0; oz <= 20'sd0;
	end
	else begin
		if (is_digit) begin
			test <= 1'b1;
			test_n <= rx_data[2:0];
		end
		else if (is_live || do_cal)
			test <= 1'b0;
		if (do_cal) begin													// the board lies flat: it reads (0, 0, 1 g) now
			ox <= fxq; oy <= fyq; oz <= fzq - 20'sd4096;
			cal <= 1'b1;
		end
		else if (is_uncal) begin
			ox <= 20'sd0; oy <= 20'sd0; oz <= 20'sd0;
			cal <= 1'b0;
		end
		if (is_digit || is_peak || do_cal || key_rise[0])
			peak_clr <= 1'b1;
		else if (tick && !busy)
			peak_clr <= 1'b0;												// the engine took it at this tick
		if (is_report)
			want_report <= 1'b1;
		else if (rep_send)
			want_report <= 1'b0;
		if (is_spin)
			spin_on <= ~spin_on;
		if (tick)
			spin <= spin_on ? spin + SPIN_STEP : VIEW_YAW;
		if (key_rise[0])
			late <= 1'b0;
		else if (busy && (tick || (pxl_x == 32'd0 && pxl_y == 32'd0)))
			late <= 1'b1;
	end
end
assign status_led = late;

// ---- the frame: math in the blanking, pixels as the screen scans
wire	[2:0]				slot_valid;
wire	[2:0][11:0]		slot_rgb;
wire	[11:0][15:0]	e_dx, e_dy;
wire	[11:0][31:0]	e_c;
wire	[11:0][23:0]	e_t;
wire	[7:0]				sg_valid, sg_dash;
wire	[7:0][11:0]		sg_rgb;
wire	[7:0][17:0]		sg_dx, sg_dy;
wire	[7:0][31:0]		sg_c;
wire	[7:0][23:0]		sg_t;
wire	[7:0][9:0]		sg_xmin, sg_xmax, sg_ymin, sg_ymax;
wire	[6:0][15:0]		bcd4;
wire	[2:0][19:0]		bcd5;
wire	[4:0]				neg;
wire	[2:0][9:0]		bar_len;
wire	[2:0]				bar_neg;
wire	[15:0]			mag_nc;
wire	[8*114-1:0]		report;

cube_math math (
	.clk(clk), .rst(rst), .start(tick), .gx(gx), .gy(gy), .gz(gz), .ax(ax), .ay(ay), .az(az), .psi(psi),
	.peak_clr(peak_clr), .busy(busy), .done(done_nc),
	.slot_valid(slot_valid), .slot_rgb(slot_rgb), .e_dx(e_dx), .e_dy(e_dy), .e_c(e_c), .e_t(e_t),
	.sg_valid(sg_valid), .sg_dash(sg_dash), .sg_rgb(sg_rgb), .sg_dx(sg_dx), .sg_dy(sg_dy), .sg_c(sg_c),
	.sg_t(sg_t), .sg_xmin(sg_xmin), .sg_xmax(sg_xmax), .sg_ymin(sg_ymin), .sg_ymax(sg_ymax),
	.bcd4(bcd4), .bcd5(bcd5), .neg(neg), .bar_len(bar_len), .bar_neg(bar_neg), .mag(mag_nc));

cube_draw draw (
	.clk(clk), .rst(rst), .pxl_x(pxl_x), .pxl_y(pxl_y),
	.slot_valid(slot_valid), .slot_rgb(slot_rgb), .e_dx(e_dx), .e_dy(e_dy), .e_c(e_c), .e_t(e_t),
	.sg_valid(sg_valid), .sg_dash(sg_dash), .sg_rgb(sg_rgb), .sg_dx(sg_dx), .sg_dy(sg_dy), .sg_c(sg_c),
	.sg_t(sg_t), .sg_xmin(sg_xmin), .sg_xmax(sg_xmax), .sg_ymin(sg_ymin), .sg_ymax(sg_ymax),
	.bcd4(bcd4), .bcd5(bcd5), .neg(neg), .bar_len(bar_len), .bar_neg(bar_neg),
	.devid(devid), .mode(mode), .test_n(test_n), .rgb(rgb), .report(report));

// ---- the report line, sent between frames so its numbers belong to one frame
assign rep_send = want_report && !busy && !p_busy;
line_printer #(.MAXLEN(128)) printer (
	.clk(clk), .text({report, {14{8'h20}}}), .len(7'd114), .send(rep_send), .busy(p_busy),
	.tx_data(p_data), .tx_valid(p_valid), .tx_ready(p_ready));

// ---- LEDs: a bubble level along x from the steady vector (the lit LED slides with the tilt); a checker
// pattern when no sensor
wire	signed	[15:0]	bx = (gx > 16'sd4095) ? 16'sd4095 : (gx < -16'sd4095) ? -16'sd4095 : gx;
wire	[12:0]	bpos = bx[12:0] + 13'd4096;						// 1..8191
wire	[15:0]	bmul = bpos * 16'd5;									// x 10 / 8192 = x 5 / 4096
wire	[3:0]		bidx = bmul[15:12];									// 0..9
always_comb leds = (devid == ADXL_ID) ? (10'd1 << bidx) : 10'b10_1010_1010;

// ---- 7-segment: the mode letter (preset digit, C calibrated, L live), then |a| as d.ddd g
wire	[7:0]		mode_ch = test ? dg({1'b0, test_n}) : cal ? "C" : "L";
seg7_char h5(.ch(mode_ch), .dp(1'b0), .seg(hex[47:40]));
seg7_char h4(.ch(" "), .dp(1'b0), .seg(hex[39:32]));
seg7_char h3(.ch(dg(bcd4[3][15:12])), .dp(1'b1), .seg(hex[31:24]));
seg7_char h2(.ch(dg(bcd4[3][11:8])), .dp(1'b0), .seg(hex[23:16]));
seg7_char h1(.ch(dg(bcd4[3][7:4])), .dp(1'b0), .seg(hex[15:8]));
seg7_char h0(.ch(dg(bcd4[3][3:0])), .dp(1'b0), .seg(hex[7:0]));

endmodule

`default_nettype wire
