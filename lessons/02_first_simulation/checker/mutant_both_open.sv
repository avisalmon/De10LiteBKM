// A wrong door alarm the checker uses to test the student's testbench: it also sounds when the system is OFF but
// the door and the window are both open. The given 6 test cases miss it.
module door_alarm (
	input  logic armed,
	input  logic door,
	input  logic window,
	output logic alarm
);
	assign alarm = armed & (door | window) | door & window;
endmodule
