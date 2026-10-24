// Example 12: DSP multipliers vs logic multipliers
//
// Two identical multiply-accumulate engines (src/mac.sv) add up a[i] * b[i] for 1,000,000 pairs of 18-bit signed
// numbers: one in the MAX 10's embedded multipliers at 100 MHz, one in logic elements at 75 MHz (its 18x18
// multiplier reaches only ~93 MHz: at 100 MHz it failed timing). Each runs on its own PLL clock, so the timing
// report gives each its own maximum frequency. Both results must equal the Python reference
// (sim/mac_reference.py) 01E17200A928.
//   KEY0: run again.  HEX5..HEX0: "PASS" when both match, "FAIL" if not.  LEDR0/1: DSP / logic done.
//   USB (scripts/de10.py log): "DSP   acc=01E17200A928 cycles=1000001" and the same for LOGIC, after each run.
// ***********************************************

module mult_top (
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

localparam [47:0] EXPECT = 48'h01E17200A928;		// sim/mac_reference.py, N = 1,000,000

wire				clk = MAX10_CLK1_50;
wire	[4:0]		pclk;
wire				locked;
pll_de10 #(.C0_MUL(2), .C0_DIV(1), .C1_MUL(3), .C1_DIV(2)) pll(		// c0 100 MHz (DSP), c1 75 MHz (logic)
	.areset(1'b0), .inclk0(clk), .clk(pclk), .locked(locked));
wire				clk_dsp = pclk[0], clk_logic = pclk[1];

// ---- start: after the PLL locks, and on every KEY0 press (synchronized into each engine's clock)
reg	[1:0]		key_s = 0;
reg				go = 0;			// 50 MHz: held for 8 clocks so both 100 MHz domains see it
reg	[3:0]		go_n = 0;
reg				started = 0;
always @(posedge clk) begin
	key_s <= {key_s[0], ~KEY[0]};
	if ((locked && !started) || key_s == 2'b01) begin
		started <= 1;
		go_n <= 4'd8;
	end
	else if (go_n != 0)
		go_n <= go_n - 1'b1;
	go <= (go_n != 0);
end
reg	[1:0]		gd = 0, gl = 0;
always @(posedge clk_dsp) gd <= {gd[0], go};
always @(posedge clk_logic) gl <= {gl[0], go};

wire signed [47:0]	acc_d, acc_l;
wire	[31:0]	cyc_d, cyc_l;
wire				done_d, done_l;
mac #(.USE_DSP(1)) mac_dsp(.clk(clk_dsp), .start(gd == 2'b01), .acc(acc_d), .done(done_d), .cycles(cyc_d));
mac #(.USE_DSP(0)) mac_logic(.clk(clk_logic), .start(gl == 2'b01), .acc(acc_l), .done(done_l), .cycles(cyc_l));

// ---- results into the 50 MHz domain. done is a 1-clock pulse at 100 MHz: stretch it to 4 clocks there, then
// synchronize; acc and cycles are still (the engines have finished), so they can be read directly.
reg	[3:0]		sd = 0, sl = 0;
always @(posedge clk_dsp)   sd <= done_d ? 4'hF : sd >> 1;
always @(posedge clk_logic) sl <= done_l ? 4'hF : sl >> 1;
reg	[2:0]		dd = 0, dl = 0;
reg				have_d = 0, have_l = 0;
always @(posedge clk) begin
	dd <= {dd[1:0], sd[0]};
	dl <= {dl[1:0], sl[0]};
	if (go) begin have_d <= 0; have_l <= 0; end
	if (dd[2:1] == 2'b01) have_d <= 1;
	if (dl[2:1] == 2'b01) have_l <= 1;
end

wire				both = have_d && have_l;
wire				pass = both && acc_d == EXPECT && acc_l == EXPECT;

wire	[8*6-1:0]	msg = !both ? "  RUN " : pass ? "  PASS" : "  FAIL";
seg7_char c5(.ch(msg[47:40]), .dp(1'b0), .seg(HEX5));
seg7_char c4(.ch(msg[39:32]), .dp(1'b0), .seg(HEX4));
seg7_char c3(.ch(msg[31:24]), .dp(1'b0), .seg(HEX3));
seg7_char c2(.ch(msg[23:16]), .dp(1'b0), .seg(HEX2));
seg7_char c1(.ch(msg[15:8]),  .dp(1'b0), .seg(HEX1));
seg7_char c0(.ch(msg[7:0]),   .dp(1'b0), .seg(HEX0));
assign LEDR = {pass, 7'b0, have_l, have_d};

// ---- report to the PC
function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction
function automatic [8*12-1:0] h48(input [47:0] v);
	integer k;
	for (k = 0; k < 12; k = k + 1) h48[8*k +: 8] = hx(v[4*k +: 4]);
endfunction
function automatic [8*8-1:0] h32(input [31:0] v);
	integer k;
	for (k = 0; k < 8; k = k + 1) h32[8*k +: 8] = hx(v[4*k +: 4]);
endfunction

reg	[1:0]		line = 0;		// 0 = nothing to send, 1 = DSP next, 2 = LOGIC next
reg				both_d = 0, send = 0;
reg	[8*40-1:0]	text;
wire				busy;
always @(posedge clk) begin
	send <= 0;
	both_d <= both;
	if (both && !both_d) line <= 1;
	if (line != 0 && !busy && !send) begin
		text <= (line == 1) ? {"DSP   acc=", h48(acc_d), " cycles=", h32(cyc_d), {2{8'h20}}}
		                    : {"LOGIC acc=", h48(acc_l), " cycles=", h32(cyc_l), {2{8'h20}}};
		send <= 1;
		line <= (line == 1) ? 2'd2 : 2'd0;
	end
end
wire	[7:0]		tx_data;
wire				tx_valid, tx_ready;
line_printer #(.MAXLEN(40)) printer(.clk(clk), .text(text), .len(7'd38), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(), .rx_valid());

endmodule
