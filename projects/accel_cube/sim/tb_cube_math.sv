// Unit test of the per-frame math engine against assets/model.py. Runs the 8 presets in order (the held
// orientation carries between them, as in the full testbench), then the 8 YAW_CASES (other view yaws, both
// sides of the CORDIC's +-90 degree pre-rotation, +-180 degrees, the peak kept across frames; the two
// vectors equal), then the 2 GA_CASES (the steady vector g differs from the live vector a: a shake, and a
// weak g that holds the cube), prints every per-frame value in the format of `python assets/model.py dump`
// and compares line by line with math_expected.txt (made by that command), so the first wrong number is
// named, not just a wrong frame. Also writes math_dump.txt for `model.py dumpcmp`.
// sim-sources: lib/rtl/bin2bcd_seq.sv ../src/cube_units.sv ../src/cube_math.sv
`timescale 1ns/1ns

module tb_cube_math;

logic clk = 1'b0;
always #20 clk = ~clk;
logic rst = 1'b1, start = 1'b0, peak_clr = 1'b0;
logic signed [15:0] gx = 16'sd0, gy = 16'sd0, gz = 16'sd0;
logic signed [15:0] ax = 16'sd0, ay = 16'sd0, az = 16'sd0, psi = 16'sd5461;		// VIEW_YAW
wire busy, done;
wire [2:0] slot_valid;
wire [2:0][11:0] slot_rgb;
wire [11:0][15:0] e_dx, e_dy;
wire [11:0][31:0] e_c;
wire [11:0][23:0] e_t;
wire [7:0] sg_valid, sg_dash;
wire [7:0][11:0] sg_rgb;
wire [7:0][17:0] sg_dx, sg_dy;
wire [7:0][31:0] sg_c;
wire [7:0][23:0] sg_t;
wire [7:0][9:0] sg_xmin, sg_xmax, sg_ymin, sg_ymax;
wire [6:0][15:0] bcd4;
wire [2:0][19:0] bcd5;
wire [4:0] neg;
wire [2:0][9:0] bar_len;
wire [2:0] bar_neg;
wire [15:0] mag;

cube_math dut(.clk(clk), .rst(rst), .start(start), .gx(gx), .gy(gy), .gz(gz), .ax(ax), .ay(ay), .az(az),
	.psi(psi), .peak_clr(peak_clr),
	.busy(busy), .done(done), .slot_valid(slot_valid), .slot_rgb(slot_rgb),
	.e_dx(e_dx), .e_dy(e_dy), .e_c(e_c), .e_t(e_t),
	.sg_valid(sg_valid), .sg_dash(sg_dash), .sg_rgb(sg_rgb), .sg_dx(sg_dx), .sg_dy(sg_dy), .sg_c(sg_c), .sg_t(sg_t),
	.sg_xmin(sg_xmin), .sg_xmax(sg_xmax), .sg_ymin(sg_ymin), .sg_ymax(sg_ymax),
	.bcd4(bcd4), .bcd5(bcd5), .neg(neg), .bar_len(bar_len), .bar_neg(bar_neg), .mag(mag));

integer errors = 0, fexp, fdump, cycles, n, i, j, c, lines = 0;
string got;
reg [8*160-1:0] want, gotv;		// $fgets wants a reg; a string assigned to a reg is right-justified, zero-padded

task check(input string line);				// one dump line: compare with the model's, keep it
	lines = lines + 1;
	$fdisplay(fdump, "%0s", line);
	if ($fgets(want, fexp) == 0) want = "<missing>";
	while (want[7:0] == 8'h0A || want[7:0] == 8'h0D) want = want >> 8;		// drop the line end $fgets keeps
	gotv = {8*160{1'b0}};
	for (c = 0; c < line.len(); c = c + 1) gotv = {gotv[8*159-1:0], line[c]};
	if (want != gotv) begin
		errors = errors + 1;
		if (errors <= 20) $display("FAIL line %0d:\n  want %0s\n  got  %0s", lines, want, line);
	end
endtask

task preset(input integer p);		// model.py PRESETS (0..7), YAW_CASES (8..15) and GA_CASES (16..17), Q4 counts
	psi = 16'sd5461;				// VIEW_YAW
	case (p)
		0: begin ax = 16'sd0;    ay = 16'sd0;     az = 16'sd4096;  end
		1: begin ax = -16'sd2048; ay = 16'sd0;    az = 16'sd3547;  end
		2: begin ax = 16'sd0;    ay = 16'sd2048;  az = 16'sd3547;  end
		3: begin ax = 16'sd0;    ay = 16'sd0;     az = -16'sd4096; end
		4: begin ax = 16'sd4096; ay = 16'sd0;     az = 16'sd0;     end
		5: begin ax = 16'sd2365; ay = 16'sd2365;  az = 16'sd2365;  end
		6: begin ax = 16'sd4800; ay = -16'sd3200; az = 16'sd6400;  end
		7: begin ax = 16'sd0;    ay = 16'sd200;   az = 16'sd300;   end
		8:  begin ax = 16'sd2048;  ay = 16'sd1024;  az = 16'sd3200;  psi = 16'sd0;      end
		9:  begin ax = 16'sd2048;  ay = 16'sd1024;  az = 16'sd3200;  psi = 16'sd16384;  end
		10: begin ax = 16'sd2048;  ay = 16'sd1024;  az = 16'sd3200;  psi = 16'sd16385;  end
		11: begin ax = -16'sd1500; ay = 16'sd2500;  az = -16'sd2000; psi = -16'sd16384; end
		12: begin ax = -16'sd1500; ay = 16'sd2500;  az = -16'sd2000; psi = -16'sd16385; end
		13: begin ax = 16'sd4800;  ay = -16'sd3200; az = 16'sd6400;  psi = 16'sd32767;  end
		14: begin ax = 16'sd0;     ay = 16'sd0;     az = 16'sd4096;  psi = 16'sh8000;   end	// -32768
		15: begin ax = 16'sd300;   ay = -16'sd200;  az = 16'sd900;   psi = 16'sd23661;  end
		16: begin ax = -16'sd3200; ay = 16'sd4800;  az = 16'sd5696;  end	// a small tilt, a 2 g shake
		default: begin ax = 16'sd4800; ay = -16'sd3200; az = 16'sd14400; end	// |g| < 0.25 g holds the cube
	endcase
	case (p)							// the steady vector: equal to the live one except in the GA_CASES
		16: begin gx = -16'sd400; gy = 16'sd600; gz = 16'sd4296; end
		17: begin gx = 16'sd0;    gy = 16'sd200; gz = 16'sd300;  end
		default: begin gx = ax; gy = ay; gz = az; end
	endcase
endtask

task dump_frame(input integer fr);
	integer cnt;
	logic [11:0] col;
	check($sformatf("frame %0d", fr));
	check($sformatf("mag %0d g %0d r %0d", dut.mag_a, dut.mag_g, dut.r_g));
	check($sformatf("ang %0d %0d %0d %0d", dut.sth, dut.cth, dut.sph, dut.cph));
	check($sformatf("pr %0d %0d %0d %0d", dut.pitch, dut.roll, dut.cps, dut.sps));
	got = "p";
	for (i = 0; i < 9; i = i + 1) got = {got, $sformatf(" %0d", dut.pm[i])};
	check(got);
	got = "v";
	for (i = 0; i < 8; i = i + 1) got = {got, $sformatf(" %0d %0d", dut.vx[i], dut.vy[i])};
	check(got);
	cnt = slot_valid[0] + slot_valid[1] + slot_valid[2];
	check($sformatf("slots %0d", cnt));
	for (i = 0; i < cnt; i = i + 1) begin
		col = slot_rgb[i];
		check($sformatf("slot %0d %0d %0d %0d", i, col[11:8], col[7:4], col[3:0]));
		for (j = 0; j < 4; j = j + 1)
			check($sformatf("edge %0d %0d %0d %0d %0d %0d", i, j, $signed(e_dx[4 * i + j]), $signed(e_dy[4 * i + j]),
				$signed(e_c[4 * i + j]), e_t[4 * i + j]));
	end
	check($sformatf("nums %04h %0d %04h %0d %04h %0d %04h 0 %04h 0 %04h %0d %04h %0d",
		bcd4[0], neg[0], bcd4[1], neg[1], bcd4[2], neg[2], bcd4[3], bcd4[4],
		bcd4[5], neg[3], bcd4[6], neg[4]));
	check($sformatf("aq %05h %0d %05h %0d %05h %0d", bcd5[0], neg[0], bcd5[1], neg[1], bcd5[2], neg[2]));
	check($sformatf("bars %0d %0d %0d %0d %0d %0d", bar_len[0], bar_neg[0], bar_len[1], bar_neg[1],
		bar_len[2], bar_neg[2]));
	for (i = 0; i < 8; i = i + 1)
		check($sformatf("seg %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %03h", i, sg_valid[i], sg_dash[i],
			$signed(sg_dx[i]), $signed(sg_dy[i]), $signed(sg_c[i]), sg_t[i],
			sg_xmin[i], sg_xmax[i], sg_ymin[i], sg_ymax[i], sg_rgb[i]));
endtask

initial begin
	fexp = $fopen("math_expected.txt", "r");
	fdump = $fopen("math_dump.txt", "w");
	if (fexp == 0) begin
		$display("FAIL: math_expected.txt not found: python assets/model.py dump > sim/math_expected.txt");
		$finish;
	end
	repeat (3) @(posedge clk);
	rst <= 1'b0;
	repeat (3) @(posedge clk);
	for (n = 0; n < 18; n = n + 1) begin
		preset(n);
		peak_clr <= (n < 8);		// a preset clears the peak (as the letter does); the other cases keep it
		start <= 1'b1;
		@(posedge clk);
		start <= 1'b0;
		peak_clr <= 1'b0;
		cycles = 1;
		while (!done) begin
			@(posedge clk);
			cycles = cycles + 1;
			if (cycles > 5000) begin
				$display("FAIL: no done after %0d cycles in frame %0d (phase %0d k %0d)", cycles, n, dut.phase, dut.k);
				$finish;
			end
		end
		@(posedge clk);
		if (busy) begin errors = errors + 1; $display("FAIL: busy after done"); end
		$display("frame %0d: %0d cycles", n, cycles);
		dump_frame(n);
	end
	if ($fgets(want, fexp) != 0) begin errors = errors + 1; $display("FAIL: the model has more lines"); end
	$fclose(fexp);
	$fclose(fdump);
	if (errors == 0) $display("PASS: %0d lines match the model", lines);
	else $display("FAIL: %0d lines differ", errors);
	$finish;
end

endmodule
