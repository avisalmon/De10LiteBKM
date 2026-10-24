// ADXL345 accelerometer on the DE10-Lite (the "G-sensor"), SPI mode 3, 1 MHz
//
// Verified on the board with THREE_WIRE = 0 (4-wire: we send on GSENSOR_SDI, read on GSENSOR_SDO): DEVID = E5,
// |g| = 257 counts at rest. THREE_WIRE = 1 (Terasic's demo: data both ways on SDI) is NOT verified here.
// After power-up: DATA_FORMAT = 0x08 (full resolution, +-2 g -> 3.9 mg per LSB, 1 g ~ 256; 0x48 in 3-wire), BW_RATE = 0x0A
// (100 samples/s), POWER_CTL = 0x08 (measure); reads DEVID (must be 0xE5); then reads X, Y, Z every 10 ms.
// x, y, z are signed (two's complement), valid pulses with each new set.
// Pins: GSENSOR_CS_N, GSENSOR_SCLK, GSENSOR_SDI (assign GSENSOR_SDI = sdio_oe ? sdio_out : 1'bz; sdio_in = the
// pin), GSENSOR_SDO -> miso. The chip keeps its registers while the FPGA is reprogrammed (only power resets it).
// ***********************************************

module adxl345 #(
	parameter THREE_WIRE = 0		// 0: 4-wire, read on miso (= SDO) - verified; 1: data both ways on SDI (not verified)
)(
	input						clk,		// 50 MHz
	output					cs_n,
	output					sclk,
	output					sdio_out,
	output					sdio_oe,
	input						sdio_in,	// 3-wire: the SDI pin
	input						miso,		// 4-wire: the SDO pin
	output reg	[7:0]		devid = 0,
	output reg signed [15:0]	x = 0,
	output reg signed [15:0]	y = 0,
	output reg signed [15:0]	z = 0,
	output reg				valid = 0
	);

reg				start = 0;
reg	[7:0]		tx = 0;
reg				hold = 0;
reg				rd = 0;
wire	[7:0]		rx;
wire				done, busy;

spi_master #(.DIV(25)) spi(.clk(clk), .start(start), .tx_byte(tx), .cs_hold(hold), .rd(rd), .rx_byte(rx), .done(done),
	.busy(busy), .sclk(sclk), .mosi(sdio_out), .mosi_oe(sdio_oe), .miso(THREE_WIRE ? sdio_in : miso), .cs_n(cs_n));

// the sequence of bytes: {read, hold-after, byte}; read commands are 0x80 | addr (+0x40 for several bytes)
localparam logic [9:0] SEQ [0:16] = '{
	{2'b01, 8'h31}, {2'b00, 8'h08},		// DATA_FORMAT: full res, +-2 g; bit 6 (3-wire) added below
	{2'b01, 8'h2C}, {2'b00, 8'h0A},		// BW_RATE: 100 Hz
	{2'b01, 8'h2D}, {2'b00, 8'h08},		// POWER_CTL: measure
	{2'b01, 8'h80}, {2'b10, 8'h00},		// read DEVID
	{2'b01, 8'hF2},							// read 6 bytes from DATAX0 (0x32)
	{2'b11, 8'h00}, {2'b11, 8'h00}, {2'b11, 8'h00}, {2'b11, 8'h00}, {2'b11, 8'h00}, {2'b10, 8'h00},
	{2'b00, 8'h00}, {2'b00, 8'h00}};	// unused
localparam LOOP = 8, LAST = 14;

reg	[4:0]		i = 0;
reg	[19:0]	wait_cnt = 20'd1_000_000;	// 20 ms after power-up before talking to it
reg	[7:0]		b [0:5];
reg				pending = 0;

always @(posedge clk) begin
	start <= 0;
	valid <= 0;
	if (wait_cnt != 0)
		wait_cnt <= wait_cnt - 1'b1;
	else if (!pending && !busy) begin
		tx <= (i == 1 && THREE_WIRE) ? 8'h48 : SEQ[i][7:0];
		hold <= SEQ[i][8];
		rd <= SEQ[i][9] && THREE_WIRE;
		start <= 1;
		pending <= 1;
	end
	if (done) begin
		pending <= 0;
		if (i == 7) devid <= rx;
		if (i >= LOOP + 1) b[i - LOOP - 1] <= rx;
		if (i == LAST) begin
			x <= {b[1], b[0]};
			y <= {b[3], b[2]};
			z <= {rx, b[4]};
			valid <= 1;
			i <= LOOP;
			wait_cnt <= 20'd500_000;		// next read in 10 ms
		end
		else begin
			i <= i + 1'b1;
			if (i[0] && i < LOOP) wait_cnt <= 20'd50;		// a short gap with CS high between commands
		end
	end
end

endmodule
