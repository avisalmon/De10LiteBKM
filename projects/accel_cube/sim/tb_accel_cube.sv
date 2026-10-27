// The accelerometer cube without the FPGA: the real VGA timing (lib vga_controller) drives cube_core, the
// testbench selects the eight test presets over the "USB" letters '0'..'7' in order, captures every frame
// the way the board's screen capture does (every 2nd pixel and line, 320 x 240), writes it as frame_n.ppm,
// hashes it and compares the hash with the one assets/model.py computes for the same preset sequence
// (python projects/accel_cube/assets/model.py hashes). Then the live path, one frame compared the same way
// at each step: 120 sensor samples of one vector through the filter (frame_live.ppm), KEY1 calibrates
// with that as flat (frame_cal.ppm), one different sample shows the steady and the live vectors apart
// (frame_calb.ppm), the 'r' report line character for character, 'u' forgets the calibration
// (frame_u.ppm), 'c' calibrates again (the offsets checked), 's' spins the view (frame_spin.ppm, one step
// on) and 's' stops it. PASS = every picture and the report are bit-exact.
//   python scripts/sim.py projects/accel_cube/sim/tb_accel_cube.sv            (from the repo root)
//   on a mismatch: python projects/accel_cube/assets/model.py compare seq:3 projects/accel_cube/sim/frame_3.ppm diff.png
// sim-sources: lib/rtl/vga_controller.v lib/rtl/font8x8.sv lib/rtl/bin2bcd_seq.sv lib/rtl/line_printer.sv lib/rtl/seg7_char.sv ../src/cube_units.sv ../src/cube_math.sv ../src/cube_text.sv ../src/cube_draw.sv ../src/cube_core.sv
`timescale 1ns/1ns
`default_nettype none

module tb_accel_cube;

logic clk = 0;
always #20 clk = ~clk;					// 25 MHz

logic rst = 1, reset_n = 0;
logic rx_valid = 0, acc_valid = 0;
logic [7:0] rx_data = 8'd0;
logic signed [15:0] acc_x = 16'sd0, acc_y = 16'sd0, acc_z = 16'sd0;
logic [1:0] key = 2'b00;
wire h_sync, v_sync, disp_ena;
wire [31:0] column, row;
wire [11:0] rgb;
wire [9:0] leds;
wire [47:0] hex;
wire [7:0] p_data;
wire p_valid, status_led;

vga_controller vga(.pixel_clk(clk), .reset_n(reset_n), .h_sync(h_sync), .v_sync(v_sync), .disp_ena(disp_ena),
	.column(column), .row(row));

logic vs_d = 1;
always @(posedge clk) vs_d <= v_sync;
wire tick = vs_d && !v_sync;

cube_core #(.HEADING(0)) core(.clk(clk), .rst(rst), .tick(tick), .pxl_x(column), .pxl_y(row),
	.acc_x(acc_x), .acc_y(acc_y), .acc_z(acc_z), .acc_valid(acc_valid), .devid(8'hE5),
	.key(key), .rx_data(rx_data), .rx_valid(rx_valid),
	.p_data(p_data), .p_valid(p_valid), .p_ready(1'b1),
	.rgb(rgb), .leds(leds), .hex(hex), .status_led(status_led));

// the report line, as the USB would receive it
logic [8*128-1:0] rep = '0;
integer rlen = 0;
always @(posedge clk) if (p_valid) begin
	rep <= {rep[8*127-1:0], p_data};
	rlen <= rlen + 1;
end

// the frame hashes assets/model.py computes for presets 0..7 shown in this order (model.py hashes)
function automatic [31:0] want(input integer p);
	case (p)
		0: want = 32'h51f5162d;  1: want = 32'h342b1f12;  2: want = 32'h3688ea15;  3: want = 32'he137bbda;
		4: want = 32'h52b2a954;  5: want = 32'hc376dce4;  6: want = 32'h4392beb8;  default: want = 32'h5cf4aea7;
	endcase
endfunction
// the live path: raw samples V = (300, -200, 900) = Q4 (4800, -3200, 14400), 3.8 g, then one sample
// B = (100, 100, 1000). Each frame's hash from `python projects/accel_cube/assets/model.py render <case> x.png`:
//   q:4800,-3200,14400                       WANT_LIVE    the filter settled on V, both vectors V x 16
//   cal:0,0,4096                             WANT_CAL     calibrated on V: flat, 1 g
//   ema:300,-200,900;100,100,1000;1;cal      WANT_CALB    B after V, calibrated: g moved 1/8 of the way, a is B
//   (the same case with `model.py report`)   WANT_REPORT
//   ema:300,-200,900;100,100,1000;1          WANT_U       the same, the calibration forgotten
//   ema:300,-200,900;100,100,1000;1@5552     WANT_SPIN    the same, the view yaw VIEW_YAW + SPIN_STEP
localparam [31:0] WANT_LIVE = 32'h0e21cda7, WANT_CAL = 32'h8a24fe65, WANT_CALB = 32'h9269c928,
	WANT_U = 32'h1114235f, WANT_SPIN = 32'h59d938ac;
localparam [8*114-1:0] WANT_REPORT =
	"AQ -03200 +04800 +05696 X-0.781 Y+1.172 Z+1.391 MAG 1.979 PEAK 1.979 PITCH  +5.3 ROLL  +7.9 ID E5 LIVE CAL        ";

integer errors = 0, n, f, got, cycles;
logic [31:0] h;
logic [8*32-1:0] name;

task automatic letter(input [7:0] c);
	@(negedge clk) begin rx_data = c; rx_valid = 1; end
	@(negedge clk) rx_valid = 0;
endtask

task automatic sample(input signed [15:0] x, input signed [15:0] y, input signed [15:0] z);
	@(negedge clk) begin acc_x = x; acc_y = y; acc_z = z; acc_valid = 1; end
	@(negedge clk) acc_valid = 0;
	repeat (6) @(negedge clk);
endtask

task automatic press_key1;		// a KEY1 press as the top's synchroniser delivers it: a rising edge, then the release
	@(negedge clk) key[1] = 1'b1;
	repeat (4) @(negedge clk);
	key[1] = 1'b0;
	@(negedge clk);
endtask

task automatic wait_tick;
	@(negedge clk);
	while (!tick) @(negedge clk);
endtask

task automatic check_vec(input [8*24-1:0] what, input signed [15:0] x, input signed [15:0] y, input signed [15:0] z,
		input signed [15:0] wx, input signed [15:0] wy, input signed [15:0] wz);
	if (x == wx && y == wy && z == wz)
		$display("ok:   %0s = %0d %0d %0d", what, x, y, z);
	else begin
		errors = errors + 1;
		$display("FAIL: %0s = %0d %0d %0d, want %0d %0d %0d", what, x, y, z, wx, wy, wz);
	end
endtask

// capture the next frame like debug_link: pixel (0, 0) first, then every even column of every even row
task automatic capture(input [8*32-1:0] nm, input [31:0] want_h);
	begin
		name = nm;
		f = $fopen(name, "w");
		$fwrite(f, "P3\n320 240\n15\n");
		h = 32'd0;
		got = 0;
		@(negedge clk);
		while (!(disp_ena && column == 32'd0 && row == 32'd0)) @(negedge clk);
		while (got < 76800) begin
			if (disp_ena && column[0] == 1'b0 && row[0] == 1'b0 && column < 32'd640 && row < 32'd480) begin
				$fwrite(f, "%0d %0d %0d\n", rgb[11:8], rgb[7:4], rgb[3:0]);
				h = h * 32'd33 + {20'd0, rgb};
				got = got + 1;
			end
			@(negedge clk);
		end
		$fclose(f);
		if (h == want_h)
			$display("ok:   %0s hash %08h matches the model", name, h);
		else begin
			errors = errors + 1;
			$display("FAIL: %0s hash %08h, model %08h", name, h, want_h);
		end
	end
endtask

