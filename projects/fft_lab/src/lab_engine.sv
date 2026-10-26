// The lab's engine: one frame = one wave of 256 samples into both FFTs, timed, turned into bars
//
// start (a frame tick) -> wave_gen streams the frame. Every sample goes to the Altera FFT IP (Avalon-ST sink)
// and, in the same clock, to our fft_r2: a sample moves when the IP is ready, so both see the same input
// at the same time. The clocks are counted from the first sample (clock 1) to each FFT's last output.
// Each FFT's outputs -> mag_px -> bar heights (bins 0..127) into the draw's RAMs, and the tallest bar.
// The scope memory gets the frame's samples as vertical spans (entry n = sample n to sample n + 1).
// When both are done the results are published (pub, r_*), all inside the vertical blanking time.
// The IP (an evaluation core in Quartus Lite) can stop: if it does not answer within WATCHDOG clocks it is
// marked dead (r_ip_ok = 0, its numbers 0) and the frames go on without it; ip_restart resets it and tries
// again. An IP that answers a non-zero input with all zeros is also not ok.
// ***********************************************
`default_nettype none

module lab_engine #(
	parameter TWIDDLE_FILE = "assets/twiddle.hex",
	parameter SINE_FILE = "assets/sine.hex",
	parameter HANN_FILE = "assets/hann.hex",
	parameter MAG_FILE = "assets/mag_rom.bin",
	parameter WATCHDOG = 20000,
	parameter [10:0] IP_RESET_CLOCKS = 11'd1000
)(
	input		wire						clk,
	input		wire						rst_hold,		// hold the IP in reset (the PLL is not locked yet)
	input		wire						start,
	input		wire			[2:0]		shape,
	input		wire			[9:0]		fq,
	input		wire						win,
	input		wire						lin,
	input		wire						ip_restart,
	// scope memory: entry {lo, hi}
	output	logic						sc_we = 1'b0,
	output	logic			[7:0]		sc_addr = 8'd0,
	output	logic			[13:0]	sc_d = 14'd0,
	// bar memories: our FFT (d) and the IP (i)
	output	logic						bd_we = 1'b0,
	output	logic			[6:0]		bd_addr = 7'd0,
	output	logic			[6:0]		bd_d = 7'd0,
	output	logic						bi_we = 1'b0,
	output	logic			[6:0]		bi_addr = 7'd0,
	output	logic			[6:0]		bi_d = 7'd0,
	// published results (stable from pub to the next pub)
	output	logic						pub = 1'b0,
	output	logic			[2:0]		r_shape = 3'd0,
	output	logic			[9:0]		r_fq = 10'd0,
	output	logic						r_win = 1'b0,
	output	logic						r_lin = 1'b0,
	output	logic			[16:0]	r_dclk = 17'd0,
	output	logic			[16:0]	r_iclk = 17'd0,
	output	logic			[6:0]		r_dpk = 7'd0,
	output	logic			[6:0]		r_dpx = 7'd0,
	output	logic			[6:0]		r_ipk = 7'd0,
	output	logic			[6:0]		r_ipx = 7'd0,
	output	logic signed [5:0]		r_iexp = 6'sd0,
	output	logic						r_ip_ok = 1'b1,
	output	logic						r_ip_dead = 1'b0,
	output	wire						busy
	);

logic				run = 1'b0;
logic	[2:0]		f_shape = 3'd0;
logic	[9:0]		f_fq = 10'd0;
logic				f_win = 1'b0, f_lin = 1'b0;
logic	[10:0]	rcnt = IP_RESET_CLOCKS;
logic				restart_pend = 1'b0, dead = 1'b0, ip_rst_n = 1'b0;
assign busy = run;

// ---- the generator
wire				g_valid, g_busy, sink_ready;
wire	[7:0]		g_n;
wire signed [15:0]	g_x;
wire				g_ready = sink_ready || dead;
wire				tr = g_valid && g_ready;				// a sample moves into both FFTs
wire				frame_go = start && !run && !g_busy && rcnt == 11'd0 && !restart_pend;

wave_gen #(.SINE_FILE(SINE_FILE), .HANN_FILE(HANN_FILE)) gen(
	.clk(clk), .start(frame_go), .shape(shape), .fq(fq), .win(win),
	.ready(g_ready), .valid(g_valid), .n(g_n), .x(g_x), .busy(g_busy));

// ---- the Altera FFT IP
wire				src_valid, src_sop, src_eop;
wire	[15:0]	src_real, src_imag;
wire	[5:0]		src_exp;
wire	[1:0]		src_error;
fft256 ip(
	.clk(clk), .reset_n(ip_rst_n), .inverse(1'b0),
	.sink_valid(g_valid && !dead), .sink_sop(g_n == 8'd0), .sink_eop(g_n == 8'd255),
	.sink_real(g_x), .sink_imag(16'd0), .sink_error(2'b00), .sink_ready(sink_ready),
	.source_ready(1'b1), .source_exp(src_exp), .source_error(src_error),
	.source_sop(src_sop), .source_eop(src_eop), .source_valid(src_valid),
	.source_real(src_real), .source_imag(src_imag));
wire				i_valid = src_valid && !dead;
logic	[7:0]		ik = 8'd0;
wire	[7:0]		i_k = src_sop ? 8'd0 : ik;

// ---- our FFT
wire				d_valid, d_busy;
wire	[7:0]		d_k;
wire signed [15:0]	d_re, d_im;
fft_r2 #(.TWIDDLE_FILE(TWIDDLE_FILE)) diy(
	.clk(clk), .in_valid(tr), .in_re(g_x), .in_im(16'sd0),
	.out_valid(d_valid), .out_k(d_k), .out_re(d_re), .out_im(d_im), .busy(d_busy));

// ---- bar heights (one ROM, two ports)
wire	[11:0]	ra_d, ra_i;
wire	[6:0]		rq_d, rq_i;
mag_rom #(.FILE(MAG_FILE)) mrom(.clk(clk), .addr_a(ra_d), .q_a(rq_d), .addr_b(ra_i), .q_b(rq_i));
wire signed [7:0]	exp8 = {{2{src_exp[5]}}, src_exp};
wire signed [7:0]	d_off = f_win ? 8'sd18 : 8'sd16;
wire signed [7:0]	i_off = (f_win ? 8'sd2 : 8'sd0) - (exp8 <<< 1);
wire				mv_d, mv_i;
wire	[7:0]		mk_d, mk_i;
wire	[6:0]		mp_d, mp_i;
mag_px mag_d(.clk(clk), .in_valid(d_valid), .in_k(d_k), .re(d_re), .im(d_im), .off(d_off), .lin(f_lin),
	.rom_addr(ra_d), .rom_q(rq_d), .out_valid(mv_d), .out_k(mk_d), .px(mp_d));
mag_px mag_i(.clk(clk), .in_valid(i_valid), .in_k(i_k), .re(src_real), .im(src_imag), .off(i_off), .lin(f_lin),
	.rom_addr(ra_i), .rom_q(rq_i), .out_valid(mv_i), .out_k(mk_i), .px(mp_i));

// ---- the scope: y = 64 - x / 512, kept in 16..112
function automatic [6:0] ypix(input signed [15:0] v);
	logic signed [8:0] y;
	begin
		y = 9'sd64 - $signed(v[15:9]);
		ypix = (y < 16) ? 7'd16 : (y > 112) ? 7'd112 : y[6:0];
	end
endfunction
wire	[6:0]		yn = ypix(g_x);
logic	[6:0]		yp = 7'd0;
logic				last_pend = 1'b0;

// ---- timing: clock 1 = the clock the first sample moves
logic	[16:0]	t = 17'd0;
logic				started = 1'b0;
wire	[16:0]	t_now = started ? t : 17'd1;

logic	[16:0]	dclk = 17'd0, iclk = 17'd0;
logic	[6:0]		dpk = 7'd0, dpx = 7'd0, ipk = 7'd0, ipx = 7'd0;
logic signed [5:0]	iexp = 6'sd0;
logic				d_done = 1'b0, i_done = 1'b0, in_nz = 1'b0, out_nz = 1'b0;
logic	[14:0]	wd = 15'd0;

always @(posedge clk) begin
	pub <= 1'b0;
	sc_we <= 1'b0;
	bd_we <= 1'b0;
	bi_we <= 1'b0;

	// IP reset: at power-up, while the PLL is not locked, and on request between frames
	ip_rst_n <= (rcnt == 11'd0);
	if (rcnt != 11'd0) rcnt <= rcnt - 1'b1;
	if (rst_hold) rcnt <= IP_RESET_CLOCKS;
	if (restart_pend && !run) begin rcnt <= IP_RESET_CLOCKS; dead <= 1'b0; end
	restart_pend <= ip_restart || (restart_pend && run);

	if (frame_go) begin
		run <= 1'b1;
		f_shape <= shape; f_fq <= fq; f_win <= win; f_lin <= lin;
		started <= 1'b0;
		d_done <= 1'b0; i_done <= 1'b0; in_nz <= 1'b0; out_nz <= 1'b0;
		wd <= 15'd0;
	end
	else begin
		if (!started) begin
			if (tr) begin started <= 1'b1; t <= 17'd2; end
		end
		else if (t != 17'd99999) t <= t + 1'b1;

		if (tr && g_x != 16'sd0) in_nz <= 1'b1;
		if (i_valid && (src_real != 16'd0 || src_imag != 16'd0)) out_nz <= 1'b1;

		if (mv_d && mk_d == 8'd255) d_done <= 1'b1;
		if (mv_i && mk_i == 8'd255) i_done <= 1'b1;

		// the watchdog: the IP must finish its frame in time
		if (run && !i_done && !dead) begin
			if (wd == WATCHDOG - 1) dead <= 1'b1;
			else wd <= wd + 1'b1;
		end
	end

	// scope memory
	if (tr) begin
		yp <= yn;
		if (g_n != 8'd0) begin
			sc_we <= 1'b1;
			sc_addr <= g_n - 1'b1;
			sc_d <= (yp < yn) ? {yp, yn} : {yn, yp};
		end
		last_pend <= (g_n == 8'd255);
	end
	else if (last_pend) begin
		sc_we <= 1'b1;
		sc_addr <= 8'd255;
		sc_d <= {yp, yp};
		last_pend <= 1'b0;
	end

	// the FFTs' clocks
	if (d_valid && d_k == 8'd255) dclk <= t_now;
	if (src_valid) ik <= i_k + 1'b1;
	if (i_valid && src_eop) begin iclk <= t_now; iexp <= $signed(src_exp); end

	// bars and the tallest bar (the lowest bin on a tie)
	if (mv_d && !mk_d[7]) begin
		bd_we <= 1'b1; bd_addr <= mk_d[6:0]; bd_d <= mp_d;
		if (mk_d == 8'd0 || mp_d > dpx) begin dpx <= mp_d; dpk <= mk_d[6:0]; end
	end
	if (mv_i && !mk_i[7]) begin
		bi_we <= 1'b1; bi_addr <= mk_i[6:0]; bi_d <= mp_i;
		if (mk_i == 8'd0 || mp_i > ipx) begin ipx <= mp_i; ipk <= mk_i[6:0]; end
	end

	// publish
	if (run && d_done && (i_done || dead)) begin
		run <= 1'b0;
		pub <= 1'b1;
		r_shape <= f_shape; r_fq <= f_fq; r_win <= f_win; r_lin <= f_lin;
		r_dclk <= dclk; r_dpk <= dpk; r_dpx <= dpx;
		r_iclk <= dead ? 17'd0 : iclk;
		r_ipk <= dead ? 7'd0 : ipk;
		r_ipx <= dead ? 7'd0 : ipx;
		r_iexp <= dead ? 6'sd0 : iexp;
		r_ip_ok <= !dead && !(in_nz && !out_nz);
		r_ip_dead <= dead;
	end
end

endmodule

`default_nettype wire
