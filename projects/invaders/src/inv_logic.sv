// inv_logic.sv - Space Invaders: the game rules, the attract mode, the text screen and the shields.
//
// A micro-sequencer runs one game step per frame (tick, in the vertical blank): the mode (attract, credit, intro,
// play, game over), the rack's edge test, the player, the shot, one bomb slot or the saucer, one invader of the
// rack, the checks, the score line and the typewriter. Collisions ask the same per-pixel layers the screen draws
// (inv_layers, the "probe"): "what is lit at (p_x, p_y)?", so a hit is exactly what you see.
// Our own design after the 1978 arcade's rules; every arcade number is a localparam below and the project's spec
// lists what was measured and what was assumed.

module inv_logic #(
	parameter	[7:0]	SAUCER_Y = 8'd40,
	parameter	[7:0]	SHIELD_Y = 8'd192,
	parameter	[7:0]	PLAYER_Y = 8'd216,
	parameter	[7:0]	GROUND_Y = 8'd239
	) (
	input		wire				clk,
	input		wire				rst_n,
	input		wire				tick,			// one pulse per frame, in the vertical blank
	input		wire				in_left, in_right, in_fire, in_coin, in_start,	// levels, active high
	input		wire				invincible,
	input		wire				pause_tgl,		// pulse
	input		wire	[1:0]		dip_ships,		// 3 + this many ships, read as a game (or the demo) starts
	input		wire				dip_bonus,		// extra ship at 1000 instead of 1500, read as a game starts
	input		wire				preset_go,		// pulse: full reset, then run preset preset_num fast and pause
	input		wire	[3:0]		preset_num,
	// the screen's read ports (one clock latency)
	input		wire	[9:0]		tb_addr,		// text: {row, column}
	output	logic	[7:0]		tb_q,
	input		wire	[7:0]		sb_addr,		// shields: column x
	output	logic	[15:0]	sb_q,
	// the objects
	output	logic				rack_on,
	output	logic	[7:0]		old_x, old_y, new_x, new_y,
	output	logic				old_frame, new_frame,
	output	logic	[5:0]		cursor,
	output	logic				fill,
	output	logic	[54:0]	alive,
	output	logic				aexp_on,
	output	logic	[7:0]		aexp_x, aexp_y,
	output	wire				pl_on,
	output	wire	[1:0]		pl_img,
	output	logic	[7:0]		pl_x,
	output	logic	[1:0]		sh_st,
	output	logic	[7:0]		sh_x, sh_y,
	output	wire	[5:0]		bm_st,
	output	wire	[23:0]	bm_x, bm_y,
	output	wire	[5:0]		bm_frame,
	output	logic	[1:0]		sc_st,
	output	logic	[7:0]		sc_x,
	output	logic	[11:0]	sc_score,		// BCD, shown while sc_st == 3
	output	logic	[223:0]	ground,
	// status
	output	logic	[15:0]	score, hiscore,	// BCD
	output	logic	[7:0]		credits,			// BCD
	output	logic	[3:0]		lives,
	output	wire				in_game,
	output	logic				ffwd, paused,
	output	wire				busy,
	// sound
	output	wire				snd_die, snd_ufo_hit, snd_extra, snd_hit, snd_shot, snd_march,
	output	logic	[1:0]		march_note,
	output	wire				snd_ufo
	);

	// ---------------------------------------------------------------- states and modes
	localparam	[5:0]
		S_IDLE = 6'd0,       S_PWR = 6'd1,        S_PWR_HDR = 6'd2,    S_PWR_END = 6'd3,    S_MODE = 6'd4,
		S_CLR = 6'd5,        S_PRB = 6'd6,        S_BUMP0 = 6'd7,      S_BUMP = 6'd8,       S_PLAYER = 6'd9,
		S_SHOT = 6'd10,      S_SH_COL = 6'd11,    S_SH_WAIT = 6'd12,   S_SH_ROW = 6'd13,    S_SH_HIT = 6'd14,
		S_ERO_COL = 6'd15,   S_ERO_WAIT = 6'd16,  S_ERO_LOAD = 6'd17,  S_ERO_ROW = 6'd18,   S_ERO_STORE = 6'd19,
		S_BOMB = 6'd20,      S_BM_FIND = 6'd21,   S_BM_SPAWN = 6'd22,  S_BM_COL = 6'd23,    S_BM_WAIT = 6'd24,
		S_BM_ROW = 6'd25,    S_BM_HIT = 6'd26,    S_SAUCER = 6'd27,    S_RACK = 6'd28,      S_RACK_SCAN = 6'd29,
		S_RACK_MOVE = 6'd30, S_BOX_COL = 6'd31,   S_BOX_WAIT = 6'd32,  S_BOX_LOAD = 6'd33,  S_CHECK = 6'd34,
		S_HUD = 6'd35,       S_TYPE = 6'd36,      S_TYPE2 = 6'd37;

	localparam	[2:0]	GM_ATTRACT = 3'd0, GM_CREDIT = 3'd1, GM_INTRO = 3'd2, GM_PLAY = 3'd3, GM_OVER = 3'd4;
	localparam	[1:0]	P_ALIVE = 2'd0, P_EXPL = 2'd1, P_HIDDEN = 2'd2, P_OFF = 2'd3;
	localparam	[2:0]	OP_CLR = 3'd0, OP_WAIT = 3'd1, OP_PRT = 3'd2, OP_PRB = 3'd3, OP_DEMO = 3'd4, OP_JMP = 3'd5;

	// ---------------------------------------------------------------- arcade numbers
	localparam	[7:0]		PL_XMIN = 8'd16, PL_XMAX = 8'd185;		// the cannon's left edge
	localparam	[7:0]		SHOT_Y0 = 8'd212, SHOT_TOP = 8'd36;		// launch line; bursts at or above the top
	localparam	[7:0]		BOMB_FLOOR = 8'd232;						// a bomb at or below this bursts on the ground
	localparam	[7:0]		RACK_X0 = 8'd24, RACK_Y0 = 8'd128;		// first wave: the bottom-left invader's cell
	localparam	[7:0]		BUMP_R = 8'd213, BUMP_L = 8'd9;			// the columns tested for the rack's edges
	localparam	[7:0]		BUMP_Y0 = 8'd40, BUMP_Y1 = 8'd223;
	localparam	[7:0]		INVADE_Y = 8'd216;							// an invader's top here: invaded
	localparam	[7:0]		SC_XL = 8'd9, SC_XR = 8'd192;				// saucer start from the left / the right
	localparam	[7:0]		SC_XMIN = 8'd8, SC_XMAX = 8'd193;			// saucer removed below / at or above
	localparam	[10:0]	SC_TIME = 11'h600;							// steps between saucers
	localparam	[5:0]		SC_HIT_T = 6'd32, SC_SCORE_T = 6'd24;		// saucer explosion, then its score until 0
	localparam	[4:0]		SH_BURST_T = 5'd16, AEXP_T = 5'd16;		// steps
	localparam	[2:0]		BM_BURST_T = 3'd4;							// turns of its slot
	localparam	[6:0]		WCLR_T = 7'd64;							// pause after the last invader
	localparam	[7:0]		EXPL_T = 8'd5, HIDE_T = 8'd128;			// player explosion: steps per picture; hidden
	localparam	[3:0]		EXPL_N = 4'd12;							// player explosion: picture changes
	localparam	[15:0]	BONUS_HI = 16'h1500, BONUS_LO = 16'h1000;	// extra ship score (BCD)

	// ---------------------------------------------------------------- pure functions
	function automatic [15:0] bcd_add(input [15:0] a, input [15:0] b);
		logic	[4:0]	s;
		logic			c;
		c = 1'b0;
		for (int i = 0; i < 4; i++) begin
			s = {1'b0, a[4*i +: 4]} + {1'b0, b[4*i +: 4]} + {4'd0, c};
			if (s > 5'd9) begin s = s + 5'd6; c = 1'b1; end
			else c = 1'b0;
			bcd_add[4*i +: 4] = s[3:0];
		end
	endfunction

	function automatic [7:0] bcd_inc99(input [7:0] v);	// saturates at 99
		if (v == 8'h99)				bcd_inc99 = v;
		else if (v[3:0] == 4'd9)	bcd_inc99 = {v[7:4] + 4'd1, 4'd0};
		else						bcd_inc99 = {v[7:4], v[3:0] + 4'd1};
	endfunction

	function automatic [7:0] bcd_dec(input [7:0] v);	// v != 0
		if (v[3:0] == 4'd0)	bcd_dec = {v[7:4] - 4'd1, 4'd9};
		else				bcd_dec = {v[7:4], v[3:0] - 4'd1};
	endfunction

	function automatic [5:0] march_delay(input [5:0] n);	// steps between march notes for n invaders
		if      (n >= 6'd50)	march_delay = 6'd52;
		else if (n >= 6'd43)	march_delay = 6'd46;
		else if (n >= 6'd36)	march_delay = 6'd39;
		else if (n >= 6'd28)	march_delay = 6'd34;
		else if (n >= 6'd22)	march_delay = 6'd28;
		else if (n >= 6'd17)	march_delay = 6'd24;
		else if (n >= 6'd13)	march_delay = 6'd21;
		else if (n >= 6'd10)	march_delay = 6'd19;
		else if (n >= 6'd8)	march_delay = 6'd16;
		else if (n >= 6'd7)	march_delay = 6'd14;
		else if (n >= 6'd6)	march_delay = 6'd13;
		else if (n >= 6'd5)	march_delay = 6'd12;
		else if (n >= 6'd4)	march_delay = 6'd11;
		else if (n >= 6'd3)	march_delay = 6'd9;
		else if (n >= 6'd2)	march_delay = 6'd7;
		else					march_delay = 6'd5;
	endfunction

	function automatic [7:0] reload_rate(input [15:0] s);	// bomb turns before another bomb may drop
		if      (s < 16'h0200)	reload_rate = 8'd48;
		else if (s < 16'h1000)	reload_rate = 8'd16;
		else if (s < 16'h2000)	reload_rate = 8'd11;
		else if (s < 16'h3000)	reload_rate = 8'd8;
		else					reload_rate = 8'd7;
	endfunction

	function automatic [3:0] col_table(input [4:0] i);	// the arcade's bomb column table, columns 1..11
		case (i)
		5'd0:  col_table = 4'h1;	5'd1:  col_table = 4'h7;	5'd2:  col_table = 4'h1;	5'd3:  col_table = 4'h1;
		5'd4:  col_table = 4'h1;	5'd5:  col_table = 4'h4;	5'd6:  col_table = 4'hB;	5'd7:  col_table = 4'h1;
		5'd8:  col_table = 4'h6;	5'd9:  col_table = 4'h3;	5'd10: col_table = 4'h1;	5'd11: col_table = 4'h1;
		5'd12: col_table = 4'hB;	5'd13: col_table = 4'h9;	5'd14: col_table = 4'h2;	5'd15: col_table = 4'h8;
		5'd16: col_table = 4'h2;	5'd17: col_table = 4'hB;	5'd18: col_table = 4'h4;	5'd19: col_table = 4'h7;
		5'd20: col_table = 4'hA;	5'd21: col_table = 4'h5;	5'd22: col_table = 4'h2;	5'd23: col_table = 4'h5;
		5'd24: col_table = 4'h4;	5'd25: col_table = 4'h6;	5'd26: col_table = 4'h7;	5'd27: col_table = 4'h8;
		5'd28: col_table = 4'hA;	5'd29: col_table = 4'h6;	5'd30: col_table = 4'hA;	default: col_table = 4'h3;
		endcase
	endfunction

	function automatic [7:0] sc_table(input [3:0] i);	// saucer value in tens (BCD), by shots fired mod 15
		case (i)
		4'd0:  sc_table = 8'h10;	4'd1:  sc_table = 8'h05;	4'd2:  sc_table = 8'h05;	4'd3:  sc_table = 8'h10;
		4'd4:  sc_table = 8'h15;	4'd5:  sc_table = 8'h10;	4'd6:  sc_table = 8'h10;	4'd7:  sc_table = 8'h05;
		4'd8:  sc_table = 8'h30;	4'd9:  sc_table = 8'h10;	4'd10: sc_table = 8'h10;	4'd11: sc_table = 8'h10;
		4'd12: sc_table = 8'h05;	4'd13: sc_table = 8'h15;	default: sc_table = 8'h10;
		endcase
	endfunction

	function automatic [7:0] wave_y(input [2:0] i);	// the rack's start line from the second wave on
		case (i)
		3'd0:					wave_y = 8'd152;
		3'd1:					wave_y = 8'd168;
		3'd2, 3'd3, 3'd4:		wave_y = 8'd176;
		default:				wave_y = 8'd184;
		endcase
	endfunction

	function automatic [5:0] shield_col(input [7:0] x);	// {inside a shield, its column 0..21}
		logic	[7:0]	b, d;
		shield_col = 6'd0;
		b = 8'd32;
		for (int s = 0; s < 4; s++) begin
			d = x - b;
			if (x >= b && d < 8'd22) shield_col = {1'b1, d[4:0]};
			b = b + 8'd45;
		end
	endfunction

	function automatic [15:0] box_mask(input [7:0] ay);	// shield rows under an invader whose top is ay
		if (ay >= SHIELD_Y)	box_mask = 16'h00FF << (ay - SHIELD_Y);
		else					box_mask = 16'h00FF >> (SHIELD_Y - ay);
	endfunction

	function automatic [6:0] div11(input [5:0] j);	// {row 0..4 (0 = bottom), column 0..10}
		logic	[2:0]	r;
		logic	[5:0]	c;
		if      (j >= 6'd44)	begin r = 3'd4; c = j - 6'd44; end
		else if (j >= 6'd33)	begin r = 3'd3; c = j - 6'd33; end
		else if (j >= 6'd22)	begin r = 3'd2; c = j - 6'd22; end
		else if (j >= 6'd11)	begin r = 3'd1; c = j - 6'd11; end
		else					begin r = 3'd0; c = j; end
		div11 = {r, c[3:0]};
	endfunction

	function automatic [14:0] preset_steps(input [3:0] n);
		case (n)
		4'd0: preset_steps = 15'd600;		4'd1: preset_steps = 15'd120;		4'd2: preset_steps = 15'd600;
		4'd3: preset_steps = 15'd1500;		4'd4: preset_steps = 15'd3000;		4'd5: preset_steps = 15'd5000;
		4'd6: preset_steps = 15'd8000;		4'd7: preset_steps = 15'd12000;	4'd8: preset_steps = 15'd20000;
		default: preset_steps = 15'd30000;
		endcase
	endfunction

	// The self-playing cannon: 1 right, 2 left, 0 stay; the next move is taken at each shot. The arcade's table
	// (DemoCommands, $1F74) holds 12 bytes, but its pointer wraps from $7D back to $74, so only these 10 are used.
	function automatic [1:0] demo_dir(input [3:0] i);
		case (i)
		4'd0, 4'd1, 4'd4, 4'd7:			demo_dir = 2'd1;
		4'd6, 4'd9:						demo_dir = 2'd2;
		default:						demo_dir = 2'd0;
		endcase
	endfunction

	function automatic [238:0] msg_info(input [4:0] id);	// {row, column, length, text right-aligned}
		logic	[4:0]		r, c, n;
		logic	[223:0]	t;
		case (id)
		5'd0:  begin r = 5'd1;  c = 5'd0;  n = 5'd28; t = " SCORE<1> HI-SCORE SCORE<2> "; end
		5'd1:  begin r = 5'd30; c = 5'd17; n = 5'd7;  t = "CREDIT "; end
		5'd2:  begin r = 5'd8;  c = 5'd12; n = 5'd4;  t = "PUSH"; end
		5'd3:  begin r = 5'd11; c = 5'd4;  n = 5'd20; t = "ONLY 1PLAYER  BUTTON"; end
		5'd4:  begin r = 5'd11; c = 5'd7;  n = 5'd14; t = "PLAY PLAYER<1>"; end
		5'd5:  begin r = 5'd5;  c = 5'd9;  n = 5'd9;  t = "GAME OVER"; end
		5'd6:  begin r = 5'd8;  c = 5'd12; n = 5'd4;  t = "PLAY"; end
		5'd7:  begin r = 5'd11; c = 5'd7;  n = 5'd15; t = "SPACE  INVADERS"; end
		5'd8:  begin r = 5'd15; c = 5'd4;  n = 5'd21; t = "*SCORE ADVANCE TABLE*"; end
		5'd9:  begin r = 5'd17; c = 5'd7;  n = 5'd3;  t = {8'h88, 8'h89, 8'h8A}; end
		5'd10: begin r = 5'd19; c = 5'd8;  n = 5'd2;  t = {8'h86, 8'h87}; end
		5'd11: begin r = 5'd21; c = 5'd8;  n = 5'd2;  t = {8'h84, 8'h85}; end
		5'd12: begin r = 5'd23; c = 5'd8;  n = 5'd2;  t = {8'h82, 8'h83}; end
		5'd13: begin r = 5'd17; c = 5'd10; n = 5'd10; t = "=? MYSTERY"; end
		5'd14: begin r = 5'd19; c = 5'd10; n = 5'd10; t = "=30 POINTS"; end
		5'd15: begin r = 5'd21; c = 5'd10; n = 5'd10; t = "=20 POINTS"; end
		5'd16: begin r = 5'd23; c = 5'd10; n = 5'd10; t = "=10 POINTS"; end
		5'd17: begin r = 5'd14; c = 5'd8;  n = 5'd12; t = "INSERT  COIN"; end
		default: begin r = 5'd17; c = 5'd4; n = 5'd17; t = "*1 PLAYER  1 COIN"; end
		endcase
		msg_info = {r, c, n, t};
	endfunction

	function automatic [10:0] script_cmd(input [4:0] p);	// the attract mode: {op, argument}
		case (p)
		5'd0:  script_cmd = {OP_CLR,  8'd0};
		5'd1:  script_cmd = {OP_WAIT, 8'd64};
		5'd2:  script_cmd = {OP_PRT,  8'd6};
		5'd3:  script_cmd = {OP_PRT,  8'd7};
		5'd4:  script_cmd = {OP_WAIT, 8'd64};
		5'd5:  script_cmd = {OP_PRB,  8'd8};
		5'd6:  script_cmd = {OP_PRB,  8'd9};
		5'd7:  script_cmd = {OP_PRB,  8'd10};
		5'd8:  script_cmd = {OP_PRB,  8'd11};
		5'd9:  script_cmd = {OP_PRB,  8'd12};
		5'd10: script_cmd = {OP_PRT,  8'd13};
		5'd11: script_cmd = {OP_PRT,  8'd14};
		5'd12: script_cmd = {OP_PRT,  8'd15};
		5'd13: script_cmd = {OP_PRT,  8'd16};
		5'd14: script_cmd = {OP_WAIT, 8'd128};
		5'd15: script_cmd = {OP_DEMO, 8'd0};
		5'd16: script_cmd = {OP_WAIT, 8'd64};
		5'd17: script_cmd = {OP_CLR,  8'd0};
		5'd18: script_cmd = {OP_PRB,  8'd17};
		5'd19: script_cmd = {OP_PRT,  8'd18};
		5'd20: script_cmd = {OP_WAIT, 8'd128};
		default: script_cmd = {OP_JMP, 8'd0};
		endcase
	endfunction

	// the score line, one character per call: i 0..26 -> {text address, character}
	function automatic [17:0] hud_char(input [4:0] i, input [15:0] sc, input [15:0] hi, input [7:0] cr,
			input [3:0] lv, input show_l, input blank_s);
		logic	[4:0]	r, c, i13;
		logic	[7:0]	ch;
		logic	[3:0]	k;
		r = 5'd3; c = 5'd0; ch = 8'h20;
		i13 = i - 5'd13;
		k = i13[3:0];
		if (i < 5'd4) begin
			c = 5'd3 + i;
			ch = blank_s ? 8'h20 : {4'h3, sc[4 * (3 - i[1:0]) +: 4]};
		end else if (i < 5'd8) begin
			c = 5'd7 + i;
			ch = {4'h3, hi[4 * (3 - i[1:0]) +: 4]};
		end else if (i < 5'd12) begin
			c = 5'd13 + i;
			ch = 8'h30;
		end else if (i == 5'd12) begin
			r = 5'd30; c = 5'd1;
			ch = show_l ? {4'h3, lv} : 8'h20;
		end else if (i < 5'd25) begin
			r = 5'd30; c = 5'd3 + {1'b0, k};
			ch = (show_l && ({1'b0, k[3:1]} + 4'd1 < lv)) ? (k[0] ? 8'h81 : 8'h80) : 8'h20;
		end else begin
			r = 5'd30; c = (i == 5'd25) ? 5'd24 : 5'd25;
			ch = {4'h3, (i == 5'd25) ? cr[7:4] : cr[3:0]};
		end
		hud_char = {r, c, ch};
	endfunction

	// ---------------------------------------------------------------- registers
	logic	[5:0]		ms, ret, ero_ret;
	logic	[2:0]		gm;
	logic	[4:0]		sub;				// step inside the mode
	logic	[7:0]		mt;					// mode timer, steps
	logic	[7:0]		frame;
	logic	[14:0]	pr_left;			// preset steps still to run
	logic				pr_pending;
	logic	[3:0]		pr_num;
	logic				preset_inv, demo, attract_demo;
	logic				coin_d, start_d, st_edge, armed;
	logic	[4:0]		sp;					// attract script pointer
	logic				wave_req, first, clr_wave;
	logic	[2:0]		wv;
	logic	[7:0]		wave_top;
	logic				wclr;
	logic	[6:0]		wclr_t;
	logic				invaded, extra_done;
	logic				bonus_lo;			// SW2 as the game started: the extra ship at 1000
	logic	[5:0]		n_alive;
	logic	[7:0]		dx;					// the rack's step: +2, +3 or -2 (two's complement)
	logic				drop;
	logic	[5:0]		mrt;				// march timer
	logic	[1:0]		pst;
	logic	[7:0]		pl_t;
	logic				pl_alt;
	logic	[3:0]		pl_n;
	logic	[3:0]		dm_ptr;
	logic	[4:0]		sh_t, aexp_t;
	logic	[3:0]		sc_ptr;
	logic				parity;				// shots completed, odd: the saucer comes from the left
	logic	[1:0]		bslot, bb;
	logic	[3:0]		pp;
	logic	[4:0]		ps;
	logic	[3:0]		bcol;
	logic	[2:0]		brow;
	logic	[5:0]		bj;
	logic	[1:0]		bc;
	logic	[10:0]	sc_timer;
	logic				sc_due, sc_dir;
	logic	[5:0]		sc_t;
	logic	[7:0]		sc_val;
	logic	[5:0]		rj;
	logic				wrapped;
	logic	[7:0]		box_x;
	logic	[15:0]	bmask;
	logic	[3:0]		bxc;
	logic	[9:0]		cc;					// PWR / CLR counter
	logic	[2:0]		rk;					// probe row counter
	logic				h_al, h_sc, h_bm, h_shd, h_pl, h_sh;
	logic	[5:0]		h_idx;
	logic	[1:0]		h_b;
	logic	[1:0]		ero_b;				// 3 = the shot, else a bomb slot
	logic	[7:0]		ero_x, ero_y;
	logic	[2:0]		ero_c;
	logic	[15:0]	ew;
	logic				tw_on;
	logic	[4:0]		tw_msg, tw_k;
	logic	[2:0]		tw_t;
	logic	[4:0]		msg_id, mk;
	logic	[4:0]		hk;
	logic				p_die, p_ufo_hit, p_extra, p_hit, p_shot, p_march;

	// the bombs, one slot per type: 0 rolling, 1 plunger, 2 squiggly
	logic	[1:0]		bst [0:2];			// 0 idle, 1 falling, 2 burst
	logic	[7:0]		bx [0:2], by [0:2];
	logic	[1:0]		bfr [0:2];
	logic	[7:0]		bsteps [0:2];		// turns since launch, saturating; 0 = none
	logic	[2:0]		bt [0:2];			// burst turns left
	assign bm_st    = {bst[2], bst[1], bst[0]};
	assign bm_x     = {bx[2], bx[1], bx[0]};
	assign bm_y     = {by[2], by[1], by[0]};
	assign bm_frame = {bfr[2], bfr[1], bfr[0]};

	// ---------------------------------------------------------------- memories
	// text screen: 32 x 32 characters, {row, column}
	logic	[7:0]		tram [0:1023];
	logic	[9:0]		ta_addr;
	logic				ta_we;
	logic	[7:0]		ta_wd;
	always @(posedge clk) if (ta_we) tram[ta_addr] <= ta_wd;
	always @(posedge clk) tb_q <= tram[tb_addr];

	// shields: one word per screen column x, bit = y - SHIELD_Y
	logic	[15:0]	smem [0:255];
	logic	[7:0]		sa_addr;
	logic				sa_we;
	logic	[15:0]	sa_wd, sa_q;
	always @(posedge clk) begin
		if (sa_we) smem[sa_addr] <= sa_wd;
		sa_q <= smem[sa_addr];
	end
	always @(posedge clk) sb_q <= smem[sb_addr];

	// ---------------------------------------------------------------- the probe: what is lit at (p_x, p_y)
	logic	[7:0]		p_x, p_y;
	wire				p_rack, p_ae, p_pl, p_sh, p_sc, p_shd, p_gnd_nc;
	wire	[5:0]		p_idx;
	wire	[2:0]		p_bm;
	inv_layers #(.SAUCER_Y(SAUCER_Y), .SHIELD_Y(SHIELD_Y), .PLAYER_Y(PLAYER_Y), .GROUND_Y(GROUND_Y)) u_probe (
		.x(p_x), .y(p_y), .shield_word(sa_q),
		.rack_on(rack_on), .old_x(old_x), .old_y(old_y), .new_x(new_x), .new_y(new_y),
		.old_frame(old_frame), .new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive),
		.aexp_on(aexp_on), .aexp_x(aexp_x), .aexp_y(aexp_y),
		.pl_on(pl_on), .pl_img(pl_img), .pl_x(pl_x),
		.sh_st(sh_st), .sh_x(sh_x), .sh_y(sh_y),
		.bm_st(bm_st), .bm_x(bm_x), .bm_y(bm_y), .bm_frame(bm_frame),
		.sc_st(sc_st), .sc_x(sc_x), .ground(ground),
		.rack_px(p_rack), .rack_idx(p_idx), .ae_px(p_ae), .pl_px(p_pl), .sh_px(p_sh),
		.bm_px(p_bm), .sc_px(p_sc), .shd_px(p_shd), .gnd_px(p_gnd_nc));

	// the shield art for a new wave, by the CLR counter's column
	wire	[5:0]		cc_sh = shield_col(cc[7:0]);
	wire	[15:0]	cc_art;
	inv_shield_rom u_shr (.col(cc_sh[4:0]), .bits(cc_art));

	// ---------------------------------------------------------------- derived signals
	wire				l_in = in_left  & ~ffwd;		// in fast-forward the controls count as released
	wire				r_in = in_right & ~ffwd;
	wire				f_in = in_fire  & ~ffwd;
	wire				c_in = in_coin  & ~ffwd;
	wire				s_in = in_start & ~ffwd;

	wire				playing    = (gm == GM_PLAY);
	wire				objs_move  = playing & ~wclr;
	wire				eff_inv    = (invincible | preset_inv) & ~attract_demo;
	wire				scoring    = ~attract_demo;
	wire				rack_moves = objs_move & ~aexp_on & (pst == P_ALIVE) & (n_alive != 6'd0);

	wire				bump_hit = p_rack | p_ae | (|p_bm) | p_sh;	// the saucer row is not tested
	wire				ero_px   = (ero_b == 2'd3) ? p_sh : p_bm[ero_b];
	wire	[7:0]		p_dy     = p_y - SHIELD_Y;

	// the alien the shot hit, where it is drawn now
	wire	[6:0]		h_rc  = div11(h_idx);
	wire				h_new = (h_idx < cursor);
	wire	[7:0]		h_ax  = (h_new ? new_x : old_x) + {h_rc[3:0], 4'd0};
	wire	[7:0]		h_ay  = (h_new ? new_y : old_y) - {1'b0, h_rc[6:4], 4'd0};
	wire	[15:0]	h_pts = (h_rc[6:4] >= 3'd4) ? 16'h0030 : (h_rc[6:4] >= 3'd2) ? 16'h0020 : 16'h0010;

	// the alien a bomb drops from
	wire				b_new = (bj < cursor);
	wire	[7:0]		b_ax  = (b_new ? new_x : old_x) + {bcol, 4'd0};
	wire	[7:0]		b_ay  = (b_new ? new_y : old_y) - {1'b0, brow, 4'd0};

	// the alien the rack step moves (already at the new reference)
	wire	[6:0]		r_rc = div11(rj);
	wire	[7:0]		r_ax = new_x + {r_rc[3:0], 4'd0};
	wire	[7:0]		r_ay = new_y - {1'b0, r_rc[6:4], 4'd0};

	// bombs
	wire	[7:0]		b_ny   = by[bslot] + ((n_alive <= 6'd8) ? 8'd5 : 8'd4);
	wire	[7:0]		b_inc  = (bsteps[bslot] == 8'hFF) ? 8'hFF : bsteps[bslot] + 8'd1;
	wire	[7:0]		rld    = reload_rate(score);
	wire	[2:0]		b_busy = {(bsteps[2] != 8'd0) && (bsteps[2] <= rld),
								  (bsteps[1] != 8'd0) && (bsteps[1] <= rld),
								  (bsteps[0] != 8'd0) && (bsteps[0] <= rld)};
	wire				reload_ok = ~|(b_busy & ~(3'b001 << bslot));
	wire	[7:0]		roll_c = (pl_x + 8'd8 - new_x) >> 4;
	wire	[3:0]		plg_c  = col_table({1'b0, pp}) - 4'd1;
	wire	[3:0]		sqg_c  = col_table(ps) - 4'd1;

	// saucer
	wire	[7:0]		sc_nx = sc_dir ? sc_x + 8'd2 : sc_x - 8'd2;

	// text
	wire	[238:0]	mi    = msg_info(msg_id);
	wire	[4:0]		m_row = mi[238:234];
	wire	[4:0]		m_col = mi[233:229];
	wire	[4:0]		m_len = mi[228:224];
	wire	[223:0]	m_str = mi[223:0];
	wire	[4:0]		m_k   = m_len - 5'd1 - mk;
	wire	[7:0]		m_ch  = m_str[{m_k, 3'b000} +: 8];
	wire	[4:0]		m_c   = m_col + mk;
	wire	[17:0]	hc    = hud_char(hk, score, hiscore, credits, lives, (gm == GM_INTRO) || playing,
								   (gm == GM_INTRO) && frame[3]);
	wire	[10:0]	scr     = script_cmd(sp);
	wire	[2:0]		scr_op  = scr[10:8];
	wire	[7:0]		scr_arg = scr[7:0];

	// ---------------------------------------------------------------- outputs
	assign pl_on  = (pst == P_ALIVE) || (pst == P_EXPL);
	assign pl_img = (pst == P_EXPL) ? (pl_alt ? 2'd2 : 2'd1) : 2'd0;
	assign in_game = playing & ~attract_demo;
	assign busy = (ms != S_IDLE);
	assign snd_die     = p_die     & ~attract_demo;
	assign snd_ufo_hit = p_ufo_hit & ~attract_demo;
	assign snd_extra   = p_extra   & ~attract_demo;
	assign snd_hit     = p_hit     & ~attract_demo;
	assign snd_shot    = p_shot    & ~attract_demo;
	assign snd_march   = p_march   & ~attract_demo;
	assign snd_ufo     = (sc_st == 2'd1) & playing & ~attract_demo;

	// ---------------------------------------------------------------- tasks (called from the one always block)
	task automatic kill_player();
		pst <= P_EXPL; pl_t <= EXPL_T; pl_alt <= 1'b0; pl_n <= 4'd0; p_die <= 1'b1;
	endtask

	task automatic shot_burst(input [7:0] y);		// y = the shot's top line
		sh_st <= 2'd2; sh_x <= sh_x - 8'd3; sh_y <= y - 8'd2; sh_t <= SH_BURST_T;
	endtask

	task automatic bomb_burst(input [1:0] s, input [7:0] y);	// y = the bomb's top line
		bst[s] <= 2'd2; bx[s] <= bx[s] - 8'd2; by[s] <= y + 8'd2; bt[s] <= BM_BURST_T;
	endtask

	task automatic erode(input [1:0] b, input [7:0] x0, input [7:0] y0, input [5:0] r);
		ero_b <= b; ero_x <= x0; ero_y <= y0; ero_c <= 3'd0; ero_ret <= r; ms <= S_ERO_COL;
	endtask

	task automatic clear_objects();
		rack_on <= 1'b0; pst <= P_OFF; sh_st <= 2'd0; sc_st <= 2'd0; aexp_on <= 1'b0; ground <= {224{1'b0}};
		for (int i = 0; i < 3; i++) begin bst[i] <= 2'd0; bsteps[i] <= 8'd0; end
	endtask

	task automatic start_wave();
		rack_on <= 1'b1; alive <= {55{1'b1}}; n_alive <= 6'd55;
		old_x <= RACK_X0; new_x <= RACK_X0; old_y <= wave_top; new_y <= wave_top;
		old_frame <= 1'b0; new_frame <= 1'b0; cursor <= 6'd0; fill <= 1'b1;
		dx <= 8'd2; drop <= 1'b0; mrt <= 6'd0; ground <= {224{1'b1}};
		wclr <= 1'b0; wclr_t <= 7'd0; invaded <= 1'b0;
		sh_st <= 2'd0; sc_st <= 2'd0; sc_timer <= SC_TIME; sc_due <= 1'b0; sc_ptr <= 4'd0; parity <= 1'b0;
		pp <= 4'd0; ps <= 5'd6;		// the arcade copies its RAM mirror at every rack: the pointers restart
		pst <= P_ALIVE; pl_x <= PL_XMIN; aexp_on <= 1'b0;
		for (int i = 0; i < 3; i++) begin bst[i] <= 2'd0; bsteps[i] <= 8'd0; end
	endtask

	task automatic full_reset(input pend, input [3:0] num);
		ms <= S_PWR; cc <= 10'd0; ret <= S_IDLE; ero_ret <= S_IDLE;
		gm <= GM_ATTRACT; sub <= 5'd0; mt <= 8'd0; frame <= 8'd0; sp <= 5'd0;
		ffwd <= 1'b0; paused <= 1'b0; pr_left <= 15'd0; pr_pending <= pend; pr_num <= num;
		preset_inv <= 1'b0; demo <= 1'b0; attract_demo <= 1'b0;
		coin_d <= 1'b0; start_d <= 1'b0; st_edge <= 1'b0; armed <= 1'b0;
		wave_req <= 1'b0; first <= 1'b1; wv <= 3'd0; clr_wave <= 1'b0; wave_top <= RACK_Y0;
		wclr <= 1'b0; wclr_t <= 7'd0; invaded <= 1'b0; extra_done <= 1'b0; bonus_lo <= 1'b0;
		score <= 16'h0000; hiscore <= 16'h0000; credits <= 8'h00; lives <= 4'd0;
		rack_on <= 1'b0; old_x <= RACK_X0; new_x <= RACK_X0; old_y <= RACK_Y0; new_y <= RACK_Y0;
		old_frame <= 1'b0; new_frame <= 1'b0; cursor <= 6'd0; fill <= 1'b0; alive <= 55'd0; n_alive <= 6'd0;
		dx <= 8'd2; drop <= 1'b0; mrt <= 6'd0; march_note <= 2'd0;
		aexp_on <= 1'b0; aexp_t <= 5'd0; aexp_x <= 8'd0; aexp_y <= 8'd0;
		pst <= P_OFF; pl_x <= PL_XMIN; pl_t <= 8'd0; pl_alt <= 1'b0; pl_n <= 4'd0; dm_ptr <= 4'd0;
		sh_st <= 2'd0; sh_x <= 8'd0; sh_y <= 8'd0; sh_t <= 5'd0; sc_ptr <= 4'd0; parity <= 1'b0;
		bslot <= 2'd0; bb <= 2'd0; pp <= 4'd0; ps <= 5'd6; bcol <= 4'd0; brow <= 3'd0; bj <= 6'd0; bc <= 2'd0;
		for (int i = 0; i < 3; i++) begin
			bst[i] <= 2'd0; bx[i] <= 8'd0; by[i] <= 8'd0; bfr[i] <= 2'd0; bsteps[i] <= 8'd0; bt[i] <= 3'd0;
		end
		sc_st <= 2'd0; sc_x <= 8'd0; sc_timer <= SC_TIME; sc_due <= 1'b0; sc_dir <= 1'b0; sc_t <= 6'd0;
		sc_val <= 8'h00; sc_score <= 12'h000; ground <= {224{1'b0}};
		rj <= 6'd0; wrapped <= 1'b0; box_x <= 8'd0; bmask <= 16'd0; bxc <= 4'd0; rk <= 3'd0;
		h_al <= 1'b0; h_sc <= 1'b0; h_bm <= 1'b0; h_shd <= 1'b0; h_pl <= 1'b0; h_sh <= 1'b0;
		h_idx <= 6'd0; h_b <= 2'd0; ero_b <= 2'd0; ero_x <= 8'd0; ero_y <= 8'd0; ero_c <= 3'd0; ew <= 16'd0;
		tw_on <= 1'b0; tw_msg <= 5'd0; tw_k <= 5'd0; tw_t <= 3'd0; msg_id <= 5'd0; mk <= 5'd0; hk <= 5'd0;
		p_x <= 8'd0; p_y <= 8'd0; ta_addr <= 10'd0; ta_wd <= 8'h20; sa_addr <= 8'd0; sa_wd <= 16'd0;
	endtask

	// ---------------------------------------------------------------- the micro-sequencer
	always @(posedge clk) begin
		ta_we <= 1'b0; sa_we <= 1'b0;
		p_die <= 1'b0; p_ufo_hit <= 1'b0; p_extra <= 1'b0; p_hit <= 1'b0; p_shot <= 1'b0; p_march <= 1'b0;
		if (!rst_n) full_reset(1'b0, 4'd0);
		else if (preset_go) full_reset(1'b1, preset_num);
		else begin
			if (pause_tgl && !ffwd) paused <= ~paused;
			case (ms)
			// ------------------------------------------------ wait for the next step
			S_IDLE: begin
				if (ffwd && pr_left == 15'd0) begin
					ffwd <= 1'b0; paused <= 1'b1; preset_inv <= 1'b0;
					if (!attract_demo) demo <= 1'b0;
				end else if (ffwd ? (pr_left != 15'd0) : (tick && !paused)) begin
					frame <= frame + 8'd1;
					if (ffwd) pr_left <= pr_left - 15'd1;
					coin_d <= c_in; start_d <= s_in; st_edge <= s_in & ~start_d;
					if (!f_in) armed <= 1'b1;
					if (c_in && !coin_d) begin
						credits <= bcd_inc99(credits);
						if (gm == GM_ATTRACT || attract_demo) begin
							gm <= GM_CREDIT; sub <= 5'd0; demo <= 1'b0; attract_demo <= 1'b0; tw_on <= 1'b0;
						end
					end
					ms <= S_MODE;
				end
			end

			// ------------------------------------------------ power-up: blank text, no shields, the header
			S_PWR: begin
				ta_we <= 1'b1; ta_addr <= cc; ta_wd <= 8'h20;
				if (cc < 10'd256) begin sa_we <= 1'b1; sa_addr <= cc[7:0]; sa_wd <= 16'h0000; end
				if (cc == 10'd1023) begin msg_id <= 5'd0; mk <= 5'd0; ret <= S_PWR_HDR; ms <= S_PRB; end
				else cc <= cc + 10'd1;
			end
			S_PWR_HDR: begin msg_id <= 5'd1; mk <= 5'd0; ret <= S_PWR_END; ms <= S_PRB; end
			S_PWR_END: begin
				ms <= S_IDLE;
				if (pr_pending) begin
					pr_pending <= 1'b0; ffwd <= 1'b1; pr_left <= preset_steps(pr_num);
					if (pr_num != 4'd0) begin
						gm <= GM_PLAY; demo <= 1'b1; preset_inv <= 1'b1; score <= 16'h0000;
						lives <= 4'd3; wave_req <= 1'b1; first <= 1'b1; wv <= 3'd0;	// whatever the switches say
					end
				end
			end

			// ------------------------------------------------ the mode
			S_MODE: begin
				ms <= S_BUMP0; ret <= S_BUMP0;
				case (gm)
				GM_ATTRACT: case (scr_op)
					OP_CLR: begin clr_wave <= 1'b0; cc <= 10'd0; ms <= S_CLR; sp <= sp + 5'd1; end
					OP_WAIT: begin
						if (sub == 5'd0) begin mt <= scr_arg; sub <= 5'd1; end
						else if (mt == 8'd0) begin sp <= sp + 5'd1; sub <= 5'd0; end
						else mt <= mt - 8'd1;
					end
					OP_PRT: begin
						if (sub == 5'd0) begin
							tw_on <= 1'b1; tw_msg <= scr_arg[4:0]; tw_k <= 5'd0; tw_t <= 3'd0; sub <= 5'd1;
						end else if (!tw_on) begin sp <= sp + 5'd1; sub <= 5'd0; end
					end
					OP_PRB: begin msg_id <= scr_arg[4:0]; mk <= 5'd0; ms <= S_PRB; sp <= sp + 5'd1; end
					OP_DEMO: begin
						gm <= GM_PLAY; demo <= 1'b1; attract_demo <= 1'b1; wave_req <= 1'b1; dm_ptr <= 4'd0;
						lives <= 4'd3 + {2'b00, dip_ships}; first <= 1'b1; wv <= 3'd0; sub <= 5'd0;
					end
					default: sp <= scr_arg[4:0];		// OP_JMP
					endcase
				GM_CREDIT: case (sub)
					5'd0: begin clr_wave <= 1'b0; cc <= 10'd0; ms <= S_CLR; sub <= 5'd1; end
					5'd1: begin msg_id <= 5'd2; mk <= 5'd0; ms <= S_PRB; sub <= 5'd2; end
					5'd2: begin msg_id <= 5'd3; mk <= 5'd0; ms <= S_PRB; sub <= 5'd3; end
					default: if (st_edge && credits != 8'h00) begin
						credits <= bcd_dec(credits); gm <= GM_INTRO; sub <= 5'd0;
					end
					endcase
				GM_INTRO: case (sub)
					5'd0: begin clr_wave <= 1'b0; cc <= 10'd0; ms <= S_CLR; sub <= 5'd1; end
					5'd1: begin
						score <= 16'h0000; lives <= 4'd3 + {2'b00, dip_ships}; extra_done <= 1'b0;
						bonus_lo <= dip_bonus; first <= 1'b1; wv <= 3'd0; demo <= 1'b0; attract_demo <= 1'b0;
						msg_id <= 5'd4; mk <= 5'd0; ms <= S_PRB; mt <= 8'd128; sub <= 5'd2;
					end
					default: begin
						if (mt == 8'd0) begin gm <= GM_PLAY; wave_req <= 1'b1; sub <= 5'd0; end
						else mt <= mt - 8'd1;
					end
					endcase
				GM_PLAY: if (wave_req) begin
					wave_req <= 1'b0; clr_wave <= 1'b1; cc <= 10'd0; ms <= S_CLR;
					wave_top <= first ? RACK_Y0 : wave_y(wv);
					if (!first) wv <= wv + 3'd1;
					first <= 1'b0;
				end
				default: case (sub)		// GM_OVER
					5'd0: begin
						if (score > hiscore) hiscore <= score;
						tw_on <= 1'b1; tw_msg <= 5'd5; tw_k <= 5'd0; tw_t <= 3'd0; sub <= 5'd1;
					end
					5'd1: if (!tw_on) begin mt <= 8'd128; sub <= 5'd2; end
					default: begin
						if (mt == 8'd0) begin
							gm <= (credits != 8'h00) ? GM_CREDIT : GM_ATTRACT; sp <= 5'd0; sub <= 5'd0;
						end else mt <= mt - 8'd1;
					end
					endcase
				endcase
			end

			// ------------------------------------------------ clear the play area (text rows 4..29, shields)
			S_CLR: begin
				ta_we <= 1'b1; ta_addr <= 10'd128 + cc; ta_wd <= 8'h20;
				if (cc < 10'd256) begin
					sa_we <= 1'b1; sa_addr <= cc[7:0]; sa_wd <= (clr_wave && cc_sh[5]) ? cc_art : 16'h0000;
				end
				if (cc == 10'd831) begin
					ms <= ret;
					if (clr_wave) start_wave(); else clear_objects();
				end else cc <= cc + 10'd1;
			end

			// ------------------------------------------------ print a whole message, one character a clock
			S_PRB: begin
				ta_we <= 1'b1; ta_addr <= {m_row, m_c}; ta_wd <= m_ch;
				if (mk == m_len - 5'd1) ms <= ret; else mk <= mk + 5'd1;
			end

			// ------------------------------------------------ the rack's edge: test the column it moves toward
			S_BUMP0: begin
				ms <= S_PLAYER;
				if (rack_moves) begin p_x <= dx[7] ? BUMP_L : BUMP_R; p_y <= BUMP_Y0; ms <= S_BUMP; end
			end
			S_BUMP: begin
				if (bump_hit) begin
					dx <= dx[7] ? ((n_alive == 6'd1) ? 8'd3 : 8'd2) : 8'hFE; drop <= 1'b1; ms <= S_PLAYER;
				end else if (p_y == BUMP_Y1) ms <= S_PLAYER;
				else p_y <= p_y + 8'd1;
			end

			// ------------------------------------------------ the cannon
			S_PLAYER: begin
				ms <= S_SHOT;
				if (playing) case (pst)
					P_ALIVE: if (!wclr) begin
						if (demo) begin
							if (demo_dir(dm_ptr) == 2'd1 && pl_x < PL_XMAX) pl_x <= pl_x + 8'd1;
							else if (demo_dir(dm_ptr) == 2'd2 && pl_x > PL_XMIN) pl_x <= pl_x - 8'd1;
						end else begin
							if (r_in && !l_in && pl_x < PL_XMAX) pl_x <= pl_x + 8'd1;
							else if (l_in && !r_in && pl_x > PL_XMIN) pl_x <= pl_x - 8'd1;
						end
					end
					P_EXPL: begin
						if (pl_t == 8'd1) begin
							if (pl_n == EXPL_N - 4'd1) begin pst <= P_HIDDEN; pl_t <= HIDE_T; end
							else begin pl_alt <= ~pl_alt; pl_t <= EXPL_T; end
							pl_n <= pl_n + 4'd1;
						end else pl_t <= pl_t - 8'd1;
					end
					P_HIDDEN: begin
						if (pl_t == 8'd1) begin
							pst <= P_OFF;
							if (attract_demo) begin
								gm <= GM_ATTRACT; sp <= sp + 5'd1; sub <= 5'd0; demo <= 1'b0; attract_demo <= 1'b0;
							end else if (invaded || lives <= 4'd1) begin
								lives <= 4'd0; gm <= GM_OVER; sub <= 5'd0;
							end else begin
								lives <= lives - 4'd1; pst <= P_ALIVE; pl_x <= PL_XMIN;
							end
						end else pl_t <= pl_t - 8'd1;
					end
					default: ;
					endcase
			end

			// ------------------------------------------------ the shot
			S_SHOT: begin
				ms <= S_BOMB;
				if (objs_move) case (sh_st)
					2'd0: if (pst == P_ALIVE && (demo || (f_in && armed))) begin
						sh_st <= 2'd1; sh_x <= pl_x + 8'd8; sh_y <= SHOT_Y0;
						sc_ptr <= (sc_ptr == 4'd14) ? 4'd0 : sc_ptr + 4'd1;
						dm_ptr <= (dm_ptr == 4'd9) ? 4'd0 : dm_ptr + 4'd1;
						p_shot <= 1'b1; armed <= 1'b0;
					end
					2'd1: begin
						if (sh_y - 8'd4 <= SHOT_TOP) shot_burst(sh_y - 8'd4);
						else begin sh_y <= sh_y - 8'd4; ms <= S_SH_COL; end
					end
					2'd2: begin
						if (sh_t == 5'd1) erode(2'd3, sh_x, sh_y, S_BOMB);
						else sh_t <= sh_t - 5'd1;
					end
					default: ;		// 3: waits for the invader's explosion
					endcase
			end
			S_SH_COL: begin
				sa_addr <= sh_x; p_x <= sh_x; p_y <= sh_y; rk <= 3'd0;
				h_al <= 1'b0; h_sc <= 1'b0; h_bm <= 1'b0; h_shd <= 1'b0;
				ms <= S_SH_WAIT;
			end
			S_SH_WAIT: ms <= S_SH_ROW;
			S_SH_ROW: begin
				if (p_rack && !h_al) begin h_al <= 1'b1; h_idx <= p_idx; end
				if (p_sc) h_sc <= 1'b1;
				if ((|p_bm) && !h_bm) begin h_bm <= 1'b1; h_b <= p_bm[0] ? 2'd0 : (p_bm[1] ? 2'd1 : 2'd2); end
				if (p_shd) h_shd <= 1'b1;
				p_y <= p_y + 8'd1; rk <= rk + 3'd1;
				if (rk == 3'd3) ms <= S_SH_HIT;
			end
			S_SH_HIT: begin
				ms <= S_BOMB;
				if (h_al) begin
					alive[h_idx] <= 1'b0; n_alive <= n_alive - 6'd1;
					if (scoring) score <= bcd_add(score, h_pts);
					aexp_on <= 1'b1; aexp_t <= AEXP_T; aexp_x <= h_ax; aexp_y <= h_ay;
					sh_st <= 2'd3; p_hit <= 1'b1;
				end else if (h_sc) begin
					if (sc_st == 2'd1) begin
						sc_st <= 2'd2; sc_t <= SC_HIT_T; sc_val <= sc_table(sc_ptr); p_ufo_hit <= 1'b1;
					end
					shot_burst(sh_y);
				end else if (h_bm) begin
					if (bst[h_b] == 2'd1) bomb_burst(h_b, by[h_b]);
					shot_burst(sh_y);
				end else if (h_shd) shot_burst(sh_y);
			end

			// ------------------------------------------------ erosion: clear the shield and ground under a burst
			S_ERO_COL: begin
				p_x <= ero_x + {5'd0, ero_c}; sa_addr <= ero_x + {5'd0, ero_c}; p_y <= ero_y; rk <= 3'd0;
				ms <= S_ERO_WAIT;
			end
			S_ERO_WAIT: ms <= S_ERO_LOAD;
			S_ERO_LOAD: begin ew <= sa_q; ms <= S_ERO_ROW; end
			S_ERO_ROW: begin
				if (ero_px) begin
					if (p_y >= SHIELD_Y && p_dy < 8'd16) ew[p_dy[3:0]] <= 1'b0;
					if (p_y == GROUND_Y && p_x < 8'd224) ground[p_x] <= 1'b0;
				end
				p_y <= p_y + 8'd1; rk <= rk + 3'd1;
				if (rk == 3'd7) ms <= S_ERO_STORE;
			end
			S_ERO_STORE: begin
				sa_we <= 1'b1; sa_wd <= ew;
				if (ero_c == 3'd7) begin
					ms <= ero_ret;
					if (ero_b == 2'd3) begin sh_st <= 2'd0; parity <= ~parity; end
					else begin bst[ero_b] <= 2'd0; bsteps[ero_b] <= 8'd0; end
				end else begin ero_c <= ero_c + 3'd1; ms <= S_ERO_COL; end
			end

			// ------------------------------------------------ one bomb slot per step (slot 2 or the saucer)
			S_BOMB: begin
				ms <= S_RACK;
				bb <= bslot;
				bslot <= (bslot == 2'd2) ? 2'd0 : bslot + 2'd1;
				if (objs_move) begin
					if (bslot == 2'd2 && (sc_st != 2'd0 || (sc_due && bst[2] == 2'd0))) ms <= S_SAUCER;
					else case (bst[bslot])
						2'd1: begin
							bsteps[bslot] <= b_inc; bfr[bslot] <= bfr[bslot] + 2'd1;
							if (b_ny >= BOMB_FLOOR) bomb_burst(bslot, b_ny);
							else begin
								by[bslot] <= b_ny; bc <= 2'd0; h_pl <= 1'b0; h_sh <= 1'b0; h_shd <= 1'b0;
								ms <= S_BM_COL;
							end
						end
						2'd2: begin
							bsteps[bslot] <= b_inc;
							if (bt[bslot] == 3'd1) erode(bslot, bx[bslot], by[bslot], S_RACK);
							else bt[bslot] <= bt[bslot] - 3'd1;
						end
						2'd0: if (pst == P_ALIVE && !fill && reload_ok && !(bslot == 2'd1 && n_alive == 6'd1)) begin
							brow <= 3'd0;
							case (bslot)
							2'd0: if (roll_c < 8'd11) begin
								bcol <= roll_c[3:0]; bj <= {2'b00, roll_c[3:0]}; ms <= S_BM_FIND;
							end
							2'd1: begin bcol <= plg_c; bj <= {2'b00, plg_c}; pp <= pp + 4'd1; ms <= S_BM_FIND; end
							default: begin
								bcol <= sqg_c; bj <= {2'b00, sqg_c}; ps <= (ps == 5'd20) ? 5'd6 : ps + 5'd1;
								ms <= S_BM_FIND;
							end
							endcase
						end
						default: ;
						endcase
				end
			end
			S_BM_FIND: begin
				if (alive[bj]) ms <= S_BM_SPAWN;
				else if (brow == 3'd4) ms <= S_RACK;
				else begin brow <= brow + 3'd1; bj <= bj + 6'd11; end
			end
			S_BM_SPAWN: begin
				bst[bb] <= 2'd1; bx[bb] <= b_ax + 8'd7; by[bb] <= b_ay + 8'd8; bfr[bb] <= 2'd0; bsteps[bb] <= 8'd1;
				ms <= S_RACK;
			end
			S_BM_COL: begin
				p_x <= bx[bb] + {6'd0, bc}; sa_addr <= bx[bb] + {6'd0, bc}; p_y <= by[bb]; rk <= 3'd0;
				ms <= S_BM_WAIT;
			end
			S_BM_WAIT: ms <= S_BM_ROW;
			S_BM_ROW: begin
				if (p_bm[bb]) begin
					if (p_pl && pst == P_ALIVE && !eff_inv) h_pl <= 1'b1;
					if (p_sh && sh_st == 2'd1) h_sh <= 1'b1;
					if (p_shd) h_shd <= 1'b1;
				end
				p_y <= p_y + 8'd1; rk <= rk + 3'd1;
				if (rk == 3'd7) begin
					if (bc == 2'd2) ms <= S_BM_HIT;
					else begin bc <= bc + 2'd1; ms <= S_BM_COL; end
				end
			end
			S_BM_HIT: begin
				ms <= S_RACK;
				if (h_pl) begin kill_player(); bst[bb] <= 2'd0; bsteps[bb] <= 8'd0; end
				else if (h_sh) begin shot_burst(sh_y); bomb_burst(bb, by[bb]); end
				else if (h_shd) bomb_burst(bb, by[bb]);
			end

			// ------------------------------------------------ the saucer (on slot 2's turn)
			S_SAUCER: begin
				ms <= S_RACK;
				case (sc_st)
				2'd0: if (pst == P_ALIVE) begin
					sc_st <= 2'd1; sc_due <= 1'b0; sc_dir <= parity; sc_x <= parity ? SC_XL : SC_XR;
				end
				2'd1: begin
					if (sc_nx < SC_XMIN || sc_nx >= SC_XMAX) begin sc_st <= 2'd0; sc_due <= 1'b0; sc_timer <= SC_TIME; end
					else sc_x <= sc_nx;
				end
				default: begin
					sc_t <= sc_t - 6'd1;
					if (sc_t == SC_SCORE_T + 6'd1) begin
						sc_st <= 2'd3; sc_score <= {sc_val, 4'h0};
						if (scoring) score <= bcd_add(score, {4'h0, sc_val, 4'h0});
					end
					if (sc_t == 6'd1) begin sc_st <= 2'd0; sc_timer <= SC_TIME; end
				end
				endcase
			end

			// ------------------------------------------------ the rack: move the next live invader
			S_RACK: begin
				ms <= S_CHECK;
				if (rack_moves) begin
					if (mrt == 6'd0) begin p_march <= 1'b1; march_note <= march_note + 2'd1; mrt <= march_delay(n_alive); end
					else mrt <= mrt - 6'd1;
					rj <= cursor; wrapped <= 1'b0; ms <= S_RACK_SCAN;
				end
			end
			S_RACK_SCAN: begin
				if (rj >= 6'd55) begin
					if (wrapped) ms <= S_CHECK;
					else begin
						wrapped <= 1'b1;
						old_x <= new_x; old_y <= new_y; new_x <= new_x + dx; new_y <= new_y + (drop ? 8'd8 : 8'd0);
						drop <= 1'b0; old_frame <= new_frame; new_frame <= ~new_frame; fill <= 1'b0;
						cursor <= 6'd0; rj <= 6'd0;
					end
				end else if (alive[rj]) begin cursor <= rj + 6'd1; ms <= S_RACK_MOVE; end
				else rj <= rj + 6'd1;
			end
			S_RACK_MOVE: begin
				ms <= S_CHECK;
				if (r_ay >= INVADE_Y) begin
					if (eff_inv) wave_req <= 1'b1;
					else begin invaded <= 1'b1; kill_player(); end
				end
				if (r_ay + 8'd7 >= SHIELD_Y && r_ay < SHIELD_Y + 8'd16) begin
					box_x <= r_ax; bmask <= box_mask(r_ay); bxc <= 4'd0; ms <= S_BOX_COL;
				end
			end
			S_BOX_COL: begin sa_addr <= box_x + {4'd0, bxc}; ms <= S_BOX_WAIT; end
			S_BOX_WAIT: ms <= S_BOX_LOAD;
			S_BOX_LOAD: begin
				sa_we <= 1'b1; sa_wd <= sa_q & ~bmask;
				if (bxc == 4'd15) ms <= S_CHECK;
				else begin bxc <= bxc + 4'd1; ms <= S_BOX_COL; end
			end

			// ------------------------------------------------ explosion timer, wave clear, saucer timer, bonus
			S_CHECK: begin
				ms <= S_HUD; hk <= 5'd0;
				if (playing) begin
					if (aexp_on) begin
						if (aexp_t == 5'd1) begin
							aexp_on <= 1'b0;
							if (sh_st == 2'd3) begin sh_st <= 2'd0; parity <= ~parity; end
						end else aexp_t <= aexp_t - 5'd1;
					end
					if (wclr) begin
						if (wclr_t == 7'd1) wave_req <= 1'b1;
						if (wclr_t != 7'd0) wclr_t <= wclr_t - 7'd1;
					end else if (n_alive == 6'd0 && pst == P_ALIVE) begin wclr <= 1'b1; wclr_t <= WCLR_T; end
					if (!wclr && sc_st == 2'd0 && !sc_due && new_y > RACK_Y0 && n_alive >= 6'd8) begin
						if (sc_timer == 11'd0) sc_due <= 1'b1; else sc_timer <= sc_timer - 11'd1;
					end
					if (!extra_done && score >= (bonus_lo ? BONUS_LO : BONUS_HI)) begin
						extra_done <= 1'b1; lives <= lives + 4'd1; p_extra <= 1'b1;
					end
				end
			end

			// ------------------------------------------------ the score line: 27 characters
			S_HUD: begin
				ta_we <= 1'b1; ta_addr <= hc[17:8]; ta_wd <= hc[7:0];
				if (hk == 5'd26) ms <= S_TYPE; else hk <= hk + 5'd1;
			end

			// ------------------------------------------------ the typewriter: one letter every 7 steps
			S_TYPE: begin
				ms <= S_IDLE;
				if (tw_on) begin
					if (tw_t == 3'd0) begin msg_id <= tw_msg; mk <= tw_k; ms <= S_TYPE2; end
					else tw_t <= tw_t - 3'd1;
				end
			end
			S_TYPE2: begin
				ta_we <= 1'b1; ta_addr <= {m_row, m_c}; ta_wd <= m_ch; tw_t <= 3'd6;
				if (tw_k == m_len - 5'd1) tw_on <= 1'b0; else tw_k <= tw_k + 5'd1;
				ms <= S_IDLE;
			end

			default: ms <= S_IDLE;
			endcase
		end
	end
endmodule
