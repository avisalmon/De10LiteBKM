// Space Invaders sounds on the shield's buzzer: one square wave (or noise) whose half-period, in 25 MHz clocks,
// changes once per frame: half = 25e6 / (2 * f). The arcade made its sounds with analog circuits; these are
// buzzer-sized stand-ins with the same roles and lengths.
// Effects, highest priority first: the cannon's explosion (falling noise), the saucer hit (fast warble), the extra
// ship (beeps), an invader hit (short noise), the shot (falling "pew"), the march (4 low notes, one per step of
// the fleet, chosen by the game logic), the flying saucer (slow warble, as long as it flies).
// ***********************************************
`default_nettype none

module inv_sound (
	input		wire				clk,			// 25 MHz
	input		wire				tick,			// frame
	input		wire				mute,
	input		wire				snd_die, snd_ufo_hit, snd_extra, snd_hit, snd_shot,	// one-clock pulses
	input		wire				snd_march,	// pulse: play note march_note
	input		wire	[1:0]		march_note,
	input		wire				snd_ufo,		// level: the saucer is flying
	output	logic				buzz
	);

logic	[6:0]		die_t, uhit_t, extra_t;
logic	[4:0]		hit_t, shot_t;
logic	[2:0]		march_t;
logic	[1:0]		note;
logic	[16:0]	half, cnt;
logic				noise;
logic	[7:0]		fr;
logic	[15:0]	lfsr;

function automatic [16:0] note_half(input [1:0] n);	// the march: G3, F3, E3, D3
	case (n)
		2'd0: note_half = 17'd63776;
		2'd1: note_half = 17'd71582;
		2'd2: note_half = 17'd75843;
		default: note_half = 17'd85131;
	endcase
endfunction

wire	[3:0]		tri16 = fr[4] ? ~fr[3:0] : fr[3:0];		// 0..15..0 over 32 frames

always @(posedge clk) begin
	if (snd_die) die_t <= 7'd64;
	if (snd_ufo_hit) uhit_t <= 7'd40;
	if (snd_extra) extra_t <= 7'd48;
	if (snd_hit) hit_t <= 5'd16;
	if (snd_shot) shot_t <= 5'd12;
	if (snd_march) begin march_t <= 3'd5; note <= march_note; end
	if (tick) begin
		fr <= fr + 1'b1;
		if (die_t != 0) die_t <= die_t - 1'b1;
		if (uhit_t != 0) uhit_t <= uhit_t - 1'b1;
		if (extra_t != 0) extra_t <= extra_t - 1'b1;
		if (hit_t != 0) hit_t <= hit_t - 1'b1;
		if (shot_t != 0) shot_t <= shot_t - 1'b1;
		if (march_t != 0) march_t <= march_t - 1'b1;
		// the sound for the coming frame
		noise <= 1'b0;
		if (die_t != 0)          begin half <= 17'd2500 + {7'd64 - die_t, 7'd0}; noise <= 1'b1; end
		else if (uhit_t != 0)    half <= 17'd5000 + {uhit_t[2:0], 10'd0};
		else if (extra_t != 0)   half <= extra_t[3] ? 17'd8333 : 17'd0;
		else if (hit_t != 0)     begin half <= 17'd1200 + {5'd16 - hit_t, 7'd0}; noise <= 1'b1; end
		else if (shot_t != 0)    half <= 17'd3000 + {5'd12 - shot_t, 9'd0} + {5'd12 - shot_t, 7'd0};
		else if (march_t != 0)   half <= note_half(note);
		else if (snd_ufo)        half <= 17'd9000 + {tri16, 9'd0};
		else                     half <= 17'd0;
	end
	// the square wave (or noise: a random level each half-period)
	if (half == 0 || mute) begin cnt <= 17'd0; buzz <= 1'b0; end
	else if (cnt >= half) begin
		cnt <= 17'd0;
		lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
		buzz <= noise ? lfsr[0] : ~buzz;
	end
	else cnt <= cnt + 1'b1;
end

initial begin
	die_t = 0; uhit_t = 0; extra_t = 0; hit_t = 0; shot_t = 0; march_t = 0; note = 0;
	half = 0; cnt = 0; noise = 0; fr = 0; lfsr = 16'hACE1; buzz = 0;
end

endmodule

`default_nettype wire
