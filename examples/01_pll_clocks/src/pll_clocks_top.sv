// Example 01: PLL and clocks
//
// One PLL makes 5 clocks from the 50 MHz oscillator; the design then measures each of them (and the
// board's two other oscillators) against MAX10_CLK1_50 and shows the result:
//   HEX5..HEX0  frequency of the selected clock in kHz (025000 = 25 MHz)
//   SW9 up      cycle through the 8 clocks, one per second; SW9 down: SW2..SW0 pick one
//   LEDR2..0    which clock is shown;  LEDR8..4  one blinker per PLL output (~1 Hz each);  LEDR9  PLL locked
//   KEY0        hold to reset the PLL (LEDR9 goes off, the PLL clocks stop)
//   USB (JTAG UART, scripts/de10.py log): one line per clock every second, e.g. "c0 PLL 50*1/2 = 25000 kHz"
// ***********************************************

module pll_clocks_top (
	input						MAX10_CLK1_50,
	input						MAX10_CLK2_50,
	input						ADC_CLK_10,
	input			[1:0]		KEY,
	input			[9:0]		SW,
	output		[9:0]		LEDR,
	output		[7:0]		HEX0,
	output		[7:0]		HEX1,
	output		[7:0]		HEX2,
	output		[7:0]		HEX3,
	output		[7:0]		HEX4,
	output		[7:0]		HEX5
	);

wire			clk = MAX10_CLK1_50;
wire	[4:0]	pll_clk;
wire			locked;

// ---- the PLL: f = 50 MHz * MUL / DIV
pll_de10 #(
	.C0_MUL(1), .C0_DIV(2),								// 25 MHz
	.C1_MUL(2), .C1_DIV(1),								// 100 MHz
	.C2_MUL(2), .C2_DIV(3),								// 33.333 MHz
	.C3_MUL(1), .C3_DIV(5),								// 10 MHz
	.C4_MUL(1), .C4_DIV(1), .C4_PHASE("5000")		// 50 MHz, 90 degrees late (5 ns of 20 ns)
) pll (
	.areset(~KEY[0]),
	.inclk0(clk),
	.clk(pll_clk),
	.locked(locked)
	);

// ---- measure 8 clocks
wire	[7:0]		sources = {clk, ADC_CLK_10, MAX10_CLK2_50, pll_clk};
wire	[19:0]	khz [0:7];

genvar g;
generate
	for (g = 0; g < 8; g = g + 1) begin : meas
		freq_counter fc(.ref_clk(clk), .meas_clk(sources[g]), .khz(khz[g]), .valid());
	end
endgenerate

// ---- one ~1 Hz blinker per PLL output, each counted in its own clock domain
localparam logic [27:0] HALF [0:4] = '{12_500_000, 50_000_000, 16_666_667, 5_000_000, 25_000_000};
reg	[4:0]		blink = 0;
generate
	for (g = 0; g < 5; g = g + 1) begin : blinkers
		reg [27:0] n = 0;
		always @(posedge pll_clk[g]) begin
			if (n >= HALF[g] - 1) begin
				n <= 0;
				blink[g] <= ~blink[g];
			end
			else
				n <= n + 1;
		end
	end
endgenerate

// ---- which clock to show
reg	[25:0]	tick = 0;		// 1 s at 50 MHz
reg	[2:0]		auto_sel = 0;
wire			second = (tick == 49_999_999);
always @(posedge clk) begin
	tick <= second ? 26'd0 : tick + 1'b1;
	if (second)
		auto_sel <= auto_sel + 1'b1;
end
wire	[2:0]		sel = SW[9] ? auto_sel : SW[2:0];

// ---- 7-segment: kHz in decimal, leading zeros blank
wire	[23:0]	bcd;
wire	[7:0]		seg [0:5];
bin2bcd #(.BITS(20), .DIGITS(6)) to_dec(.bin(khz[sel]), .bcd(bcd));
generate
	for (g = 0; g < 6; g = g + 1) begin : digits
		wire [7:0] s;
		seven_segment dec(.in_hex(bcd[4*g +: 4]), .out_to_ss(s));
		assign seg[g] = (g > 0 && bcd[23:4*g] == 0) ? 8'hFF : s;
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

assign LEDR = {locked, blink, 1'b0, sel};

// ---- report every clock to the PC once a second
localparam logic [8*16-1:0] NAME [0:7] = '{
	"c0 PLL 50*1/2  =", "c1 PLL 50*2/1  =", "c2 PLL 50*2/3  =", "c3 PLL 50*1/5  =",
	"c4 PLL 50 +90d =", "MAX10_CLK2_50  =", "ADC_CLK_10     =", "MAX10_CLK1_50  ="};

wire	[7:0]		tx_data;
wire				tx_valid, tx_ready, busy;
reg	[2:0]		rep = 0;
reg				reporting = 0;
reg				send = 0;
wire	[23:0]	rep_bcd;
bin2bcd #(.BITS(20), .DIGITS(6)) rep_dec(.bin(khz[rep]), .bcd(rep_bcd));

function automatic [7:0] dch(input [3:0] d);
	dch = 8'h30 + d;
endfunction

wire [8*48-1:0] text = {NAME[rep], " ",
	dch(rep_bcd[23:20]), dch(rep_bcd[19:16]), dch(rep_bcd[15:12]),
	dch(rep_bcd[11:8]), dch(rep_bcd[7:4]), dch(rep_bcd[3:0]), " kHz", {21{8'h20}}};

always @(posedge clk) begin
	send <= 0;
	if (second && !reporting) begin
		reporting <= 1;
		rep <= 0;
	end
	else if (reporting && !busy && !send) begin
		send <= 1;
		if (rep == 7)
			reporting <= 0;
		else
			rep <= rep + 1'b1;
	end
end

// the line is latched by line_printer when send is high; rep has already moved on by then,
// so print the clock that was selected one cycle earlier
reg [8*48-1:0] text_q;
always @(posedge clk) text_q <= text;

line_printer #(.MAXLEN(48)) printer(
	.clk(clk), .text(text_q), .len(7'd27), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

jtag_uart uart(
	.clk(clk), .resetN(1'b1),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(), .rx_valid());

endmodule
