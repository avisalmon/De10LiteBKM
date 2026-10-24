// Example 11: a 256-point FFT two ways: Altera's FFT IP (FFT II, Burst, block floating point) and our own
// radix-2 FFT (src/fft_r2.sv), on the same test signal (assets/input.hex: tones at bins 10, 37, 85 + noise)
//
// After start-up, on KEY0 or when the PC sends 'R': both FFTs run, their results are collected and sent to the PC:
//   IP SCALE=<s>  + 256 lines RRRRIIII   (FFT value = word * 2^s; s from the IP's block exponent)
//   DIY SCALE=8   + 256 lines            (it halves every stage)
//   IP  CYC=........ / DIY CYC=........  (hex clocks from the start to the last result)
// Then on the PC: python examples/11_fft/sim/fft_data.py check <dump> -> accuracy of each against numpy.
// HEX: "IP" / "diy" done, LEDR0/1 done.  50 MHz.
// NOTE: the FFT IP is a licensed core; in Quartus Prime Lite it compiles as an OpenCore Plus evaluation: the .sof
// it makes (fft_time_limited.sof) only runs while the USB cable stays connected (and for a limited time).
// ***********************************************

module fft_top (
	input						MAX10_CLK1_50,
	input			[1:0]		KEY,
	output		[9:0]		LEDR,
	output		[7:0]		HEX0,
	output		[7:0]		HEX1,
	output		[7:0]		HEX2,
	output		[7:0]		HEX3,
	output		[7:0]		HEX4,
	output		[7:0]		HEX5
	);

wire				clk = MAX10_CLK1_50;

