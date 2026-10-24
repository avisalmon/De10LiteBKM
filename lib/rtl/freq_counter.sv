// Frequency counter: measures any clock against the 50 MHz reference, result in kHz
//
// Every 1 ms of ref_clk (the gate), counts rising edges of meas_clk -> khz (25 MHz -> 25000).
// The gate crosses into the measured domain through a 2-flop synchronizer; the count is held still
// while it crosses back, so no multi-bit value is ever sampled while it changes.
// ***********************************************

module freq_counter #(
	parameter REF_HZ = 50_000_000
)(
	input						ref_clk,
	input						meas_clk,
	output reg	[19:0]	khz = 0,		// up to 1 GHz
	output reg				valid = 0	// pulses (ref_clk) when khz is updated
	);

localparam GATE = REF_HZ / 1000;		// 1 ms in ref_clk cycles

// ref domain: 1 ms gate, then 1 ms pause while the count is copied
reg	[31:0]	cnt = 0;
reg				gate = 0;
always @(posedge ref_clk) begin
	if (cnt == GATE - 1) begin
		cnt <= 0;
		gate <= ~gate;
	end
	else
		cnt <= cnt + 1;
end

// measured domain: count while the (synchronized) gate is high
reg	[2:0]		gate_m = 0;
reg	[19:0]	edges = 0;
always @(posedge meas_clk) begin
	gate_m <= {gate_m[1:0], gate};
	if (gate_m[2:1] == 2'b01)
		edges <= 1;		// this edge is the first one inside the gate
	else if (gate_m[1])
		edges <= edges + 1;
end

// back in ref: half way through the pause the count has been still for ~0.5 ms
always @(posedge ref_clk) begin
	valid <= 0;
	if (!gate && cnt == GATE / 2) begin
		khz <= edges;
		valid <= 1;
	end
end

endmodule
