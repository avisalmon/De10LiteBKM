// Renders the frame the board should show for a box position: 320x240 = every 2nd pixel, like the capture.
// python scripts/sim.py examples/05_screen_readback/sim/tb_frame.sv -D BX=64 -D BY=192   -> sim/expected.ppm
// sim-sources: lib/rtl/font8x8.sv ../src/test_card.sv
`timescale 1ns/1ns
`ifndef BX
`define BX 64
`endif
`ifndef BY
`define BY 192
`endif

module tb_frame;

reg	[31:0]	x = 0, y = 0;
wire	[11:0]	rgb;
integer			f, i, j;

test_card dut(.pxl_x(x), .pxl_y(y), .bx(10'd`BX), .by(9'd`BY), .rgb(rgb));

initial begin
	f = $fopen("expected.ppm", "w");
	$fwrite(f, "P3\n320 240\n15\n");
	for (j = 0; j < 480; j = j + 2)
		for (i = 0; i < 640; i = i + 2) begin
			x = i; y = j; #1;
			$fwrite(f, "%0d %0d %0d\n", rgb[11:8], rgb[7:4], rgb[3:0]);
		end
	$fclose(f);
	$display("expected.ppm: box at (%0d, %0d)", `BX, `BY);
	$display("PASS");
	$finish;
end

endmodule
