// The published numbers as decimal digits, for the screen, the report line and the 7-segment display
//
// After each pub (a new frame's results) one bin2bcd_seq converts the 12 numbers one after the other
// (about 21 clocks each, all inside the vertical blanking time). busy is high from pub until the last one.
// ***********************************************
`default_nettype none

module lab_digits (
	input		wire						clk,
	input		wire						pub,
	input		wire			[9:0]		fq,
	input		wire			[16:0]	dclk,
	input		wire			[16:0]	iclk,
	input		wire			[6:0]		dpk,
	input		wire			[6:0]		dpx,
	input		wire			[6:0]		ipk,
	input		wire			[6:0]		ipx,
	input		wire signed	[5:0]		iexp,
	output	logic			[15:0]	fq_bcd = 16'd0,		// the frequency step N
	output	logic			[23:0]	hz_bcd = 24'd0,		// the frequency in 0.1 Hz (N x 125)
	output	logic			[11:0]	bin_bcd = 12'd0,		// the whole FFT bin (N / 8)
	output	logic			[19:0]	dclk_bcd = 20'd0,		// our FFT: clocks
	output	logic			[23:0]	dus_bcd = 24'd0,		// our FFT: time in 10 ns (clocks x 4)
	output	logic			[19:0]	iclk_bcd = 20'd0,		// the IP: clocks
	output	logic			[23:0]	ius_bcd = 24'd0,		// the IP: time in 10 ns
	output	logic			[11:0]	dpk_bcd = 12'd0,		// tallest bar: bin and height
	output	logic			[11:0]	dpx_bcd = 12'd0,
	output	logic			[11:0]	ipk_bcd = 12'd0,
	output	logic			[11:0]	ipx_bcd = 12'd0,
	output	logic			[7:0]		exp_bcd = 8'd0,		// |the IP's exponent|
	output	wire						busy
	);

logic	[3:0]		si = 4'd0;
logic				seq = 1'b0, go = 1'b0;
logic	[18:0]	bin;
wire	[23:0]	bcd;
wire				bdone;
wire	[5:0]		exp_abs = iexp[5] ? (~iexp + 1'b1) : iexp;

assign busy = seq || pub;

always_comb
	case (si)
		4'd0:    bin = {9'd0, fq};
		4'd1:    bin = fq * 19'd125;
		4'd2:    bin = {12'd0, fq[9:3]};
		4'd3:    bin = {2'd0, dclk};
		4'd4:    bin = {dclk, 2'b00};
		4'd5:    bin = {2'd0, iclk};
		4'd6:    bin = {iclk, 2'b00};
		4'd7:    bin = {12'd0, dpk};
		4'd8:    bin = {12'd0, dpx};
		4'd9:    bin = {12'd0, ipk};
		4'd10:   bin = {12'd0, ipx};
		default: bin = {13'd0, exp_abs};
	endcase

bin2bcd_seq #(.BITS(19), .DIGITS(6)) conv(.clk(clk), .start(go), .bin(bin), .bcd(bcd), .done(bdone), .busy());

always @(posedge clk) begin
	go <= 1'b0;
	if (pub) begin
		seq <= 1'b1; si <= 4'd0; go <= 1'b1;
	end
	else if (seq && bdone) begin
		case (si)
			4'd0:    fq_bcd <= bcd[15:0];
			4'd1:    hz_bcd <= bcd;
			4'd2:    bin_bcd <= bcd[11:0];
			4'd3:    dclk_bcd <= bcd[19:0];
			4'd4:    dus_bcd <= bcd;
			4'd5:    iclk_bcd <= bcd[19:0];
			4'd6:    ius_bcd <= bcd;
			4'd7:    dpk_bcd <= bcd[11:0];
			4'd8:    dpx_bcd <= bcd[11:0];
			4'd9:    ipk_bcd <= bcd[11:0];
			4'd10:   ipx_bcd <= bcd[11:0];
			default: exp_bcd <= bcd[7:0];
		endcase
		if (si == 4'd11) seq <= 1'b0;
		else begin si <= si + 1'b1; go <= 1'b1; end
	end
end

endmodule

`default_nettype wire
