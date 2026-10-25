// Lesson 2: your first FPGA project
//
// One switch drives one LED. There is no logic at all: the LED is simply connected to the switch.
// sw0 and led0 are names we chose. The Pin Planner connects them to the real pins:
//   sw0  -> PIN_C10 (switch SW0 on the board)
//   led0 -> PIN_A8  (red LED LEDR0 on the board)
// ***********************************************

module first_led (
	input		sw0,
	output	led0
	);

assign led0 = sw0;		// the LED shows what the switch says

endmodule
