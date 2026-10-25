// The door alarm on the board: three switches in, one LED out.
//
//   SW2 = armed, SW1 = door open, SW0 = window open  ->  LEDR0 = alarm
//
// This top module only connects the board's switches and LEDs to door_alarm (you will write modules like this
// in lesson 4). The port names SW and LEDR are the board's own, so the chat's commands find every pin by itself.

module alarm_top (
	input  logic [9:0] SW,
	output logic [9:0] LEDR
);

	door_alarm alarm (.armed(SW[2]), .door(SW[1]), .window(SW[0]), .alarm(LEDR[0]));

	assign LEDR[9:1] = 9'b0;		// the other LEDs: off

endmodule
