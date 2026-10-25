// The right door alarm (the checker's reference): the student's testbench must PASS on it.
module door_alarm (
	input  logic armed,
	input  logic door,
	input  logic window,
	output logic alarm
);
	assign alarm = armed & (door | window);
endmodule
