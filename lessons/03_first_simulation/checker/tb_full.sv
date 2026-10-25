// The checker's own testbench: all 8 input combinations, against the rule "armed AND (door OR window)".
// Used by check_alarm.py --design; the student never edits this file.
// sim-sources: ../src/door_alarm.sv
`timescale 1ns/1ns

module tb_full;

	logic armed, door, window, alarm;
	integer i, errors = 0;

	door_alarm dut (.armed(armed), .door(door), .window(window), .alarm(alarm));

	initial begin
		for (i = 0; i < 8; i = i + 1) begin
			{armed, door, window} = i[2:0];
			#10;
			if (alarm !== (armed & (door | window))) begin
				$display("WRONG armed=%b door=%b window=%b -> alarm=%b, expected %b", armed, door, window, alarm,
				         armed & (door | window));
				errors = errors + 1;
			end
		end
		if (errors == 0) $display("PASS: all 8 combinations right");
		else             $display("FAIL: %0d of 8 combinations wrong", errors);
		$finish;
	end

endmodule
