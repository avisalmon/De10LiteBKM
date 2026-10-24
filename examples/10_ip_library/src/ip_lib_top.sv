// Example 10: using IP from Altera's library: megafunctions instantiated directly (no generation, no license)
//
//   altsqrt     |g| = sqrt(x^2 + y^2 + z^2) from the accelerometer (lib/rtl/adxl345.sv), 4-clock pipeline
//   lpm_divide  flat% = z * 100 / |g| (how much of gravity points straight down), signed, 12-clock pipeline
//               (with 4 stages it failed timing at 50 MHz by 1.9 ns: more stages = more latency, higher Fmax)
//   dcfifo      carries {|g|, flat%, count} from the 50 MHz domain to a 25 MHz printer domain
// HEX: |g| in milli-g (1000 at rest). USB (scripts/de10.py log): "G=0257 (1004 mg) FLAT%=+076 #05", 10 per second.
// The other IP kind, cores generated with ip-generate, is in example 11 (FFT).
// ***********************************************

module ip_lib_top (
	input						MAX10_CLK1_50,
	output		[9:0]		LEDR,
	output		[7:0]		HEX0,
	output		[7:0]		HEX1,
	output		[7:0]		HEX2,
	output		[7:0]		HEX3,
	output		[7:0]		HEX4,
	output		[7:0]		HEX5,
	output					GSENSOR_CS_N,
	output					GSENSOR_SCLK,
	inout						GSENSOR_SDI,
	inout						GSENSOR_SDO,
	input			[2:1]		GSENSOR_INT
	);

wire				clk = MAX10_CLK1_50;
wire	[4:0]		pclk;
wire				locked;
pll_de10 #(.C0_MUL(1), .C0_DIV(2)) pll(.areset(1'b0), .inclk0(clk), .clk(pclk), .locked(locked));
wire				clk25 = pclk[0];

// ---- accelerometer (50 MHz)
wire signed [15:0]	x, y, z;
wire	[7:0]		devid;
wire				valid, sdio_out, sdio_oe;
assign GSENSOR_SDI = sdio_oe ? sdio_out : 1'bz;
assign GSENSOR_SDO = 1'bz;
adxl345 accel(.clk(clk), .cs_n(GSENSOR_CS_N), .sclk(GSENSOR_SCLK), .sdio_out(sdio_out), .sdio_oe(sdio_oe),
	.sdio_in(GSENSOR_SDI), .miso(GSENSOR_SDO), .devid(devid), .x(x), .y(y), .z(z), .valid(valid));

// ---- x^2 + y^2 + z^2 (DSP multipliers), then altsqrt
reg	[31:0]	sumsq = 0;
reg	[6:0]		pipe = 0;							// which pipeline stage holds a new value
always @(posedge clk) begin
	pipe <= {pipe[5:0], valid};
	if (valid) sumsq <= x * x + y * y + z * z;
end

wire	[15:0]	mag;
altsqrt #(.width(32), .q_port_width(16), .r_port_width(17), .pipeline(4), .lpm_type("altsqrt")) sqrt (
	.radical(sumsq), .clk(clk), .ena(1'b1), .aclr(1'b0), .q(mag), .remainder());

// ---- z * 100 / |g| with lpm_divide (signed numerator, unsigned denominator)
reg signed [23:0]	z100 = 0;
always @(posedge clk) if (valid) z100 <= z * 24'sd100;
wire	[23:0]	quot;
wire	[15:0]	rem;
lpm_divide #(.lpm_widthn(24), .lpm_widthd(16), .lpm_nrepresentation("SIGNED"), .lpm_drepresentation("UNSIGNED"),
	.lpm_pipeline(12), .lpm_type("LPM_DIVIDE"), .lpm_hint("LPM_REMAINDERPOSITIVE=FALSE")) div (
	.numer(z100), .denom(mag), .clock(clk), .clken(1'b1), .aclr(1'b0), .quotient(quot), .remain(rem));
// timing: valid -> sumsq (1 clock) -> altsqrt (4) -> mag = pipe[4]; the divider then needs 12 more clocks. Its inputs
// hold still for 10 ms (until the next sample), so waiting 14 clocks instead of exactly 12 costs nothing.
reg	[15:0]	mag_q = 0;
reg signed [7:0]	pct_q = 0;
reg	[3:0]		wait_div = 0;
reg				result = 0;
always @(posedge clk) begin
	result <= 0;
	if (pipe[4]) begin mag_q <= mag; wait_div <= 4'd14; end
	else if (wait_div != 0) begin
		wait_div <= wait_div - 1'b1;
		if (wait_div == 1) begin pct_q <= quot[7:0]; result <= 1; end
	end
