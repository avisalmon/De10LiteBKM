// Unit test: pll_phase_step (lib/rtl/pll_phase_step.sv) against a model of the MAX 10 PLL's phase ports that
// behaves like Altera's atom model (fiftyfivenm_pll): phasestep latched on the falling edge of scanclk, the step
// taken on the 2nd rising edge with it latched, phasedone low from then for LOW_NS (the atom: half a scanclk
// period, so no rising edge ever sees it), a new phasestep while phasedone is low is skipped, areset returns the
// tap to the compiled value. The design side runs at 100 MHz and, like memtest_top, resets itself while the
// PLL is in areset. Checks: steps up and down and the 256 case (pos and the model's tap agree), the step count
// seen by the model, phasestep held at least 2 scanclk, no_ack with a long and a short low, the PLL reset (pos back
// to 0 after the design's own reset), a stuck phasedone (error, pos unchanged), a request while busy (ignored).
// python scripts/sim.py lib/sim/tb_pll_phase_step.sv
// sim-sources: lib/rtl/pll_phase_step.sv
`timescale 1ns/1ps

module tb_pll_phase_step;

reg				clk = 0, scanclk = 0, rst_n = 0;
always #5 clk = ~clk;
always #10 scanclk = ~scanclk;

reg				step_req = 0, reset_req = 0, step_up = 0;
reg	[7:0]		step_n = 0;
wire				busy, error, no_ack, phaseupdown, phasestep, pll_areset;
wire	[15:0]	pos;
wire	[2:0]		phasecounterselect;
wire				phasedone;

pll_phase_step #(.COUNTER(3'd3)) dut(.clk(clk), .rst_n(rst_n), .step_req(step_req), .step_n(step_n),
	.step_up(step_up), .reset_req(reset_req), .busy(busy), .error(error), .no_ack(no_ack), .pos(pos),
	.scanclk(scanclk), .phasecounterselect(phasecounterselect), .phaseupdown(phaseupdown), .phasestep(phasestep),
	.phasedone(phasedone), .pll_areset(pll_areset));

// ---- the PLL's phase ports, as the atom model does them ----
real				low_ns = 10.0;						// how long phasedone stays low after a step
reg				stuck_low = 0;
reg				update_phase = 0, phasestep_reg = 0;
integer			high_count = 0, tap = 0, steps_taken = 0, skipped = 0;
assign phasedone = stuck_low ? 1'b0 : ~update_phase;
always @(negedge scanclk) phasestep_reg <= phasestep;
always @(posedge scanclk)
	if (phasestep_reg) begin
		if (high_count == 1) begin
			if (phasecounterselect == 3'd3) begin
				tap = phaseupdown ? (tap + 1) % 8 : (tap == 0 ? 7 : tap - 1);
				steps_taken = steps_taken + 1;
				update_phase <= 1'b1;
				update_phase <= #(low_ns) 1'b0;
			end
		end
		high_count = high_count + 1;
	end
always @(posedge phasestep)
	if (update_phase == 1'b0) high_count = 0;
	else skipped = skipped + 1;								// the atom skips this one
always @(posedge pll_areset) tap = 0;

// phasestep must stay high at least 2 scanclk
real				t_rise;
integer			short_pulses = 0;
always @(posedge phasestep) t_rise = $realtime;
always @(negedge phasestep) if ($realtime - t_rise < 40.0) short_pulses = short_pulses + 1;

// the design resets while the PLL is in areset and for a while after (lock time), like the board
reg	[7:0]		relock = 0;
always @(posedge clk) begin
	if (pll_areset) relock <= 8'd200;
	else if (relock != 0) relock <= relock - 1'b1;
	rst_n <= !pll_areset && (relock == 0);
end

// ---- checks ----
integer			errors = 0;
task fail(input [8*80-1:0] what, input integer got, input integer want);
	begin
		errors = errors + 1;
		$display("FAIL at %0t: %0s: got %0d, want %0d", $time, what, got, want);
	end
endtask

task request(input [7:0] n, input up);
	begin
		@(negedge clk);
		step_n = n; step_up = up; step_req = 1;
		@(negedge clk);
		step_req = 0;
		@(negedge clk);
		if (!busy) fail("busy after request", busy, 1);
	end
endtask

task wait_idle(input integer max_us);
	integer n;
	begin
		n = 0;
		while (busy && n < max_us * 100) begin
			@(negedge clk);
			n = n + 1;
		end
		if (busy) fail("still busy", 1, 0);
	end
endtask

integer t0, prev;

initial begin
	#300;
	@(negedge clk);
	if (busy) fail("busy at start", busy, 0);
	if (phasecounterselect !== 3'd3) fail("phasecounterselect", phasecounterselect, 3);

	// 5 steps up, a long low (the negedge sampler sees it)
	t0 = $time;
	request(8'd5, 1'b1);
	wait_idle(100);
	$display("5 steps took %0d ns", $time - t0);
	if (pos !== 16'd5) fail("pos after 5 up", pos, 5);
	if (tap !== 5) fail("tap after 5 up", tap, 5);
	if (steps_taken !== 5) fail("steps taken", steps_taken, 5);
	if (error) fail("error after 5 up", error, 0);
	if (no_ack) fail("no_ack with a long low", no_ack, 0);

	// 3 down
	request(8'd3, 1'b0);
	wait_idle(100);
	if (pos !== 16'd2) fail("pos after 3 down", pos, 2);
	if (tap !== 2) fail("tap after 3 down", tap, 2);

	// 256 (n = 0) up, with the atom's short low: still correct, no_ack says so
	low_ns = 6.0;
	prev = steps_taken;
	t0 = $time;
	request(8'd0, 1'b1);
	wait_idle(2000);
	$display("256 steps took %0d us", ($time - t0) / 1000);
	if (pos !== 16'd258) fail("pos after 256 up", pos, 258);
	if (tap !== 2) fail("tap after 256 up", tap, 2);
	if (steps_taken - prev !== 256) fail("steps taken for 256", steps_taken - prev, 256);
	if (!no_ack) fail("no_ack with the atom's short low", no_ack, 1);
	if (error) fail("error after 256", error, 0);
	low_ns = 10.0;

	// a request while busy is ignored
	request(8'd2, 1'b1);
	@(negedge clk); step_n = 8'd3; step_req = 1; @(negedge clk); step_req = 0;
	wait_idle(100);
	if (pos !== 16'd260) fail("pos after 2 up (3 ignored)", pos, 260);

	// 300 steps down (two requests) to -40: the sign
	request(8'd0, 1'b0);
	wait_idle(2000);
	request(8'd44, 1'b0);
	wait_idle(2000);
	if ($signed(pos) !== -40) fail("pos after 300 down", $signed(pos), -40);
	if (tap !== 0) fail("tap after 300 down (-40 mod 8)", tap, 0);

	// the PLL reset: areset pulse, the design resets itself, pos is 0 and the stepper is free afterwards
	@(negedge clk); reset_req = 1; @(negedge clk); reset_req = 0;
	t0 = $time;
	@(posedge pll_areset);
	@(negedge pll_areset);
	$display("areset held %0d ns", $time - t0);
	if ($time - t0 < 600) fail("areset too short (ns)", $time - t0, 640);
	@(posedge rst_n);
	repeat (10) @(negedge clk);
	if (busy) fail("busy after the reset", busy, 0);
	if (pos !== 16'd0) fail("pos after the reset", pos, 0);
	if (tap !== 0) fail("tap after the reset", tap, 0);
	if (error) fail("error after the reset", error, 0);
	request(8'd7, 1'b1);
	wait_idle(100);
	if (pos !== 16'd7) fail("pos after reset + 7", pos, 7);
	if (tap !== 7) fail("tap after reset + 7", tap, 7);

	// phasedone stuck low: error, no step
	stuck_low = 1;
	prev = steps_taken;
	t0 = $time;
	request(8'd4, 1'b1);
	wait_idle(100);
	$display("stuck phasedone: gave up after %0d us", ($time - t0) / 1000);
	if (!error) fail("error with phasedone stuck", error, 1);
	if (pos !== 16'd7) fail("pos with phasedone stuck", pos, 7);
	if (steps_taken !== prev) fail("steps with phasedone stuck", steps_taken - prev, 0);
	stuck_low = 0;
	request(8'd1, 1'b0);
	wait_idle(100);
	if (error) fail("error cleared by the next request", error, 0);
	if (pos !== 16'd6) fail("pos after recovery", pos, 6);

	if (short_pulses != 0) fail("phasestep pulses under 2 scanclk", short_pulses, 0);
	if (skipped != 0) fail("steps the PLL skipped", skipped, 0);
	if (errors == 0) $display("PASS: pll_phase_step: %0d steps, reset, stuck phasedone, busy", steps_taken);
	else $display("FAIL: %0d errors", errors);
	$finish;
end

initial begin
	#5_000_000;
	$display("FAIL: timeout");
	$finish;
end

endmodule
