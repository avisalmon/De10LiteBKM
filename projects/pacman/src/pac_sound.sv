// Pac-Man sounds on the shield's buzzer: a square wave whose half-period (in 25 MHz clocks) changes per frame.
// Effects, highest priority first: death (falling warble), the intro tune, ghost eaten (rising sweep),
// power pellet (low warble), dot (two-step "waka"). half = 25e6 / (2 * f).
// ***********************************************
`default_nettype none

module pac_sound (
	input		wire				clk,			// 25 MHz
	input		wire				tick,			// frame
	input		wire				mute,
	input		wire				snd_dot, snd_power, snd_ghost, snd_death, snd_intro,
	output	logic				buzz
	);

// the arcade intro: {note, frames}; 256 frames = 4.3 s
localparam [15:0] B4 = 16'd25310, B5 = 16'd12655, FS5 = 16'd16892, DS5 = 16'd20088, C5 = 16'd23889,
                  C6 = 16'd11944, G5 = 16'd15944, E5 = 16'd18961, F5 = 16'd17897, GS5 = 16'd15049, A5 = 16'd14205;
function automatic [23:0] intro(input [4:0] i);		// {half-period, length in frames}
	case (i)
		5'd0: intro = {B4, 8'd8};   5'd1: intro = {B5, 8'd8};   5'd2: intro = {FS5, 8'd8};  5'd3: intro = {DS5, 8'd8};
		5'd4: intro = {B5, 8'd4};   5'd5: intro = {FS5, 8'd12}; 5'd6: intro = {DS5, 8'd16};
		5'd7: intro = {C5, 8'd8};   5'd8: intro = {C6, 8'd8};   5'd9: intro = {G5, 8'd8};   5'd10: intro = {E5, 8'd8};
		5'd11: intro = {C6, 8'd4};  5'd12: intro = {G5, 8'd12}; 5'd13: intro = {E5, 8'd16};
		5'd14: intro = {B4, 8'd8};  5'd15: intro = {B5, 8'd8};  5'd16: intro = {FS5, 8'd8}; 5'd17: intro = {DS5, 8'd8};
		5'd18: intro = {B5, 8'd4};  5'd19: intro = {FS5, 8'd12}; 5'd20: intro = {DS5, 8'd16};
		5'd21: intro = {DS5, 8'd4}; 5'd22: intro = {E5, 8'd4};  5'd23: intro = {F5, 8'd8};
		5'd24: intro = {F5, 8'd4};  5'd25: intro = {FS5, 8'd4}; 5'd26: intro = {G5, 8'd8};
		5'd27: intro = {G5, 8'd4};  5'd28: intro = {GS5, 8'd4}; 5'd29: intro = {A5, 8'd8};
		5'd30: intro = {B5, 8'd16};
		default: intro = {16'd0, 8'd0};
	endcase
endfunction

logic	[6:0]		death_t, ghost_t, power_t;
logic	[2:0]		dot_t;
logic				dot_alt;
logic	[4:0]		note;
logic	[7:0]		note_t;
logic				intro_on;
logic	[15:0]	half, cnt;
logic	[7:0]		fr;

wire	[23:0]	cur = intro(note), nxt = intro(note + 1'b1);

always @(posedge clk) begin
	if (snd_death) death_t <= 7'd96;
	if (snd_ghost) ghost_t <= 7'd30;
	if (snd_power) power_t <= 7'd40;
	if (snd_dot) begin dot_t <= 3'd6; dot_alt <= ~dot_alt; end
	if (snd_intro) begin intro_on <= 1'b1; note <= 5'd0; note_t <= 8'd8; end
	if (tick) begin
		fr <= fr + 1'b1;
		if (death_t != 0) death_t <= death_t - 1'b1;
		if (ghost_t != 0) ghost_t <= ghost_t - 1'b1;
		if (power_t != 0) power_t <= power_t - 1'b1;
		if (dot_t != 0) dot_t <= dot_t - 1'b1;
		if (intro_on) begin
			if (note_t <= 8'd1) begin
				if (note == 5'd30) intro_on <= 1'b0;
				note <= note + 1'b1; note_t <= nxt[7:0];
			end else note_t <= note_t - 1'b1;
		end
		// the sound for the coming frame
		if (death_t != 0)       half <= 16'd9000 + {7'd96 - death_t, 7'd0} + (fr[2] ? 16'd1500 : 16'd0);
		else if (intro_on)      half <= (note_t <= 8'd1) ? 16'd0 : cur[23:8];		// a short gap between notes
		else if (ghost_t != 0)  half <= 16'd4000 + {ghost_t, 9'd0};
		else if (power_t != 0)  half <= fr[1] ? 16'd30000 : 16'd26000;
		else if (dot_t != 0)    half <= (dot_t[2] ^ dot_alt) ? 16'd34000 : 16'd27000;
		else                    half <= 16'd0;
	end
	// the square wave
	if (half == 0 || mute) begin cnt <= 16'd0; buzz <= 1'b0; end
	else if (cnt >= half) begin cnt <= 16'd0; buzz <= ~buzz; end
	else cnt <= cnt + 1'b1;
end

initial begin
	death_t = 0; ghost_t = 0; power_t = 0; dot_t = 0; dot_alt = 0; note = 0; note_t = 0; intro_on = 0;
	half = 0; cnt = 0; fr = 0; buzz = 0;
end

endmodule
