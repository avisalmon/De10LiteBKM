// Testbench for door_alarm: a module that is never built into the chip. It plays with the inputs and checks
// the output, and ModelSim runs it.
//
// Run it in the chat:   python scripts/sim.py my_designs/lessons/03_first_simulation/alarm/sim/tb_door_alarm.sv --modelsim
// (add --gui to see the waveform)
// sim-sources: ../src/door_alarm.sv
`timescale 1ns/1ns

module tb_door_alarm;

	// wires and registers to plug into the design under test
	logic armed, door, window;
	logic alarm;
	integer errors = 0;

	// the design under test ("dut")
	door_alarm dut (.armed(armed), .door(door), .window(window), .alarm(alarm));

	// one test case: set the inputs, wait 10 ns, compare the output with what we expect
	task check(input logic a, input logic d, input logic w, input logic expected);
		armed = a; door = d; window = w;
		#10;
		if (alarm === expected)
			$display("ok    armed=%b door=%b window=%b  ->  alarm=%b", a, d, w, alarm);
		else begin
			$display("WRONG armed=%b door=%b window=%b  ->  alarm=%b, expected %b", a, d, w, alarm, expected);
			errors = errors + 1;
		end
	endtask

	initial begin
		//     armed door window  expected alarm
		check(0,    0,   0,      0);     // off, all closed: quiet
		check(0,    0,   1,      0);     // off, window open: quiet (the system is off)
		check(0,    1,   0,      0);     // off, door open: quiet
		check(1,    0,   0,      0);     // on, all closed: quiet
		check(1,    0,   1,      1);     // on, window open: ALARM
		check(1,    1,   0,      1);     // on, door open: ALARM
		// (two more cases go here)

		if (errors == 0) $display("PASS: door_alarm passed every test case");
		else             $display("FAIL: %0d test case(s) wrong", errors);
		$stop;		// pause here: in ModelSim's window you can look around; the chat's command then quits
	end

endmodule
