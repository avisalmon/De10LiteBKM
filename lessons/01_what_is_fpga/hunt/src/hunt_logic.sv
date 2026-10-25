// Lesson 1 board hunt: the steps, one challenge at a time
//
// Each step waits until its condition has held for HOLD clocks (so a bounce or a brush does not count), beeps,
// then moves on. Step 13 is the end: SELECT starts over. step_done pulses for one clock as each step is passed.
// All inputs are already debounced (1 = pressed / up). Runs at 50 MHz.
// ***********************************************

module hunt_logic #(
	parameter HOLD = 10_000_000,		// 0.2 s at 50 MHz
	parameter BEEP = 5_000_000			// 0.1 s success beep
)(
	input						clk,
	input			[9:0]		sw,
	input			[1:0]		key,
	input						up, left, a, b, start, select,
	input			[11:0]	wheel,
	output reg	[3:0]		step = 0,
	output reg				step_done = 0,
	output					beep
	);

localparam LAST = 13;

reg				ok;
always @(*) begin
	case (step)
		0:  ok = sw == 10'b0000000000;
		1:  ok = sw == 10'b0000000001;
		2:  ok = sw == 10'b1000000000;
		3:  ok = sw == 10'd5;
		4:  ok = key[0];
		5:  ok = key[1];
		6:  ok = up;
		7:  ok = left;
		8:  ok = a;
		9:  ok = b;
		10: ok = start;
		11: ok = wheel > 12'd3900;
		12: ok = wheel < 12'd200;
		default: ok = 0;
	endcase
end

reg	[$clog2(HOLD+1)-1:0]	held = 0;
reg	[$clog2(BEEP+1)-1:0]	beeping = 0;
assign beep = beeping != 0;

always @(posedge clk) begin
	step_done <= 0;
	if (beeping != 0)
		beeping <= beeping - 1'b1;

	if (step == LAST) begin
		if (select) step <= 0;
		held <= 0;
	end
	else if (!ok)
		held <= 0;
	else if (held == HOLD - 1) begin
		held <= 0;
		step <= step + 1'b1;
		step_done <= 1;
		beeping <= BEEP;
	end
	else
		held <= held + 1'b1;
end

endmodule
