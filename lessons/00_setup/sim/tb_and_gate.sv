// Lesson 0 simulation check: drives all four input pairs into and_gate and compares the output with the truth table.
// Run:  python scripts/sim.py lessons/00_setup/sim/tb_and_gate.sv --modelsim        (add --gui to see the waves)
// sim-sources: ./and_gate.sv
`timescale 1ns/1ns

module tb_and_gate;

reg			a, b;
wire			y;
integer		i, errors = 0;

and_gate dut(.a(a), .b(b), .y(y));

initial begin
	for (i = 0; i < 4; i = i + 1) begin
		{a, b} = i;
		#10;
		if (y !== (a & b)) begin
			errors = errors + 1;
			$display("a=%b b=%b: got y=%b, want %b", a, b, y, a & b);
		end
		else
			$display("a=%b b=%b -> y=%b  ok", a, b, y);
	end
	if (errors == 0) $display("PASS: and_gate matches its truth table");
	else             $display("FAIL: %0d wrong rows", errors);
	$finish;
end

endmodule
