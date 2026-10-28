`default_nettype none
// Move one PLL output's phase at run time, one step at a time (MAX 10 dynamic phase shift), and reset the PLL
//
// Drives the phase ports of lib/rtl/pll_de10_dps.v. The design asks (on its own clock) for n steps up or down;
// the stepper walks the PLL's handshake on scanclk for each one (MAX 10 Clocking and PLL User Guide):
//   wait phasedone high . hold phasestep high for 8 scanclk clocks (the PLL latches it on a falling edge and
//   takes the step on the 2nd rising edge after that; at least 2 are required) . drop phasestep . wait at
//   least 2 clocks and phasedone high (the step is applied) . one idle clock . next
// The guide says to drop phasestep once phasedone has gone low. That low is short: in Altera's simulation
// model it lasts half a scanclk period and never covers a rising edge, so this stepper does not wait for it.
// It only records whether it saw it (no_ack = a request in which some step showed no low on phasedone, sampled
// on both scanclk edges): a diagnostic for the board, not a condition.
// One step moves the output by VCO period / 8 (208 ps: the fitter runs the VCO at 600 MHz behind a 100 MHz
// output, 48 steps per period; fit.rpt "PLL Summary" has the number). Only one
// counter moves (COUNTER: 2 = c0 ... 6 = c4); the others, and the design's own clock, stay where they were.
// reset_req pulses the PLL's areset for 32 scanclk clocks: every output returns to its compiled phase, locked
// drops and the design restarts (so the requester must expect its own reset); pos returns to 0.
//
// Two clocks: clk is the design's (it stops while the PLL resets), scanclk is the PLL's reconfiguration clock
// and must be the board's 50 MHz input, which never stops. Requests cross as toggles, results come back as
// levels; pos, error and no_ack are read when busy is low (they are stable by then). The scanclk side has no
// reset: its registers start from their power-up values and the only thing that matters, pos, restarts with
// the PLL. error is set when phasedone does not come back high within 1024 scanclk clocks (before a step or
// after one) and holds until the next request.
// ***********************************************

module pll_phase_step #(
	parameter [2:0] COUNTER = 3'd3						// the PLL counter to move: 3 = clk[1] (c1)
)(
	// design side
	input		wire				clk,
	input		wire				rst_n,
	input		wire				step_req,					// one clock: take step_n steps, up (later) when step_up
	input		wire	[7:0]		step_n,						// 0 = 256
	input		wire				step_up,
	input		wire				reset_req,					// one clock: pulse the PLL's areset
	output	reg				busy = 0,
	output	reg				error = 0,
	output	reg				no_ack = 0,					// a step in the last request showed no phasedone low
	output	reg	[15:0]	pos = 0,						// signed steps from the compiled phase, valid when !busy
	// PLL side, scanclk domain
	input		wire				scanclk,
	output	wire	[2:0]		phasecounterselect,
	output	reg				phaseupdown = 1,
	output	reg				phasestep = 0,
	input		wire				phasedone,
	output	reg				pll_areset = 0
	);

assign phasecounterselect = COUNTER;

// ---- clk side: send a request, mirror the result ----
reg				step_t = 0, reset_t = 0;				// toggles: one request each
reg	[7:0]		req_n = 0;
reg				req_up = 0;
reg				s_busy = 0, s_error = 0, s_no_ack = 0;	// scanclk side levels
reg	[15:0]	s_pos = 0;
reg	[1:0]		busy_sync = 0;								// scanclk -> clk
reg				busy_d = 0;

always @(posedge clk) begin
	busy_sync <= {busy_sync[0], s_busy};
	busy_d <= busy_sync[1];
	if (step_req && !busy) begin
		req_n <= step_n;
		req_up <= step_up;
		step_t <= ~step_t;
		busy <= 1'b1;
	end
	if (reset_req && !busy) begin
		reset_t <= ~reset_t;
		busy <= 1'b1;
	end
	// the request is finished when the scanclk side's busy has risen and fallen again
	if (busy && busy_d && !busy_sync[1]) begin
		busy <= 1'b0;
		pos <= s_pos;
		error <= s_error;
		no_ack <= s_no_ack;
	end
	if (!rst_n) begin									// also the restart after reset_req: the PLL is back at pos 0
		busy <= 1'b0;
		busy_d <= 1'b0;
		pos <= 16'd0;
		error <= 1'b0;
		no_ack <= 1'b0;
	end
end

// ---- scanclk side: the PLL handshake ----
localparam [2:0]	S_IDLE = 3'd0, S_READY = 3'd1, S_RAISE = 3'd2, S_TAKEN = 3'd3, S_DONE = 3'd4,
						S_RESET = 3'd5, S_END = 3'd6;
localparam [3:0]	HOLD = 4'd8;								// scanclk clocks phasestep stays high (2 required)
reg	[2:0]		state = S_IDLE;
reg	[2:0]		step_s = 0, reset_s = 0;				// [0],[1] synchronizer, [2] previous
reg	[8:0]		left = 0;									// steps still to take
reg	[10:0]	t = 0;										// timeout / hold counter
reg	[1:0]		done_s = 2'b11;							// phasedone through 2 flops (it is a PLL output)
reg				done_n = 1;									// phasedone at the falling edge, for the diagnostic
reg				saw_low = 0;								// phasedone was low some time during this step
wire				done = done_s[1];
wire				new_step = step_s[2] ^ step_s[1];
wire				new_reset = reset_s[2] ^ reset_s[1];

always @(negedge scanclk) done_n <= phasedone;

always @(posedge scanclk) begin
	step_s <= {step_s[1:0], step_t};
	reset_s <= {reset_s[1:0], reset_t};
	done_s <= {done_s[0], phasedone};
	t <= t + 1'b1;
	if (!done_s[0] || !done_n) saw_low <= 1'b1;
	case (state)
		S_IDLE: begin
			phasestep <= 1'b0;
			pll_areset <= 1'b0;
			if (new_reset) begin
				s_busy <= 1'b1;
				s_error <= 1'b0;
				s_no_ack <= 1'b0;
				t <= 0;
				state <= S_RESET;
			end
			else if (new_step) begin
				s_busy <= 1'b1;
				s_error <= 1'b0;
				s_no_ack <= 1'b0;
				phaseupdown <= req_up;
				left <= (req_n == 0) ? 9'd256 : {1'b0, req_n};
				t <= 0;
				state <= S_READY;
			end
		end
		S_READY:											// wait for the PLL to be free, then raise phasestep
			if (left == 0) state <= S_END;
			else if (done) begin
				phasestep <= 1'b1;
				saw_low <= 1'b0;
				t <= 0;
				state <= S_RAISE;
			end
			else if (t[10]) begin						// 1024 clocks without phasedone: give up
				s_error <= 1'b1;
				state <= S_END;
			end
		S_RAISE:											// hold phasestep; the PLL takes the step meanwhile
			if (t == {7'd0, HOLD} - 1'b1) begin
				phasestep <= 1'b0;
				t <= 0;
				state <= S_TAKEN;
			end
		S_TAKEN:											// wait for the step to be applied (phasedone high again)
			if (done && t >= 2) begin
				left <= left - 1'b1;
				s_pos <= phaseupdown ? s_pos + 1'b1 : s_pos - 1'b1;
				if (!saw_low) s_no_ack <= 1'b1;
				t <= 0;
				state <= S_DONE;
			end
			else if (t[10]) begin
				s_error <= 1'b1;
				state <= S_END;
			end
		S_DONE:											// one clock apart, as the PLL wants
			state <= S_READY;
		S_RESET: begin
			pll_areset <= 1'b1;
			s_pos <= 16'd0;
			if (t[5]) begin
				pll_areset <= 1'b0;
				state <= S_END;
			end
		end
		S_END: begin									// pos and error settle one clock before busy drops
			s_busy <= 1'b0;
			state <= S_IDLE;
		end
		default: state <= S_IDLE;
	endcase
end

endmodule

`default_nettype wire
