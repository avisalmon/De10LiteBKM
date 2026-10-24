// Game pad + wheel of the LCD shield, read through the MAX 10 ADC
//
// Same decode as periphery_control.sv (Mor Dahan, Sep. 2022), plus the raw
// 12-bit readings so the channel map can be checked on the screen.
// ***********************************************

module gamepad (
	input					clk,		// 50 MHz: the ADC IP makes its 10 MHz from it (x1/5)
	output	[11:0]	a0,		// LEFT/RIGHT: Left = high, Right = middle, ~0 = nothing
	output	[11:0]	a1,		// UP/DOWN: Up = high, Down = middle
	output	[11:0]	a2,		// SELECT/START: Select = high, Start = middle
	output	[11:0]	a3,		// Button A, low = pressed
	output	[11:0]	a4,		// Button B, low = pressed
	output	[11:0]	wheel,	// the wheel knob, 0..4095
	output				A,
	output				B,
	output				Select,
	output				Start,
	output				Right,
	output				Left,
	output				Up,
	output				Down
	);

analog_input analog_input_inst(
	.clk(clk),
	.a0(a0),
	.a1(a1),
	.a2(a2),
	.a3(a3),
	.a4(a4),
	.a5(wheel)
	);

assign A      = a3 < 2048;
assign B      = a4 < 2048;
assign Select = a2 > 12'hCFF;
assign Start  = a2 < 12'hCFF & a2 > 12'h5FF;
assign Left   = a0 > 12'hCFF;
assign Right  = a0 < 12'hCFF & a0 > 12'h5FF;
assign Up     = a1 > 12'hCFF;
assign Down   = a1 < 12'hCFF & a1 > 12'h5FF;

endmodule
