// Lesson 1 hunt: plays the whole hunt in simulation, checks wrong answers do not count, and that a brief touch
// (shorter than HOLD) does not count either.
// Run:  python scripts/sim.py lessons/01_what_is_fpga/hunt/sim/tb_hunt_logic.sv --modelsim
// sim-sources: ../src/hunt_logic.sv
`timescale 1ns/1ns

module tb_hunt_logic;

reg				clk = 0;
reg	[9:0]		sw = 10'h3FF;
reg	[1:0]		key = 0;
reg				up = 0, left = 0, a = 0, b = 0, start = 0, select = 0;
reg	[11:0]	wheel = 12'd2000;
wire	[3:0]		step;
wire				step_done, beep;
integer			errors = 0, passed = 0;

always #10 clk = ~clk;
always @(posedge clk) if (step_done) passed = passed + 1;

hunt_logic #(.HOLD(20), .BEEP(5)) dut(.clk(clk), .sw(sw), .key(key), .up(up), .left(left), .a(a), .b(b),
	.start(start), .select(select), .wheel(wheel), .step(step), .step_done(step_done), .beep(beep));

task expect_step(input [3:0] want, input [8*24-1:0] what);
	begin
		if (step !== want) begin
			errors = errors + 1;
			$display("FAIL after %0s: step %0d, want %0d", what, step, want);
		end
		else
			$display("ok  %0s -> step %0d", what, step);
	end
endtask

initial begin
	repeat (40) @(negedge clk);
	expect_step(0, "switches up (wrong)");
	sw = 0;               repeat (30) @(negedge clk); expect_step(1, "all switches down");
	sw = 10'b10;          repeat (30) @(negedge clk); expect_step(1, "SW1 instead of SW0");
	sw = 10'b1;           repeat (30) @(negedge clk); expect_step(2, "SW0 up");
	sw = 10'b1000000000;  repeat (30) @(negedge clk); expect_step(3, "only SW9 up");
	sw = 10'd5;           repeat (30) @(negedge clk); expect_step(4, "5 in binary");
	key = 2'b01; repeat (5) @(negedge clk); key = 0; repeat (30) @(negedge clk); expect_step(4, "KEY0 brushed");
	key = 2'b01;          repeat (30) @(negedge clk); expect_step(5, "KEY0 held");
	key = 2'b10;          repeat (30) @(negedge clk); expect_step(6, "KEY1"); key = 0;
	up = 1;               repeat (30) @(negedge clk); expect_step(7, "joystick up"); up = 0;
	left = 1;             repeat (30) @(negedge clk); expect_step(8, "joystick left"); left = 0;
	a = 1;                repeat (30) @(negedge clk); expect_step(9, "A"); a = 0;
	b = 1;                repeat (30) @(negedge clk); expect_step(10, "B"); b = 0;
	start = 1;            repeat (30) @(negedge clk); expect_step(11, "Start"); start = 0;
	wheel = 12'd3000;     repeat (30) @(negedge clk); expect_step(11, "wheel half way");
	wheel = 12'd4095;     repeat (30) @(negedge clk); expect_step(12, "wheel full");
	wheel = 12'd10;       repeat (30) @(negedge clk); expect_step(13, "wheel empty");
	if (passed !== 13) begin errors = errors + 1; $display("FAIL: %0d step_done pulses, want 13", passed); end
	select = 1;           repeat (5) @(negedge clk);  expect_step(0, "Select: play again"); select = 0;
	if (errors == 0) $display("PASS: the hunt runs all 13 steps and ignores wrong or brief answers");
	else             $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule
