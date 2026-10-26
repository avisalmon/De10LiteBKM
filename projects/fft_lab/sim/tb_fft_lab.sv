// System testbench of the FFT lab (Icarus Verilog): fft_lab_core, with the Altera IP replaced by its recording
//
// It uses the lab the way a person would: USB letters, the game pad, the KEYs, the wheel, hold and sound, and an
// IP that stops (no answer, then the watchdog; an answer of zeros) and is restarted. It checks the controls, the
// LEDs, the 7-segment digits, the buzzer and the timing (every frame is computed and published inside the
// vertical blanking time: 28,000 clocks), renders the screen into PPM pictures the way the board's screen
// capture sees it, and logs every published frame, picture and report line into tb_fft_lab.log.
// sim/check_tb.py runs it and compares every picture (pixel by pixel) and every report line with the model.
// The IP: sim/fft256_replay.sv answers with what the real IP answered for the same input (sim/ip_vectors.hex,
// recorded in ModelSim by sim/record_ip.py); for an input it has no recording of, it does not answer.
//   python projects/fft_lab/sim/check_tb.py          (or only the testbench: python scripts/sim.py <this file>)
// sim-sources: lib/rtl/font8x8.sv lib/rtl/bin2bcd_seq.sv lib/rtl/line_printer.sv lib/rtl/seven_segment.sv ../src/fft_r2.sv ../src/wave_gen.sv ../src/mag_rom.sv ../src/mag_px.sv ../src/lab_engine.sv ../src/lab_ctrl.sv ../src/lab_digits.sv ../src/lab_draw.sv ../src/fft_lab_core.sv ./fft256_replay.sv
`timescale 1ns/1ns
`default_nettype none

module tb_fft_lab;

localparam BUDGET = 28000;			// clocks from the frame tick (start of vertical sync) to the first visible line
localparam A = 0, B = 1, SELECT = 2, START = 3, DOWN = 4, UP = 5, RIGHT = 6, LEFT = 7;

logic				clk = 0;
always #20 clk = ~clk;				// 25 MHz

logic				rst_hold = 1, tick = 0, rx_valid = 0, p_ready = 1;
logic	[31:0]	pxl_x = 32'd639, pxl_y = 32'd479;
logic	[7:0]		btn = 8'd0, rx_data = 8'd0;
logic	[1:0]		key = 2'd0;
logic	[11:0]	wheel = 12'd2000;
wire	[7:0]		p_data;
wire				p_valid, buzz, status_led;
wire	[11:0]	rgb;
wire	[9:0]		leds;
wire	[47:0]	hex;

fft_lab_core #(.TWIDDLE_FILE("../assets/twiddle.hex"), .SINE_FILE("../assets/sine.hex"),
	.HANN_FILE("../assets/hann.hex"), .MAG_FILE("../assets/mag_rom.bin"), .WHEEL_DIV(8)) dut(
	.clk(clk), .rst_hold(rst_hold), .tick(tick), .pxl_x(pxl_x), .pxl_y(pxl_y), .btn(btn), .key(key),
	.wheel(wheel), .rx_data(rx_data), .rx_valid(rx_valid), .p_data(p_data), .p_valid(p_valid), .p_ready(p_ready),
	.rgb(rgb), .leds(leds), .hex(hex), .buzz(buzz), .status_led(status_led));

integer			lf, errors = 0, nframe = 0;
task automatic check(input cond, input [8*128-1:0] what);
	if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
	else $display("ok:   %0s", what);
endtask

// ---- monitors: published frames (to the log), the blanking-time budget, the buzzer
integer			cyc = 0, since = 0, pubs = 0, late = 0, worst = 0;
always @(posedge clk) begin
	cyc <= cyc + 1;
	since <= tick ? 0 : since + 1;
	if (dut.pub) begin
		pubs <= pubs + 1;
		$fwrite(lf, "PUB S%0dN%0dW%0dL%0d %0d %0d\n", dut.r_shape, dut.r_fq, dut.r_win, dut.r_lin, dut.r_ip_ok,
			dut.r_ip_dead);
	end
	if (dut.sc_we || dut.bd_we || dut.bi_we || dut.pub || dut.dig_busy) begin
		if (since > worst) worst <= since;
		if (since >= BUDGET) late <= late + 1;
	end
end

logic				bz_d = 0;
integer			bz_last = -1, bz_period = 0, bz_edges = 0;
always @(posedge clk) begin
	bz_d <= buzz;
	if (buzz && !bz_d) begin
		if (bz_last >= 0) bz_period <= cyc - bz_last;
		bz_last <= cyc;
		bz_edges <= bz_edges + 1;
	end
end

