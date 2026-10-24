// Example 08: the DE10-Lite's own I/O: 10 switches, 10 LEDs, 2 keys, 6 seven-segment digits
//
// SW9 up:   text mode. "HELLO dE10-LItE" scrolls across HEX5..HEX0; SW3..SW0 set the speed; LEDs run back and forth.
// SW9 down: count mode. KEY0 presses are counted (debounced) on HEX5..HEX0; KEY1 resets; LEDR mirrors the switches.
// USB (scripts/de10.py log): one line per change, e.g. "SW=3FF", "KEY0 down count=5", "KEY1 down: reset".
// No shield needed. KEYs read 0 when pressed (pull-ups); the 7-segment LEDs light on 0 (active low).
// ***********************************************

module board_io_top (
	input						MAX10_CLK1_50,
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

wire				clk = MAX10_CLK1_50;

// ---- inputs, debounced (10 ms): switches bounce too
wire	[9:0]		sw;
wire	[1:0]		key_down;
debounce #(.N(12), .STEADY(500_000)) deb(.clk(clk), .in({~KEY, SW}), .out({key_down, sw}));

reg	[1:0]		key_d = 0;
always @(posedge clk) key_d <= key_down;
wire	[1:0]		press = key_down & ~key_d;			// one clock per press

// ---- count mode
reg	[19:0]	count = 0;
always @(posedge clk) begin
	if (press[1])
		count <= 0;
	else if (press[0] && count != 999_999)
		count <= count + 1'b1;
end
wire	[23:0]	cbcd;
bin2bcd #(.BITS(20), .DIGITS(6)) cdec(.bin(count), .bcd(cbcd));

// ---- text mode: a 24-character message scrolls through a 6-character window
localparam [8*24-1:0] MSG = "HELLO dE10-LItE BKM     ";
reg	[4:0]		pos = 0;
reg	[27:0]	t = 0;
wire	[27:0]	step = 28'd2_000_000 + {sw[3:0], 22'd0};	// 40 ms .. 1.3 s per step
always @(posedge clk) begin
	if (t >= step) begin
		t <= 0;
		pos <= (pos == 23) ? 5'd0 : pos + 1'b1;
	end
	else
		t <= t + 1'b1;
end

// ---- the six digits
wire	[7:0]		seg [0:5];
genvar i;
generate
	for (i = 0; i < 6; i = i + 1) begin : digit
		wire [4:0] mpos = (pos + (5 - i)) % 24;					// HEX5 shows the first character
		wire [7:0] ch_text = MSG[8*(23 - mpos) +: 8];
		wire [7:0] ch_count = (i > 0 && cbcd[23:4*i] == 0) ? " " : 8'h30 + cbcd[4*i +: 4];
		seg7_char c(.ch(sw[9] ? ch_text : ch_count), .dp(1'b0), .seg(seg[i]));
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

// ---- LEDs: mirror the switches, or a light running back and forth
reg	[9:0]		run = 10'b1;
reg				dir = 0;
reg	[22:0]	rt = 0;
always @(posedge clk) begin
	rt <= rt + 1'b1;
	if (rt == 0) begin
		if (!dir) begin run <= run << 1; if (run[8]) dir <= 1; end
		else      begin run <= run >> 1; if (run[1]) dir <= 0; end
	end
end
assign LEDR = sw[9] ? run : sw;

// ---- USB event lines
function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction

reg	[9:0]		sw_rep = 10'h3FF;
reg				first = 1;
reg	[20:0]	boot = 0;		// first report after ~20 ms, when the debounced switches are real
always @(posedge clk) if (boot != 21'h1FFFFF) boot <= boot + 1'b1;
reg	[8*24-1:0]	text;
reg	[6:0]		len;
reg				send = 0;
wire				busy;
reg	[1:0]		pend = 0;		// presses waiting to be reported (seen one clock after, so count is updated)
always @(posedge clk) begin
	send <= 0;
	pend <= pend | press;
	if (!busy && !send) begin
		if (pend != 0) begin
			pend <= (pend & (pend[1] ? 2'b01 : 2'b10)) | press;	// report KEY1 first, keep the other one pending
			text <= pend[1] ? {"KEY1 down: reset", {8{8'h20}}} :
			       {"KEY0 down count=", 8'h30 + cbcd[23:20], 8'h30 + cbcd[19:16], 8'h30 + cbcd[15:12],
			        8'h30 + cbcd[11:8], 8'h30 + cbcd[7:4], 8'h30 + cbcd[3:0], {2{8'h20}}};
			len <= pend[1] ? 7'd16 : 7'd22;
			send <= 1;
		end
		else if ((sw != sw_rep || first) && boot == 21'h1FFFFF) begin
			text <= {"SW=", hx({2'b0, sw[9:8]}), hx(sw[7:4]), hx(sw[3:0]), {18{8'h20}}};
			len <= 7'd6;
			sw_rep <= sw;
			first <= 0;
			send <= 1;
		end
	end
end

wire	[7:0]		tx_data;
wire				tx_valid, tx_ready;
line_printer #(.MAXLEN(24)) printer(.clk(clk), .text(text), .len(len), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(), .rx_valid());

endmodule
