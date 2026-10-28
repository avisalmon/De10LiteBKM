`default_nettype none
// Example 14: fill the 64 MB SDRAM from the PC over the USB-Blaster cable, prove it, read it back
//
// lib/rtl/sdram_loader.sv is a virtual JTAG node on the cable: scripts/sdram_load.py streams a file into the SDRAM
// through it, has the board CRC the whole range (no readback over the cable) and reads it back on request.
// The JTAG UART beside it is the other route a PC has into the board; here it only counts and CRCs what arrives
// (STATUS words 8, 9), so the bench can time both routes on the same board (scripts/sdram_load.py bench).
// HEX5..HEX0: KB written since the last load started (SW0 up: KB received by the JTAG UART).
// LEDR0 SDRAM ready, LEDR1 loader using the SDRAM, LEDR2 read stream open, LEDR3 board CRC running,
// LEDR9 a word was lost (write overflow or read underrun; cleared by the next load / read).
// Clocks: 50 MHz from the PLL for the logic and the SDRAM, DRAM_CLK the same shifted 180 degrees (as example 06).
// ***********************************************

module loader_top (
	input						MAX10_CLK1_50,
	input			[9:0]		SW,
	output		[9:0]		LEDR,
	output		[7:0]		HEX0,
	output		[7:0]		HEX1,
	output		[7:0]		HEX2,
	output		[7:0]		HEX3,
	output		[7:0]		HEX4,
	output		[7:0]		HEX5,
	output		[12:0]	DRAM_ADDR,
	output		[1:0]		DRAM_BA,
	output					DRAM_CAS_N,
	output					DRAM_CKE,
	output					DRAM_CLK,
	output					DRAM_CS_N,
	inout			[15:0]	DRAM_DQ,
	output					DRAM_LDQM,
	output					DRAM_RAS_N,
	output					DRAM_UDQM,
	output					DRAM_WE_N
	);

wire	[4:0]		pclk;
wire				locked;
pll_de10 #(.C0_MUL(1), .C0_DIV(1), .C1_MUL(1), .C1_DIV(1), .C1_PHASE("10000")) pll(		// c1 = c0 + 180 degrees
	.areset(1'b0), .inclk0(MAX10_CLK1_50), .clk(pclk), .locked(locked));
wire				clk = pclk[0];
assign DRAM_CLK = pclk[1];

reg	[2:0]		lk = 0;
always @(posedge clk) lk <= {lk[1:0], locked};
wire				reset_n = lk[2];

// ---- the SDRAM and the loader
wire				req, we, ready, rvalid, init_done;
wire	[24:0]	addr;
wire	[15:0]	wdata, rdata;
sdram_ctrl #(.CLK_MHZ(50), .READ_DELAY(4)) ctrl(.clk(clk), .reset_n(reset_n), .rd_delay(3'd4), .req(req), .we(we),
	.addr(addr), .wdata(wdata), .ready(ready), .rvalid(rvalid), .rdata(rdata), .init_done(init_done),
	.DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_CAS_N(DRAM_CAS_N), .DRAM_CKE(DRAM_CKE), .DRAM_CS_N(DRAM_CS_N),
	.DRAM_DQ(DRAM_DQ), .DRAM_LDQM(DRAM_LDQM), .DRAM_RAS_N(DRAM_RAS_N), .DRAM_UDQM(DRAM_UDQM), .DRAM_WE_N(DRAM_WE_N));

wire	[31:0]	words_written;
wire				reading, check_busy, busy, error;
reg	[31:0]	u_bytes = 0;				// JTAG UART: bytes received since power-up
reg	[31:0]	u_crc = 32'hFFFFFFFF;	// and their running CRC32 (the PC continues it: zlib.crc32(data, before))
sdram_loader #(.INSTANCE(0)) loader(.clk(clk), .reset_n(reset_n), .req(req), .we(we), .addr(addr), .wdata(wdata),
	.ready(ready), .rvalid(rvalid), .rdata(rdata), .init_done(init_done), .user0(u_bytes), .user1(~u_crc),
	.words_written(words_written), .reading(reading), .check_busy(check_busy), .busy(busy), .error(error));

// ---- the JTAG UART route: count and CRC every byte
function automatic [31:0] crc32_8(input [31:0] c, input [7:0] d);
	integer i;
	reg [31:0] x;
	begin
		x = c;
		for (i = 0; i < 8; i = i + 1)
			x = (x[0] ^ d[i]) ? ({1'b0, x[31:1]} ^ 32'hEDB88320) : {1'b0, x[31:1]};
		crc32_8 = x;
	end
endfunction

wire	[7:0]		rx_data;
wire				rx_valid;
jtag_uart uart(.clk(clk), .resetN(1'b1), .tx_data(8'd0), .tx_valid(1'b0), .tx_ready(),
	.rx_data(rx_data), .rx_valid(rx_valid));
always @(posedge clk)
	if (rx_valid) begin
		u_bytes <= u_bytes + 1'b1;
		u_crc <= crc32_8(u_crc, rx_data);
	end

// ---- display: KB in decimal (512 words = 1 KB)
wire	[19:0]	kb = SW[0] ? u_bytes[29:10] : words_written[28:9];
wire	[23:0]	kbcd;
bin2bcd #(.BITS(20), .DIGITS(6)) kd(.bin(kb > 999999 ? 20'd999999 : kb), .bcd(kbcd));
wire	[7:0]		seg [0:5];
genvar i;
generate
	for (i = 0; i < 6; i = i + 1) begin : digit
		wire blank = (i > 0 && kbcd[23:4*i] == 0);
		seg7_char c(.ch(blank ? " " : 8'h30 + kbcd[4*i +: 4]), .dp(1'b0), .seg(seg[i]));
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

// LEDR1 stays lit 20 ms after the last SDRAM access, so a load is visible
reg	[19:0]	act = 0;
always @(posedge clk) act <= busy ? 20'hFFFFF : (act != 0 ? act - 1'b1 : 20'd0);
assign LEDR = {error, 5'b0, check_busy, reading, act != 0, init_done};

endmodule

`default_nettype wire