// ---- start: 1 ms after power-up, KEY0, or 'R' from the PC
reg	[16:0]	boot = 0;
reg	[1:0]		ks = 0;
wire	[7:0]		rx_data;
wire				rx_valid;
reg				go = 0;
reg				reset_n = 0;
always @(posedge clk) begin
	ks <= {ks[0], ~KEY[0]};
	go <= 0;
	if (boot != 17'h1FFFF) boot <= boot + 1'b1;
	reset_n <= (boot > 17'd1000);
	if (boot == 17'h1FFFE || ks == 2'b01 || (rx_valid && (rx_data == "R" || rx_data == "r"))) go <= 1;
end

// ---- test signal ROM
reg	[31:0]	x [0:255];
initial $readmemh("assets/input.hex", x);

// ---- feed both FFTs
reg	[8:0]		di = 256, ii = 256;		// next sample index for DIY / IP (256 = idle)
reg	[31:0]	dsamp, isamp;
reg				d_valid = 0;
reg	[31:0]	t_d = 0, t_i = 0;			// clocks since start
reg				run_d = 0, run_i = 0;
always @(posedge clk) begin
	d_valid <= 0;
	if (go) begin di <= 0; run_d <= 1; end
	else if (di < 256) begin
		dsamp <= x[di[7:0]];
		d_valid <= 1;
		di <= di + 1'b1;
	end
	if (go) t_d <= 0;						// (go must win over the count: it is the later statement)
	else if (run_d) t_d <= t_d + 1'b1;
end

wire				sink_ready, source_valid, source_sop, source_eop;
wire	[15:0]	source_real, source_imag;
wire	[5:0]		source_exp;
wire	[1:0]		source_error;
reg				sink_valid = 0, sink_sop = 0, sink_eop = 0;
reg	[15:0]	sink_real = 0, sink_imag = 0;
always @(posedge clk) begin
	if (go) begin ii <= 0; run_i <= 1; sink_valid <= 0; end
	else begin
		if (sink_valid && sink_ready) sink_valid <= 0;			// sample taken
		if ((!sink_valid || sink_ready) && ii < 256) begin	// next sample
			{sink_real, sink_imag} <= x[ii[7:0]];
			sink_valid <= 1;
			sink_sop <= (ii == 0);
			sink_eop <= (ii == 255);
			ii <= ii + 1'b1;
		end
	end
	if (go) t_i <= 0;
	else if (run_i) t_i <= t_i + 1'b1;
end

fft256 fft_ip(
	.clk(clk), .reset_n(reset_n), .inverse(1'b0),
	.sink_valid(sink_valid), .sink_sop(sink_sop), .sink_eop(sink_eop),
	.sink_real(sink_real), .sink_imag(sink_imag), .sink_error(2'b00), .sink_ready(sink_ready),
	.source_ready(1'b1), .source_exp(source_exp), .source_error(source_error),
	.source_sop(source_sop), .source_eop(source_eop), .source_valid(source_valid),
	.source_real(source_real), .source_imag(source_imag));

wire				o_valid, d_busy;
wire	[7:0]		o_k;
wire signed [15:0]	o_re, o_im;
fft_r2 fft_diy(.clk(clk), .in_valid(d_valid), .in_re(dsamp[31:16]), .in_im(dsamp[15:0]),
	.out_valid(o_valid), .out_k(o_k), .out_re(o_re), .out_im(o_im), .busy(d_busy));

// ---- collect results
reg	[31:0]	res_i [0:255];
reg	[31:0]	res_d [0:255];
reg	[8:0]		ni = 0;
reg				done_i = 0, done_d = 0;
reg	[5:0]		exp_i = 0;
reg	[31:0]	cyc_i = 0, cyc_d = 0;
always @(posedge clk) begin
	if (go) begin ni <= 0; done_i <= 0; done_d <= 0; end
	if (source_valid) begin
		res_i[source_sop ? 8'd0 : ni[7:0]] <= {source_real, source_imag};
		ni <= source_sop ? 9'd1 : ni + 1'b1;
		exp_i <= source_exp;
		if (source_eop) begin done_i <= 1; cyc_i <= t_i; end
	end
	if (o_valid) begin
		res_d[o_k] <= {o_re, o_im};
		if (o_k == 255) begin done_d <= 1; cyc_d <= t_d; end
	end
end

// ---- send everything to the PC when both are done
function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction
function automatic [8*8-1:0] h32(input [31:0] v);
	integer k;
	for (k = 0; k < 8; k = k + 1) h32[8*k +: 8] = hx(v[4*k +: 4]);
endfunction
wire signed [6:0]	scale_i = -$signed({exp_i[5], exp_i});			// output * 2^(-exp)
function automatic [8*3-1:0] sdec(input signed [6:0] v);					// "-12" / "+05"
	reg [7:0] m, tens, ones;		// sized: an unsized 10 inside {...} made each term 32 bits wide (a real bug here)
	begin
		m = v[6] ? -v : v;
		tens = m / 8'd10;
		ones = m % 8'd10;
		sdec = {v[6] ? "-" : "+", 8'h30 + tens, 8'h30 + ones};
	end
endfunction

localparam S_IDLE = 0, S_IHDR = 1, S_IDAT = 2, S_DHDR = 3, S_DDAT = 4, S_CYC_I = 5, S_CYC_D = 6;
reg	[2:0]		ss = S_IDLE;
reg	[8:0]		n = 0;
reg				both_d = 0, send = 0;
reg	[8*16-1:0]	text;
reg	[6:0]		len;
reg	[31:0]	rq_i, rq_d;
wire				busy;
always @(posedge clk) begin
	rq_i <= res_i[n[7:0]];
	rq_d <= res_d[n[7:0]];
end
always @(posedge clk) begin
	send <= 0;
	both_d <= done_i && done_d;
	if (done_i && done_d && !both_d) begin ss <= S_IHDR; n <= 0; end
	else if (!busy && !send && ss != S_IDLE) begin
		send <= 1;
		case (ss)
			S_IHDR: begin text <= {"IP SCALE=", sdec(scale_i), {4{8'h20}}}; len <= 7'd12; ss <= S_IDAT; n <= 0; end
			S_IDAT: begin text <= {h32(rq_i), {8{8'h20}}}; len <= 7'd8; n <= n + 1'b1; if (n == 255) ss <= S_DHDR; end
			S_DHDR: begin text <= {"DIY SCALE=8", {5{8'h20}}}; len <= 7'd11; ss <= S_DDAT; n <= 0; end
			S_DDAT: begin text <= {h32(rq_d), {8{8'h20}}}; len <= 7'd8; n <= n + 1'b1; if (n == 255) ss <= S_CYC_I; end
			S_CYC_I: begin text <= {"IP  CYC=", h32(cyc_i)}; len <= 7'd16; ss <= S_CYC_D; end
			default: begin text <= {"DIY CYC=", h32(cyc_d)}; len <= 7'd16; ss <= S_IDLE; end
		endcase
	end
end

wire	[7:0]		tx_data;
wire				tx_valid, tx_ready;
line_printer #(.MAXLEN(16)) printer(.clk(clk), .text(text), .len(len), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid));

// ---- display
seg7_char h5(.ch(done_i ? "I" : " "), .dp(1'b0), .seg(HEX5));
seg7_char h4(.ch(done_i ? "P" : " "), .dp(1'b0), .seg(HEX4));
seg7_char h3(.ch(" "), .dp(1'b0), .seg(HEX3));
seg7_char h2(.ch(done_d ? "D" : " "), .dp(1'b0), .seg(HEX2));
seg7_char h1(.ch(done_d ? "I" : " "), .dp(1'b0), .seg(HEX1));
seg7_char h0(.ch(done_d ? "Y" : " "), .dp(1'b0), .seg(HEX0));
assign LEDR = {8'b0, done_d, done_i};

endmodule