// ---- the USB link: letters in, the report line out (the link is not always ready)
always @(negedge clk) p_ready = ($urandom % 3) != 0;
logic	[7:0]		rep [0:255];
integer			rn = 0;
always @(posedge clk) if (p_valid) begin if (rn < 256) rep[rn] = p_data; rn = rn + 1; end

task automatic send(input [8*16-1:0] s);
	integer i;
	for (i = 15; i >= 0; i = i - 1)
		if (s[8*i +: 8] != 8'd0) begin
			@(negedge clk) begin rx_data = s[8*i +: 8]; rx_valid = 1; end
			@(negedge clk) rx_valid = 0;
			repeat (3) @(negedge clk);
		end
endtask

task automatic report;
	integer i, guard;
	begin
		rn = 0;
		send("R");
		guard = 0;
		while (rn < 128 && guard < 20000) begin @(negedge clk); guard = guard + 1; end
		repeat (100) @(negedge clk);
		check(rn == 128 && rep[126] == 8'h0D && rep[127] == 8'h0A, "R: one report line, 126 characters + CR LF");
		$fwrite(lf, "REPORT %0d ", dut.hold);
		$write("      ");
		for (i = 0; i < 126 && i < rn; i = i + 1) begin $fwrite(lf, "%c", rep[i]); $write("%c", rep[i]); end
		$fwrite(lf, "\n");
		$write("\n");
	end
endtask

// ---- frames: the tick, then the blanking time; a frame is made and published unless hold is on
task automatic frame;
	integer p0;
	logic h;
	begin
		@(negedge clk) begin tick = 1; h = dut.hold; p0 = pubs; end
		@(negedge clk) tick = 0;
		repeat (BUDGET) @(negedge clk);
		nframe = nframe + 1;
		if (pubs != p0 + (h ? 0 : 1)) begin
			errors = errors + 1;
			$display("FAIL: tick %0d published %0d frames, expected %0d", nframe, pubs - p0, h ? 0 : 1);
		end
		if (dut.eng_busy || dut.dig_busy) begin
			errors = errors + 1;
			$display("FAIL: tick %0d: still busy at the end of the blanking time", nframe);
		end
	end
endtask

// a quick tick while hold is on: only the controls see it (they sample the buttons once per frame)
task automatic ftick(input integer n);
	repeat (n) begin
		if (!dut.hold) begin errors = errors + 1; $display("FAIL: a quick tick without hold would start a frame"); end
		@(negedge clk) tick = 1;
		@(negedge clk) tick = 0;
		repeat (4) @(negedge clk);
	end
endtask

task automatic press(input integer b);
	begin
		btn[b] = 1; ftick(1);
		btn[b] = 0; ftick(1);
	end
endtask

// ---- the screen as the board's capture sees it (every 2nd scan pixel, 320 x 240) into a PPM
task automatic shot(input [8*24-1:0] name);
	integer f, x, y;
	begin
		f = $fopen(name, "w");
		$fwrite(f, "P3\n320 240\n15\n");
		for (y = 0; y < 480; y = y + 2) begin
			pxl_y = y;
			pxl_x = 32'hFFFFFFFF;				// next pixel = 0, so the memories are ready for x = 0
			for (x = 0; x < 640; x = x + 1) begin
				@(negedge clk) pxl_x = x;
				#1 if (x[0] == 0) $fwrite(f, "%0d %0d %0d\n", rgb[11:8], rgb[7:4], rgb[3:0]);
			end
		end
		$fclose(f);
		@(negedge clk) begin pxl_x = 32'd639; pxl_y = 32'd479; end
		$fwrite(lf, "SHOT %0s %0d %0d\n", name, dut.hold, dut.sound);
		$display("      wrote %0s", name);
	end
endtask

integer			i, e0;
initial begin
	lf = $fopen("tb_fft_lab.log", "w");
	repeat (20) @(negedge clk);
	rst_hold = 0;										// the PLL locks
	repeat (6000) @(negedge clk);					// the IP's reset (1,000 clocks), the wheel settles (4,096)
	check(!dut.follow && dut.fq == 10'd80, "power-up: 1 kHz, the wheel does not take over until it is turned");

	// ---- 1. the defaults
	frame;
	check(hex == 48'hFF_F9_C0_C0_40_C0, "7-segment: 1000.0 (Hz)");
	check(leds == 10'b0000_000001, "LEDs: sine, no window, dB, no hold, no sound");
	check(dut.r_ip_ok && !dut.r_ip_dead && !status_led, "the IP answered (status LED off)");
	check(dut.r_dclk == 17'd6145 && dut.r_iclk == 17'd1637, "times: our FFT 6145 clocks, the IP 1637");
	shot("sine_1k.ppm");
	report;

	// ---- 2. shapes and settings over USB (inputs the IP was recorded with)
	send("S1N80"); frame;
	check(leds == 10'b0000_000010 && dut.r_shape == 3'd1 && dut.r_ip_ok, "S1: square");
	shot("square.ppm");
	send("S2W1L1N84"); frame;
	check(leds == 10'b0011_000100 && dut.r_fq == 10'd84, "S2W1L1N84: triangle, Hann window, linear, 1050 Hz");
	shot("tri_hann_lin.ppm");
	report;
	send("S3N333W1L0"); frame;
	check(hex == 48'hFF_99_F9_82_24_92, "7-segment: 4162.5 (N333)");
	shot("saw_hann.ppm");
	send("S4N80W0"); frame;
	check(dut.r_shape == 3'd4 && !dut.r_win, "S4: spikes");
	shot("spikes.ppm");
	send("S0N1023"); frame;
	check(hex == 48'hF9_A4_F8_80_78_92, "7-segment: 12787.5 (N1023, the top)");
	send("S1N200W1L1"); frame;
	send("S0N1000W0L1"); frame;
	check(dut.r_ip_ok && dut.r_lin, "more recorded cases: the IP answers");
	send("s0n84w1l0"); frame;
	check(dut.r_fq == 10'd84 && dut.r_win, "lower case letters work too");
	shot("sine_84_hann.ppm");
	send("W0"); frame;
	shot("sine_84_rect.ppm");
	send("N0"); frame;
	check(hex == 48'hFF_FF_FF_FF_40_C0 && dut.r_ip_ok, "N0: 0.0 Hz; an all-zero input is fine for the IP");
	report;
	send("N80"); frame;

	// ---- 3. hold: the screen keeps its frame, the settings still change
	send("H1");
	check(leds[8], "H1: hold (LED 8)");
	frame;
	shot("hold.ppm");
	send("S2N80"); frame;
	check(dut.r_shape == 3'd0 && leds[5:0] == 6'b000100, "held: the screen keeps the sine, the LEDs show the triangle");
	report;
	send("H0"); frame;
	check(dut.r_shape == 3'd2, "H0: the triangle comes");

	// ---- 4. the game pad and the KEYs (the frame at the Start press is still made; then hold is on and
	// quick ticks exercise the controls alone)
	btn[START] = 1; frame; btn[START] = 0;
	check(dut.hold, "Start: hold");
	press(RIGHT);
	check(dut.shape == 3'd3, "Right: the next shape");
	press(LEFT); press(LEFT); press(LEFT); press(LEFT);
	check(dut.shape == 3'd5, "Left: the shape before; from sine it goes round to noise");
	press(RIGHT);
	check(dut.shape == 3'd0, "Right: from noise round to sine");
	key[1] = 1; ftick(1); key[1] = 0; ftick(1);
	check(dut.shape == 3'd1, "KEY1: the next shape");
	press(A); press(B);
	check(dut.win && dut.lin && leds[7:6] == 2'b11, "A: Hann window, B: linear");
	press(A); press(B);
	check(!dut.win && !dut.lin, "A and B again: off");
	press(SELECT);
	check(dut.sound && leds[9], "Select: sound on (LED 9)");
	press(SELECT);
	check(!dut.sound, "Select again: sound off");
	press(UP);
	check(dut.fq == 10'd81, "Up: one step");
	press(DOWN); press(DOWN);
	check(dut.fq == 10'd79, "Down: one step each press");
	btn[UP] = 1; ftick(130); btn = 8'd0; ftick(1);
	check(dut.fq == 10'd144, "Up held 130 frames: 1 + 32 repeats (every 3rd frame after 24) + 4 x 8 (after 120)");
	btn[DOWN] = 1; ftick(30); btn = 8'd0; ftick(1);
	check(dut.fq == 10'd141, "Down held 30 frames: 1 + 2 repeats");
	btn[UP] = 1; btn[DOWN] = 1; ftick(30); btn = 8'd0; ftick(1);
	check(dut.fq == 10'd141, "Up and Down together: no change");
	send("N3"); btn[DOWN] = 1; ftick(60); btn = 8'd0; ftick(1);
	check(dut.fq == 10'd0, "Down stops at 0");
	send("N1020"); btn[UP] = 1; ftick(60); btn = 8'd0; ftick(1);
	check(dut.fq == 10'd1023, "Up stops at 1023");
	send("N5000S9");
	check(dut.fq == 10'd1023 && dut.shape == 3'd1, "N5000 gives 1023; S9 is ignored");
	key[0] = 1; ftick(1); key[0] = 0;
	check(dut.shape == 3'd0 && dut.fq == 10'd80 && !dut.win && !dut.lin && !dut.hold && !dut.sound &&
		leds == 10'b0000_000001, "KEY0: the defaults (hold off too)");
	repeat (1200) @(negedge clk);					// KEY0 also restarts the IP: 1,000 clocks of reset
	$fwrite(lf, "RESTART\n");
	frame;
	check(dut.r_ip_ok && dut.r_fq == 10'd80 && dut.r_shape == 3'd0, "after KEY0: sine at 1 kHz, the IP answers");

	// ---- 5. sound: the buzzer plays the frequency (1 kHz = 25,005.6 clocks)
	send("M1");
	repeat (80000) @(negedge clk);
	check(bz_period >= 25005 && bz_period <= 25006, "M1: the buzzer plays 1 kHz");
	frame;
	shot("sound_on.ppm");
	send("M0");
	e0 = bz_edges;
	repeat (30000) @(negedge clk);
	check(bz_edges == e0 && !buzz, "M0: the buzzer is quiet");

	// ---- 6. the IP stops
	// an input it was never recorded with: no answer; the watchdog marks it dead, the frames go on without it
	send("S5"); frame;
	check(dut.r_ip_dead && !dut.r_ip_ok && status_led, "noise (no recording): no answer, the IP is marked dead");
	check(dut.r_iclk == 17'd0 && dut.r_dclk == 17'd6145, "dead: its time shows 0, our FFT goes on");
	shot("noise_ip_dead.ppm");
	report;
	send("S0"); frame;
	check(dut.r_ip_dead, "it stays dead (and is not fed) until it is restarted");
	send("D");
	repeat (1200) @(negedge clk);
	$fwrite(lf, "RESTART\n");
	frame;
	check(dut.r_ip_ok && !dut.r_ip_dead && !status_led, "D: the defaults and an IP restart; it answers again");
	// an IP that answers all zeros
	dut.eng.ip.mode = 2; $fwrite(lf, "MODE 2\n");
	frame;
	check(!dut.r_ip_ok && !dut.r_ip_dead && dut.r_iclk == 17'd1637 && status_led, "an IP that answers zeros: not ok");
	shot("ip_zeros.ppm");
	report;
	dut.eng.ip.mode = 0; $fwrite(lf, "MODE 0\n");
	frame;
	check(dut.r_ip_ok, "it answers right again: ok, no restart needed");
	// an IP that stops answering (its evaluation time is over), then KEY0
	dut.eng.ip.mode = 1; $fwrite(lf, "MODE 1\n");
	frame;
	check(dut.r_ip_dead, "a silent IP: dead after the watchdog");
	dut.eng.ip.mode = 0; $fwrite(lf, "MODE 0\n");
	frame;
	check(dut.r_ip_dead, "it stays dead");
	key[0] = 1; frame; key[0] = 0;
	check(dut.r_ip_dead, "the frame at the KEY0 tick is still made without it");
	$fwrite(lf, "RESTART\n");
	frame;
	check(dut.r_ip_ok, "KEY0 restarted the IP");

	// ---- 7. the wheel: smoothed, with hysteresis; it takes over only when turned
	for (i = 0; i < 400; i = i + 1) begin
		wheel = (i % 3 == 0) ? 12'd1998 : (i % 3 == 1) ? 12'd2002 : 12'd2000;
		repeat (50) @(negedge clk);
	end
	check(!dut.follow && dut.fq == 10'd80, "a noisy wheel that is not turned does not take over");
	wheel = 12'd2400;
	repeat (8000) @(negedge clk);
	check(dut.follow && dut.fq == dut.ctrl.q && dut.fq >= 10'd598 && dut.fq <= 10'd600,
		"turning the wheel takes over: N follows it (2400 / 4)");
	frame;
	shot("wheel.ppm");
	send("N84");
	check(!dut.follow && dut.fq == 10'd84, "N84 takes the frequency back from the wheel");
	wheel = 12'd2402;
	repeat (8000) @(negedge clk);
	check(!dut.follow && dut.fq == 10'd84, "touching the wheel (half a step) does not take over");
	wheel = 12'd2412;
	repeat (8000) @(negedge clk);
	check(dut.follow && dut.fq >= 10'd601 && dut.fq <= 10'd603, "turning it 3 steps does");
	send("D");
	check(!dut.follow && dut.fq == 10'd80, "D: the defaults");
	repeat (1200) @(negedge clk);
	$fwrite(lf, "RESTART\n");
	frame;
	check(dut.r_ip_ok && dut.r_fq == 10'd80, "the IP is back");
	report;

	// ---- the timing
	$display("      %0d frame ticks, %0d frames published; the latest frame work ended %0d clocks after its tick",
		nframe, pubs, worst);
	check(late == 0 && worst < BUDGET, "every frame is made and published inside the blanking time (28,000 clocks)");
	$fclose(lf);
	if (errors == 0) $display("PASS"); else $display("FAIL: %0d checks", errors);
	$finish;
end

endmodule

`default_nettype wire
