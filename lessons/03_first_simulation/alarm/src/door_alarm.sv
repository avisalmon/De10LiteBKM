// The door alarm: the alarm sounds when the system is armed AND the door or the window is open.
//
//   armed   1 = the system is on
//   door    1 = the door is open
//   window  1 = the window is open
//   alarm   1 = sound the alarm
//
// Someone wrote this in a hurry. The testbench (../sim/tb_door_alarm.sv) says it is wrong. Find out why.

module door_alarm (
	input  logic armed,
	input  logic door,
	input  logic window,
	output logic alarm
);

	assign alarm = armed & door | window;

endmodule
