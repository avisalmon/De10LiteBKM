// Unit test: rom_screen draws the two pictures and the text from their ROMs at the right places.
// Needs ModelSim (picture B is the altsyncram IP):  python scripts/sim.py examples/02_rom/sim/tb_rom_screen.sv --modelsim
// sim-sources: lib/rtl/font8x8.sv lib/rtl/rom_ip.v ../src/rom_screen.sv
`timescale 1ns/1ns

module tb_rom_screen;

reg				clk = 0;
reg	[31:0]	x = 0, y = 0;
wire	[3:0]		R, G, B;
reg	[11:0]	chip [0:4095];
integer			errors = 0, checks = 0, i, px, py, f;

always #20 clk = ~clk;

rom_screen #(.TEXT_FILE("../assets/text.hex"), .IMG_A_FILE("../assets/chip.hex"), .IMG_B_MIF("../assets/chip.mif"))
	dut(.clk(clk), .pxl_x(x), .pxl_y(y), .Red(R), .Green(G), .Blue(B));

// the VGA controller moves one pixel per clock: model that, then look at the colour of (x, y)
task show(input integer sx, input integer sy, output [11:0] rgb);
	begin
		@(negedge clk) begin x = sx - 1; y = sy; end
		@(negedge clk) x = sx;		// the ROMs fetched (sx) during the previous clock
		#1 rgb = {R, G, B};
	end
endtask

reg [11:0] got, want;
initial begin
	$readmemh("../assets/chip.hex", chip);
	for (i = 0; i < 40; i = i + 1) begin
		px = (i * 37) % 64;  py = (i * 23) % 64;
		want = chip[py * 64 + px];
		if (want == 12'h000) want = 12'h113;			// transparent shows the background
		show(48 + px * 4 + 1, 112 + py * 4 + 2, got);	// picture A
		checks = checks + 1;
		if (got !== want) begin errors = errors + 1; $display("A(%0d,%0d): got %h want %h", px, py, got, want); end
		show(336 + px * 4 + 2, 112 + py * 4 + 1, got);	// picture B (same picture at power-up)
		checks = checks + 1;
		if (got !== want) begin errors = errors + 1; $display("B(%0d,%0d): got %h want %h", px, py, got, want); end
	end
	// text: the "0" of "02 ROM" is character (2,1); glyph row 2 of "0" is 0x73, its leftmost dot is lit
	show(2 * 16 + 1, 1 * 16 + 4, got);
	checks = checks + 1;
	if (got !== 12'hFFF) begin errors = errors + 1; $display("text: got %h want FFF", got); end
	$display("%0d checks, %0d errors", checks, errors);
	if (errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

endmodule
