// Unit test: mag_px + mag_rom against the model, one (re, im) per clock
// python projects/fft_lab/sim/lab_model.py expect      (writes sim/expect_mag.hex: {re, im, off, lin, px})
// python scripts/sim.py projects/fft_lab/sim/tb_mag.sv
// sim-sources: ../src/mag_px.sv ../src/mag_rom.sv
`timescale 1ns/1ns

module tb_mag;

logic				clk = 0, in_valid = 0, lin = 0;
logic	[7:0]		in_k = 0;
logic signed [15:0]	re = 0, im = 0;
logic signed [7:0]	off = 0;
wire	[11:0]	rom_addr;
wire	[6:0]		rom_q, q_b, px;
wire				out_valid;
wire	[7:0]		out_k;
logic	[47:0]	ex [0:8191];
integer			i, fd, nv = 0, got = 0, errs = 0, lat = 0, t_in = 0;

always #20 clk = ~clk;

mag_px dut(.clk(clk), .in_valid(in_valid), .in_k(in_k), .re(re), .im(im), .off(off), .lin(lin),
	.rom_addr(rom_addr), .rom_q(rom_q), .out_valid(out_valid), .out_k(out_k), .px(px));
mag_rom #(.FILE("../assets/mag_rom.bin")) rom(.clk(clk), .addr_a(rom_addr), .q_a(rom_q), .addr_b(12'd0), .q_b(q_b));

always @(posedge clk) begin
	if (in_valid && t_in == 0) t_in = $time;
	if (out_valid) begin
		if (got == 0) lat = ($time - t_in) / 40;
		if (px !== ex[got][6:0] || out_k !== got[7:0]) begin
			errs = errs + 1;
			if (errs <= 10)
				$display("FAIL: vector %0d re=%0d im=%0d off=%0d lin=%0d: px=%0d k=%0d, model px=%0d", got,
					$signed(ex[got][47:32]), $signed(ex[got][31:16]), $signed(ex[got][15:8]), ex[got][7],
					px, out_k, ex[got][6:0]);
		end
		got = got + 1;
	end
end

initial begin
	fd = $fopen("expect_mag.hex", "r");
	if (fd) begin
		while (nv < 8192 && $fscanf(fd, "%h\n", ex[nv]) == 1) nv = nv + 1;
		$fclose(fd);
	end
	if (nv == 0) begin $display("FAIL: no vectors in expect_mag.hex (run lab_model.py expect)"); $finish; end
	repeat (3) @(negedge clk);
	for (i = 0; i < nv; i = i + 1)
		@(negedge clk) begin in_valid = 1; in_k = i[7:0]; {re, im, off, lin} = ex[i][47:7]; end
	@(negedge clk) in_valid = 0;
	repeat (10) @(negedge clk);
	if (got != nv) begin $display("FAIL: %0d results for %0d vectors", got, nv); errs = errs + 1; end
	if (lat != 6) begin $display("FAIL: latency %0d clocks, expected 6", lat); errs = errs + 1; end
	if (errs == 0) $display("PASS: mag_px: %0d of %0d bar heights equal the model, latency %0d", got, nv, lat);
	else $display("FAIL: mag_px: %0d errors", errs);
	$finish;
end

endmodule
