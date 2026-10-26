// The lab's controls: game pad, KEYs, the wheel and USB letters -> the live settings
//
// Game pad (sampled once per frame, on tick): Left / Right and KEY1 change the shape, Up / Down step the
// frequency (hold: repeats after 0.4 s, x8 after 2 s), A window on/off, B dB / linear, Start hold the frame,
// Select sound. KEY0 = defaults (sine, 1 kHz, no window, dB) and restart the IP.
// The wheel tunes the frequency: it is smoothed (1 kHz, 1/64 per step) with hysteresis, and it takes over
// only when it is turned (2 steps away from where it was when the frequency was last set another way).
// USB (scripts/de10.py send): S<0..5> shape, N<0..1023> frequency step (x 12.5 Hz), W<0|1> window,
// L<0|1> linear, H<0|1> hold, M<0|1> sound, R report line, D defaults. Lower case works too.
// ***********************************************
`default_nettype none

module lab_ctrl #(
	parameter WHEEL_DIV = 25000,					// 25 MHz / 25000 = the wheel filter's 1 kHz step
	parameter SETTLE = 512							// wheel steps after power-up before it may take over
)(
	input		wire				clk,
	input		wire				tick,
	input		wire	[7:0]		btn,				// {Left, Right, Up, Down, Start, Select, B, A}, pressed = 1
	input		wire	[1:0]		key,				// pressed = 1
	input		wire	[11:0]	wheel,
	input		wire	[7:0]		rx_data,
	input		wire				rx_valid,
	output	logic	[2:0]		shape = 3'd0,
	output	logic	[9:0]		fq = 10'd80,
	output	logic				win = 1'b0,
	output	logic				lin = 1'b0,
	output	logic				hold = 1'b0,
	output	logic				sound = 1'b0,
	output	logic				follow = 1'b0,
	output	logic				ip_restart = 1'b0,
	output	logic				report = 1'b0
	);

// ---- buttons
logic	[7:0]		bprev = 8'd0;
logic	[1:0]		kprev = 2'd0;
wire	[7:0]		bedge = btn & ~bprev;
wire	[1:0]		kedge = key & ~kprev;
wire				up = btn[5] && !btn[4], down = btn[4] && !btn[5];
logic	[7:0]		rep = 8'd0;
logic	[1:0]		rep3 = 2'd0;
wire				do_step = (up || down) && (rep == 8'd0 || (rep >= 8'd24 && rep3 == 2'd0));
wire	[3:0]		step = (rep >= 8'd120) ? 4'd8 : 4'd1;
wire	[10:0]	fq_up = {1'b0, fq} + step;

// ---- wheel
logic	[11:0]	w1 = 12'd0, w2 = 12'd0, ws = 12'd0;
logic	[14:0]	div = 15'd0;
logic				strobe = 1'b0;
logic	[17:0]	wacc = 18'd0;
logic	[9:0]		q = 10'd0, q_ref = 10'd0;
logic	[9:0]		settle = 10'd0;
wire	[11:0]	wf = wacc[17:6];
wire	[12:0]	q4 = {1'b0, q, 2'b00};
wire				keep = ({1'b0, wf} + 13'd2 >= q4) && ({1'b0, wf} <= q4 + 13'd5);
wire	[9:0]		dq = (q > q_ref) ? q - q_ref : q_ref - q;

// ---- USB
logic	[7:0]		cmd = 8'd0;
logic	[13:0]	uacc = 14'd0;
wire	[7:0]		c = (rx_data >= "a" && rx_data <= "z") ? rx_data - 8'h20 : rx_data;
wire				is_digit = c >= "0" && c <= "9";
wire	[16:0]	nacc_raw = uacc * 17'd10 + (c - "0");
wire	[13:0]	nacc = (nacc_raw > 17'd9999) ? 14'd9999 : nacc_raw[13:0];

task automatic defaults;
	begin
		shape <= 3'd0; fq <= 10'd80; win <= 1'b0; lin <= 1'b0; hold <= 1'b0; sound <= 1'b0;
		follow <= 1'b0; q_ref <= q; ip_restart <= 1'b1;
	end
endtask

// One block; the order is the priority: when two lines set the same register in one clock, the later one wins
// (USB letters over KEY0 over the buttons over the wheel; Left over Right).
always @(posedge clk) begin
	ip_restart <= 1'b0;
	report <= 1'b0;

	// the wheel: sample when stable (it comes from the 50 MHz domain), smooth, quantize with hysteresis
	w1 <= wheel; w2 <= w1;
	if (w1 == w2) ws <= w2;
	strobe <= 1'b0;
	if (div == WHEEL_DIV - 1) begin div <= 15'd0; strobe <= 1'b1; end
	else div <= div + 1'b1;
	if (strobe) begin
		wacc <= wacc + ws - (wacc >> 6);
		if (!keep) q <= wf[11:2];
		if (settle != SETTLE) begin settle <= settle + 1'b1; q_ref <= q; end
		else if (dq >= 10'd2) follow <= 1'b1;
	end
	if (follow) fq <= q;

	// buttons, once per frame
	if (tick) begin
		bprev <= btn; kprev <= key;
		if (bedge[6] || kedge[1]) shape <= (shape >= 3'd5) ? 3'd0 : shape + 1'b1;
		if (bedge[7]) shape <= (shape == 3'd0 || shape > 3'd5) ? 3'd5 : shape - 1'b1;
		if (bedge[0]) win <= !win;
		if (bedge[1]) lin <= !lin;
		if (bedge[3]) hold <= !hold;
		if (bedge[2]) sound <= !sound;
		if (up || down) begin
			rep <= (rep == 8'd255) ? rep : rep + 1'b1;
			rep3 <= (rep3 == 2'd2) ? 2'd0 : rep3 + 1'b1;
		end
		else begin rep <= 8'd0; rep3 <= 2'd0; end
		if (do_step) begin
			if (up) fq <= (fq_up > 11'd1023) ? 10'd1023 : fq_up[9:0];
			else fq <= (fq < step) ? 10'd0 : fq - step;
			follow <= 1'b0; q_ref <= q;
		end
		if (kedge[0]) defaults;
	end

	// USB letters
	if (rx_valid) begin
		if (c == "S" || c == "N" || c == "W" || c == "L" || c == "H" || c == "M") begin
			cmd <= c; uacc <= 14'd0;
		end
		else if (is_digit && cmd != 8'd0) begin
			uacc <= nacc;
			case (cmd)
				"S": if (nacc <= 14'd5) shape <= nacc[2:0];
				"N": begin fq <= (nacc > 14'd1023) ? 10'd1023 : nacc[9:0]; follow <= 1'b0; q_ref <= q; end
				"W": win <= nacc[0];
				"L": lin <= nacc[0];
				"H": hold <= nacc[0];
				"M": sound <= nacc[0];
				default: ;
			endcase
		end
		else begin
			cmd <= 8'd0;
			if (c == "R") report <= 1'b1;
			if (c == "D") defaults;
		end
	end
end

endmodule

`default_nettype wire