end

// ---- every 10th result into the dcfifo (50 MHz write, 25 MHz read)
reg	[3:0]		every = 0;
reg	[7:0]		count = 0;
reg				wrreq = 0;
reg	[31:0]	wdata = 0;
wire				wrfull, rdempty;
wire	[31:0]	rdata;
always @(posedge clk) begin
	wrreq <= 0;
	if (result) begin
		every <= (every == 9) ? 4'd0 : every + 1'b1;
		if (every == 0 && !wrfull) begin
			wdata <= {mag_q, pct_q, count};
			wrreq <= 1;
			count <= count + 1'b1;
		end
	end
end

dcfifo #(.lpm_width(32), .lpm_widthu(4), .lpm_numwords(16), .lpm_showahead("OFF"), .lpm_type("dcfifo"),
	.overflow_checking("ON"), .underflow_checking("ON"), .use_eab("ON"), .rdsync_delaypipe(4), .wrsync_delaypipe(4),
	.intended_device_family("MAX 10")) fifo (
	.data(wdata), .wrclk(clk), .wrreq(wrreq), .wrfull(wrfull),
	.rdclk(clk25), .rdreq(rdreq), .q(rdata), .rdempty(rdempty),
	.aclr(1'b0), .eccstatus(), .rdfull(), .wrempty(), .rdusedw(), .wrusedw());

// ---- 25 MHz side: read a word, print it
function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction
reg				rdreq = 0, got = 0, send = 0;
reg	[8*40-1:0]	text;
wire				busy;
wire	[19:0]	mg_bcd, pct_bcd;
reg	[15:0]	m_mag;
reg signed [7:0]	m_pct;
wire	[7:0]		pct_abs = m_pct[7] ? -m_pct : m_pct;
bin2bcd #(.BITS(16), .DIGITS(5)) mgd(.bin((m_mag * 16'd125) >> 5), .bcd(mg_bcd));
bin2bcd #(.BITS(8), .DIGITS(5)) pcd(.bin(pct_abs), .bcd(pct_bcd));
reg	[1:0]		ph = 0;
always @(posedge clk25) begin
	rdreq <= 0;
	send <= 0;
	case (ph)
		0: if (!rdempty && !busy) begin rdreq <= 1; ph <= 1; end
		1: ph <= 2;										// q is valid one clock after rdreq (lpm_showahead OFF)
		2: begin {m_mag, m_pct} <= rdata[31:8]; ph <= 3; end
		default: begin
			text <= {"G=", hx(m_mag[15:12]), hx(m_mag[11:8]), hx(m_mag[7:4]), hx(m_mag[3:0]), " (",
			         8'h30 + mg_bcd[15:12], 8'h30 + mg_bcd[11:8], 8'h30 + mg_bcd[7:4], 8'h30 + mg_bcd[3:0], " mg) FLAT%=",
			         m_pct[7] ? "-" : "+", 8'h30 + pct_bcd[11:8], 8'h30 + pct_bcd[7:4], 8'h30 + pct_bcd[3:0], " #",
			         hx(rdata[7:4]), hx(rdata[3:0]), {9{8'h20}}};	// 31 + 9 = 40
			send <= 1;
			ph <= 0;
		end
	endcase
end

wire	[7:0]		tx_data;
wire				tx_valid, tx_ready;
line_printer #(.MAXLEN(40)) printer(.clk(clk25), .text(text), .len(7'd31), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(), .rx_valid());

// ---- 7-segment: |g| in milli-g (50 MHz domain)
wire	[19:0]	seg_bcd;
bin2bcd #(.BITS(16), .DIGITS(5)) sd(.bin((mag_q * 16'd125) >> 5), .bcd(seg_bcd));
seg7_char d5(.ch("G"), .dp(1'b0), .seg(HEX5));
seg7_char d4(.ch(" "), .dp(1'b0), .seg(HEX4));
seg7_char d3(.ch(8'h30 + seg_bcd[15:12]), .dp(1'b1), .seg(HEX3));		// 1.004 (g)
seg7_char d2(.ch(8'h30 + seg_bcd[11:8]), .dp(1'b0), .seg(HEX2));
seg7_char d1(.ch(8'h30 + seg_bcd[7:4]), .dp(1'b0), .seg(HEX1));
seg7_char d0(.ch(8'h30 + seg_bcd[3:0]), .dp(1'b0), .seg(HEX0));
assign LEDR = {devid == 8'hE5, 7'b0, !rdempty, wrfull};

endmodule
