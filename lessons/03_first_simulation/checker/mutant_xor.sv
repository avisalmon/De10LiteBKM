// A wrong door alarm the checker uses to test the student's testbench: XOR instead of OR, so the alarm stays
// quiet when the system is on and the door AND the window are both open. The given 6 test cases miss it.
module door_alarm (
	input  logic armed,
	input  logic door,
	input  logic window,
	output logic alarm
);
	assign alarm = armed & (door ^ window);
endmodule
