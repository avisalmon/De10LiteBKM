// Example 07: the DE10-Lite's accelerometer (ADXL345 over SPI)
//
// HEX5 = axis (X, Y or Z), HEX4..HEX0 = that axis in milli-g (-2000..+2000). SW9 up: cycle X, Y, Z every
// second; SW9 down: SW1..SW0 pick (0 X, 1 Y, 2 Z). LEDR: a bubble level for X (tilt the board, the light moves).
// USB (scripts/de10.py log): 10 lines a second, "ID=E5 X=+0012 Y=-0004 Z=+0251" (raw, 3.9 mg per count).
// At rest, flat on a table: X and Y near 0, Z near +256 (1 g). The ID must read E5, or the SPI is wrong.
// ***********************************************

module accel_top (
	input						MAX10_CLK1_50,
	input			[9:0]		SW,
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
wire	[7:0]		devid;
wire signed [15:0]	x, y, z;
wire				valid, sdio_out, sdio_oe;

// 4-wire SPI: GSENSOR_SDI is our data out, GSENSOR_SDO the chip's data out (the driver can also do 3-wire)
assign GSENSOR_SDI = sdio_oe ? sdio_out : 1'bz;
assign GSENSOR_SDO = 1'bz;

adxl345 #(.THREE_WIRE(0)) accel(.clk(clk), .cs_n(GSENSOR_CS_N), .sclk(GSENSOR_SCLK), .sdio_out(sdio_out), .sdio_oe(sdio_oe), .sdio_in(GSENSOR_SDI), .miso(GSENSOR_SDO),
	.devid(devid), .x(x), .y(y), .z(z), .valid(valid));

// ---- which axis
reg	[25:0]	tick = 0;
reg	[1:0]		auto_axis = 0;
always @(posedge clk) begin
	tick <= (tick == 49_999_999) ? 26'd0 : tick + 1'b1;
	if (tick == 0) auto_axis <= (auto_axis == 2) ? 2'd0 : auto_axis + 1'b1;
end
wire	[1:0]		axis = SW[9] ? auto_axis : (SW[1:0] == 3 ? 2'd2 : SW[1:0]);
wire signed [15:0]	v = (axis == 0) ? x : (axis == 1) ? y : z;

// ---- milli-g = count * 3.90625 = count * 125 / 32
wire				neg = v[15];
wire	[15:0]	mag = neg ? -v : v;
wire	[22:0]	mg = (mag * 23'd125) >> 5;
wire	[19:0]	bcd;
bin2bcd #(.BITS(13), .DIGITS(5)) dec(.bin(mg[12:0]), .bcd(bcd));

wire	[7:0]		seg [0:5];
seg7_char s5(.ch(axis == 0 ? "X" : axis == 1 ? "Y" : "Z"), .dp(1'b0), .seg(seg[5]));
genvar i;
generate
	for (i = 0; i < 4; i = i + 1) begin : digit
		wire blank = (i > 0 && bcd[15:4*i] == 0);
		seg7_char c(.ch(blank ? " " : 8'h30 + bcd[4*i +: 4]), .dp(1'b0), .seg(seg[i]));
	end
endgenerate
seg7_char s4(.ch(neg ? "-" : " "), .dp(1'b0), .seg(seg[4]));
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

// ---- bubble level: X -256..+256 (-1 g..+1 g) -> LED 9..0
wire signed [15:0]	xc = (x > 255) ? 16'sd255 : (x < -256) ? -16'sd256 : x;
wire	[3:0]		led = 4'd9 - ((xc + 16'sd256) * 10 >> 9);
assign LEDR = (devid == 8'hE5) ? (10'b1 << led) : 10'b1010101010;	// alternate pattern: no sensor

// ---- USB report, 10 per second
function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction
// "+0251": sign and 4 digits from a bin2bcd_seq result (the "/ 1000" logic version failed timing by 15 ns)
function automatic [8*5-1:0] sdec(input s, input [19:0] d);
	sdec = {s ? "-" : "+", 8'h30 + d[15:12], 8'h30 + d[11:8], 8'h30 + d[7:4], 8'h30 + d[3:0]};
endfunction

// every 10th sample: latch X, Y, Z, convert the three magnitudes to decimal one after another, then print
reg	[3:0]		n_valid = 0;
reg	[1:0]		conv = 3;			// 0..2 = converting X/Y/Z, 3 = idle
reg				cstart = 0;
reg	[15:0]	cin = 0;
reg	[2:0]		sgn = 0;
reg	[15:0]	lm [0:2];
reg	[19:0]	dg [0:2];
wire	[19:0]	cbcd;
wire				cdone;
reg				send = 0;
reg	[8*32-1:0]	text;
wire	[7:0]		tx_data;
wire				tx_valid, tx_ready, busy;

bin2bcd_seq #(.BITS(16), .DIGITS(5)) conv_dec(.clk(clk), .start(cstart), .bin(cin), .bcd(cbcd), .done(cdone), .busy());

always @(posedge clk) begin
	send <= 0;
	cstart <= 0;
	if (valid) begin
		n_valid <= (n_valid == 9) ? 4'd0 : n_valid + 1'b1;		// 100 Hz -> 10 Hz
		if (n_valid == 0 && conv == 3 && !busy) begin
			sgn <= {z[15], y[15], x[15]};
			lm[0] <= x[15] ? -x : x;  lm[1] <= y[15] ? -y : y;  lm[2] <= z[15] ? -z : z;
			cin <= x[15] ? -x : x;
			cstart <= 1;
			conv <= 0;
		end
	end
	if (cdone) begin
		dg[conv] <= cbcd;
		if (conv == 2) begin
			text <= {"ID=", hx(devid[7:4]), hx(devid[3:0]), " X=", sdec(sgn[0], dg[0]), " Y=", sdec(sgn[1], dg[1]),
			         " Z=", sdec(sgn[2], cbcd), {3{8'h20}}};		// 29 + 3 = 32
			send <= 1;
			conv <= 3;
		end
		else begin
			cin <= lm[conv + 1'b1];
			cstart <= 1;
			conv <= conv + 1'b1;
		end
	end
end
line_printer #(.MAXLEN(32)) printer(.clk(clk), .text(text), .len(7'd29), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(), .rx_valid());

endmodule