initial begin
	repeat (4) @(negedge clk);
	reset_n = 1;
	repeat (4) @(negedge clk);
	rst = 0;
	for (n = 0; n < 8; n = n + 1) begin
		letter(8'h30 + n[7:0]);				// '0' + n
		wait_tick;									// this frame is computed with the preset
		wait_tick;									// and shown from here
		$sformat(name, "frame_%0d.ppm", n);
		capture(name, want(n));
	end

	// live: the filter settles on a constant input (1/8 of the way per sample) within 120 samples;
	// uncalibrated, the steady vector g and the live vector a are the same: the input x 16
	letter("l");
	repeat (120) sample(16'sd300, -16'sd200, 16'sd900);
	wait_tick;
	wait_tick;
	capture("frame_live.ppm", WANT_LIVE);
	check_vec("g after 120 samples", core.gx, core.gy, core.gz, 16'sd4800, -16'sd3200, 16'sd14400);
	check_vec("a after 120 samples", core.ax, core.ay, core.az, 16'sd4800, -16'sd3200, 16'sd14400);

	// KEY1 calibrates: the filtered vector becomes the offsets, so the board now reads flat, 1 g
	press_key1;
	wait_tick;
	wait_tick;
	capture("frame_cal.ppm", WANT_CAL);
	check_vec("g calibrated", core.gx, core.gy, core.gz, 16'sd0, 16'sd0, 16'sd4096);
	check_vec("a calibrated", core.ax, core.ay, core.az, 16'sd0, 16'sd0, 16'sd4096);
	if (core.cal && core.ox == 20'sd4800 && core.oy == -20'sd3200 && core.oz == 20'sd10304)
		$display("ok:   KEY1 stored the offsets 4800 -3200 10304 (CAL)");
	else begin
		errors = errors + 1;
		$display("FAIL: cal %0d offsets %0d %0d %0d, want 1 and 4800 -3200 10304", core.cal, core.ox, core.oy, core.oz);
	end

	// one different sample: the steady g moves 1/8 of the way, the live a jumps all the way (minus offsets)
	sample(16'sd100, 16'sd100, 16'sd1000);
	wait_tick;
	wait_tick;
	capture("frame_calb.ppm", WANT_CALB);
	check_vec("g one sample later", core.gx, core.gy, core.gz, -16'sd400, 16'sd600, 16'sd4296);
	check_vec("a one sample later", core.ax, core.ay, core.az, -16'sd3200, 16'sd4800, 16'sd5696);

	// the report line ('r') with the same numbers
	letter("r");
	cycles = 0;
	while (rlen < 116 && cycles < 20000) begin @(negedge clk); cycles = cycles + 1; end
	$display("report: %0s", rep[8*116-1:16]);
	if (rlen == 116 && rep[15:0] == 16'h0D0A && rep[8*116-1:16] == WANT_REPORT)
		$display("ok:   the report is the model's 114 characters + CR LF");
	else begin
		errors = errors + 1;
		$display("FAIL: report length %0d, tail %04h, want\n        %0s", rlen, rep[15:0], WANT_REPORT);
	end

	// 'u' forgets the calibration: both vectors back to the sensor's own numbers
	letter("u");
	wait_tick;
	wait_tick;
	capture("frame_u.ppm", WANT_U);
	check_vec("g uncalibrated", core.gx, core.gy, core.gz, 16'sd4400, -16'sd2600, 16'sd14600);
	check_vec("a uncalibrated", core.ax, core.ay, core.az, 16'sd1600, 16'sd1600, 16'sd16000);

	// 'c' calibrates again, now on the moved filter output; then forget it again for the spin frame
	letter("c");
	if (core.cal && core.ox == 20'sd4400 && core.oy == -20'sd2600 && core.oz == 20'sd10504)
		$display("ok:   'c' stored the offsets 4400 -2600 10504");
	else begin
		errors = errors + 1;
		$display("FAIL: after 'c': cal %0d offsets %0d %0d %0d, want 1 and 4400 -2600 10504", core.cal, core.ox, core.oy, core.oz);
	end
	letter("u");
	if (!core.cal && core.ox == 20'sd0 && core.oy == 20'sd0 && core.oz == 20'sd0)
		$display("ok:   'u' cleared the offsets");
	else begin
		errors = errors + 1;
		$display("FAIL: after 'u': cal %0d offsets %0d %0d %0d", core.cal, core.ox, core.oy, core.oz);
	end

	// 's' starts the spin: the view yaw steps once per frame, the frame two ticks on has VIEW_YAW + 1 step
	letter("s");
	wait_tick;
	wait_tick;
	capture("frame_spin.ppm", WANT_SPIN);
	if (core.spin_on && core.spin == 16'sd5643)
		$display("ok:   the view yaw stepped to %0d while spinning", core.spin);
	else begin
		errors = errors + 1;
		$display("FAIL: spin_on %0d yaw %0d, want 1 and 5643", core.spin_on, core.spin);
	end
	// 's' again stops it: at the next tick the view returns to VIEW_YAW
	letter("s");
	wait_tick;
	@(negedge clk);
	if (!core.spin_on && core.spin == 16'sd5461)
		$display("ok:   the spin stopped, the view yaw is back at %0d", core.spin);
	else begin
		errors = errors + 1;
		$display("FAIL: spin_on %0d yaw %0d, want 0 and 5461", core.spin_on, core.spin);
	end

	if (status_led) begin
		errors = errors + 1;
		$display("FAIL: the math engine was late for a frame");
	end
	if (errors == 0) $display("PASS: 13 frames bit-exact with the model, calibration, report and spin checked");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule

`default_nettype wire
