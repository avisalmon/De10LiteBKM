// Game-pad events as text lines, for the PC (and for checking the ADC channel map)
//
//   PRESS   A      ch3=02F        a control went down; chN = the ADC channel it is read from, with its raw value
//   RELEASE A      ch3=E47
//   WHEEL   2048                 the wheel moved by more than 64 steps (0..4095; it jitters ~33 at rest)
// btn bits: {Left, Right, Up, Down, Start, Select, B, A} (debounced). Runs at 50 MHz like the game pad.
// ***********************************************

module gamepad_events (
	input					clk,
	input		[7:0]		btn,
	input		[11:0]	a0, a1, a2, a3, a4, wheel,
	output	[7:0]		tx_data,
	output				tx_valid,
	input					tx_ready
	);

localparam logic [8*6-1:0] NAME [0:7] = '{"A     ", "B     ", "SELECT", "START ", "DOWN  ", "UP    ", "RIGHT ", "LEFT  "};
localparam logic [2:0] CH [0:7] = '{3'd3, 3'd4, 3'd2, 3'd2, 3'd1, 3'd1, 3'd0, 3'd0};

function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction

reg	[7:0]		reported = 0;
reg	[11:0]	wheel_rep = 0;
reg	[2:0]		k;
reg				found;
reg	[8*28-1:0]	text;
reg				send = 0;
reg	[6:0]		len = 0;
wire				busy;
wire	[15:0]	wbcd;
reg	[11:0]	raw;
reg	[21:0]	gap = 0;			// at least ~80 ms between wheel lines

bin2bcd #(.BITS(12), .DIGITS(4)) wdec(.bin(wheel), .bcd(wbcd));

always_comb begin
	found = 0;
	k = 0;
	for (int i = 7; i >= 0; i--)
		if (btn[i] != reported[i]) begin found = 1; k = i[2:0]; end
	case (CH[k])
		3'd0: raw = a0;  3'd1: raw = a1;  3'd2: raw = a2;  3'd3: raw = a3;  default: raw = a4;
	endcase
end

wire	[11:0]	diff = (wheel > wheel_rep) ? wheel - wheel_rep : wheel_rep - wheel;

always @(posedge clk) begin
	send <= 0;
	if (gap != 0) gap <= gap - 1'b1;
	if (!busy && !send) begin
		if (found) begin
			text <= {btn[k] ? "PRESS   " : "RELEASE ", NAME[k], " ch", 8'h30 + CH[k], "=",
			         hx(raw[11:8]), hx(raw[7:4]), hx(raw[3:0]), {6{8'h20}}};	// 22 + 6 = 28
			len <= 7'd22;
			reported[k] <= btn[k];
			send <= 1;
		end
		else if (diff > 64 && gap == 0) begin		// the wheel reading jitters by ~33 steps
			text <= {"WHEEL   ", 8'h30 + wbcd[15:12], 8'h30 + wbcd[11:8], 8'h30 + wbcd[7:4], 8'h30 + wbcd[3:0], {16{8'h20}}};	// 12 + 16 = 28
			len <= 7'd12;
			wheel_rep <= wheel;
			gap <= 22'd4_000_000;
			send <= 1;
		end
	end
end

line_printer #(.MAXLEN(28)) printer(.clk(clk), .text(text), .len(len), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

endmodule
