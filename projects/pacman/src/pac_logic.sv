// Pac-Man game logic: one update per video frame (tick), done in a few hundred clocks during vertical blank.
//
// Coordinates: maze pixels, x 0..223, y 0..247 (28 x 31 tiles of 8). An actor at (x, y) stands in tile
// (x>>3, y>>3) and is at the tile's centre when x[2:0] == 4 and y[2:0] == 4; decisions are made only there.
// Directions: 0 up, 1 left, 2 down, 3 right (the arcade's tie order); the reverse of d is d ^ 2.
// Actors: 0 Pac-Man, 1 Blinky (red), 2 Pinky, 3 Inky (cyan), 4 Clyde (orange).
// Speed: each actor adds its speed (1/16 pixel per frame) to an accumulator and moves acc>>4 pixels (0..2).
// Ghost targets follow the arcade: Blinky = Pac-Man's tile; Pinky = 4 tiles ahead; Inky = the point 2 ahead,
// doubled away from Blinky; Clyde = Pac-Man when 8+ tiles away, else his corner. Scatter/chase by a timer.
// Score, high score and level are BCD so the screen and the 7-segment show them without dividing.
// ***********************************************
`default_nettype none

module pac_logic (
	input		wire				clk,
	input		wire				rst_n,
	input		wire				tick,			// one clock per frame
	input		wire				want_set,	// a direction was asked for (stick held, or a 'u/l/d/r' over USB)
	input		wire	[1:0]		want_dir,
	input		wire				start,		// Start / KEY0 / 's'
	input		wire				invincible,	// test aid: ghosts do not kill
	input		wire				pause,
	// dot RAM, read port for the screen
	input		wire	[9:0]		rb_addr,		// {row, col}
	output	logic	[1:0]		rb_q,			// 0 none, 1 dot, 2 power pellet
	// what the screen draws
	output	logic	[7:0]		pac_x, pac_y,
	output	logic	[1:0]		pac_dir,
	output	logic	[1:0]		pac_mouth,	// 0 closed .. 2 wide
	output	logic	[3:0]		death_phase,	// 0..11 while dying_anim
	output	logic				dying_anim,
	output	logic				pac_show,
	output	logic	[31:0]	g_x, g_y,	// ghost g in bits [8g-8 +: 8] (g = 1..4)
	output	logic	[7:0]		g_dir,
	output	logic	[11:0]	g_state,		// 3 bits per ghost: HOUSE, LEAVE, ACTIVE, EYES, ENTER
	output	logic	[3:0]		g_fright,
	output	logic				ghosts_show,
	output	logic				fright_flash,	// frightened time nearly over: blue/white
	output	logic	[23:0]	score, hiscore,
	output	logic	[3:0]		lives,		// including the one in play
	output	logic	[7:0]		level_bcd,
	output	logic				show_ready, show_gameover, show_push, maze_white,
	output	logic	[7:0]		frame,
	// sounds: one-clock pulses
	output	logic				snd_dot, snd_power, snd_ghost, snd_death, snd_intro,
	output	logic				fright_on
	);

localparam [2:0] HOUSE = 3'd0, LEAVE = 3'd1, ACTIVE = 3'd2, EYES = 3'd3, ENTER = 3'd4;
localparam [7:0] HOME_X = 8'd112, DOOR_Y = 8'd92, HOUSE_Y = 8'd116, PAC_Y = 8'd188;
localparam [7:0] DOTS_TOTAL = 8'd244;

// ---------------------------------------------------------------- dot RAM (port A here, port B for the screen)
logic	[1:0]		dots [0:1023];
logic	[9:0]		ra_addr;
logic	[1:0]		ra_wd, ra_q;
logic				ra_we;
always @(posedge clk) begin
	if (ra_we) dots[ra_addr] <= ra_wd;
	ra_q <= dots[ra_addr];
end
always @(posedge clk) rb_q <= dots[rb_addr];

// ---------------------------------------------------------------- tile table: one query port, one fill port
logic	signed [6:0]	qc, qr;			// tile asked about (may be -1 / 28 in the tunnel)
logic	[27:0]	q_wall_row, q_dot_nc, q_pow_nc, f_wall_nc, f_dot, f_pow;		// _nc: not connected
maze_tiles q_tiles(.row(qr[4:0]), .wall(q_wall_row), .dot(q_dot_nc), .power(q_pow_nc));
wire	q_wall = (qr < 0 || qr > 30) ? 1'b1 :
				 (qc < 0 || qc > 27) ? (qr != 14) :			// the tunnel row is open past the edge
				 q_wall_row[qc[4:0]];

logic	[9:0]		fill_addr;
maze_tiles f_tiles(.row(fill_addr[9:5]), .wall(f_wall_nc), .dot(f_dot), .power(f_pow));
wire	[1:0]		fill_val = (fill_addr[9:5] > 30 || fill_addr[4:0] > 27) ? 2'd0 :
							  f_pow[fill_addr[4:0]] ? 2'd2 : f_dot[fill_addr[4:0]] ? 2'd1 : 2'd0;

// ---------------------------------------------------------------- actors
logic	[7:0]		ax [0:4];
logic	[7:0]		ay [0:4];
logic	[1:0]		ad [0:4];
logic	[4:0]		acc [0:4];
logic	[2:0]		gst [0:4];
logic				gfr [0:4];

assign pac_x = ax[0];
assign pac_y = ay[0];
assign pac_dir = ad[0];
assign g_x = {ax[4], ax[3], ax[2], ax[1]};
assign g_y = {ay[4], ay[3], ay[2], ay[1]};
assign g_dir = {ad[4], ad[3], ad[2], ad[1]};
assign g_state = {gst[4], gst[3], gst[2], gst[1]};
assign g_fright = {gfr[4], gfr[3], gfr[2], gfr[1]};

function automatic signed [2:0] ddx(input [1:0] d);
	ddx = (d == 2'd1) ? -3'sd1 : (d == 2'd3) ? 3'sd1 : 3'sd0;
endfunction
function automatic signed [2:0] ddy(input [1:0] d);
	ddy = (d == 2'd0) ? -3'sd1 : (d == 2'd2) ? 3'sd1 : 3'sd0;
endfunction

// BCD add, 6 digits
function automatic [23:0] bcd_add(input [23:0] a, input [23:0] b);
	integer i;
	logic [4:0] s;
	logic c;
	begin
		c = 1'b0;
		for (i = 0; i < 6; i = i + 1) begin
			s = a[4*i +: 4] + b[4*i +: 4] + c;
			if (s > 5'd9) begin s = s + 5'd6; c = 1'b1; end else c = 1'b0;
			bcd_add[4*i +: 4] = s[3:0];
		end
	end
endfunction

// ---------------------------------------------------------------- game state
localparam [3:0] G_ATTRACT = 4'd0, G_FILL = 4'd1, G_READY = 4'd2, G_PLAY = 4'd3, G_FREEZE = 4'd4,
                 G_DYING = 4'd5, G_DEATH = 4'd6, G_LEVEL = 4'd7, G_OVER = 4'd8;
logic	[3:0]		gs, gs_after_fill;
logic	[9:0]		gtimer;			// frames left in the current game state
logic	[7:0]		level;			// binary, 1..
logic	[7:0]		dots_left, dots_life;
logic	[10:0]	fr_timer;		// frightened frames left
logic	[1:0]		chain;			// ghosts eaten on this power pellet
logic	[2:0]		mode_idx;		// even = scatter, odd = chase
logic	[10:0]	mode_timer;
logic	[9:0]		alive_frames;
logic				pac_pause, extra_given, new_game;
logic	[1:0]		want;
logic	[2:0]		mouth_cnt;
logic	[15:0]	lfsr;

always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]} | (lfsr == 0);

wire	[10:0]	fright_frames = (level == 1) ? 11'd360 : (level == 2) ? 11'd300 : (level == 3) ? 11'd240 :
								  (level == 4) ? 11'd180 : (level == 5) ? 11'd120 : 11'd60;
function automatic [10:0] mode_frames(input [2:0] i);
	case (i)
		3'd0, 3'd2: mode_frames = 11'd420;			// scatter 7 s
		3'd4, 3'd6: mode_frames = 11'd300;			// scatter 5 s
		default:    mode_frames = 11'd1200;			// chase 20 s (the last chase never ends)
	endcase
endfunction

// speed in 1/16 pixel per frame
function automatic [5:0] speed_of(input [2:0] a, input [2:0] st, input fr, input [7:0] y, input [7:0] x,
                                  input [7:0] lvl, input fright_any);
	if (a == 3'd0)
		speed_of = (lvl == 1) ? (fright_any ? 6'd18 : 6'd16) : (fright_any ? 6'd19 : 6'd18);
	else if (st == EYES)
		speed_of = 6'd32;
	else if (st != ACTIVE)
		speed_of = 6'd8;
	else if (y[7:3] == 5'd14 && (x < 8'd48 || x >= 8'd176))		// the tunnel slows ghosts
		speed_of = 6'd7;
	else if (fr)
		speed_of = 6'd8;
	else
		speed_of = (lvl == 1) ? 6'd15 : (lvl < 5) ? 6'd16 : 6'd17;
endfunction

// ---------------------------------------------------------------- per-frame micro sequencer
localparam [4:0] M_IDLE = 5'd0, M_ACTOR = 5'd1, M_STEP = 5'd2, M_PWANT = 5'd3, M_PFWD = 5'd4, M_TGT = 5'd5,
                 M_GQ = 5'd6, M_GR = 5'd7, M_MOVE = 5'd8, M_EAT = 5'd9, M_EAT2 = 5'd10, M_EAT3 = 5'd11,
                 M_DONE = 5'd12, M_NEXT = 5'd13, M_COLL = 5'd14, M_TIMERS = 5'd15;
logic	[4:0]		ms;
logic	[2:0]		a;					// actor being moved
logic	[1:0]		steps;
logic	[7:0]		cx, cy;
logic	[1:0]		cd;
logic	[2:0]		cst;
logic	[1:0]		k, best;
logic	[2:0]		tried;
logic	[13:0]	bestd;
logic	signed [7:0]	tx, ty;		// target tile
logic	[2:0]		cg;				// ghost for the collision pass

wire	[4:0]		tc = cx[7:3], tr = cy[7:3];
wire				at_center = (cx[2:0] == 3'd4) && (cy[2:0] == 3'd4);
wire	signed [7:0]	pcol = {3'b0, ax[0][7:3]}, prow = {3'b0, ay[0][7:3]};
wire	signed [7:0]	bcol = {3'b0, ax[1][7:3]}, brow = {3'b0, ay[1][7:3]};
wire	signed [7:0]	ccol = {3'b0, cx[7:3]},    crow = {3'b0, cy[7:3]};
wire	signed [7:0]	pdx = ddx(ad[0]), pdy = ddy(ad[0]);
// the arcade's "up" bug: looking ahead while Pac-Man faces up also shifts the point left
wire	signed [7:0]	ahead4_c = pcol + 8'sd4 * pdx - ((ad[0] == 2'd0) ? 8'sd4 : 8'sd0);
wire	signed [7:0]	ahead4_r = prow + 8'sd4 * pdy;
wire	signed [7:0]	ahead2_c = pcol + 8'sd2 * pdx - ((ad[0] == 2'd0) ? 8'sd2 : 8'sd0);
wire	signed [7:0]	ahead2_r = prow + 8'sd2 * pdy;
wire	signed [7:0]	clyde_dc = ccol - pcol, clyde_dr = crow - prow;
wire	[15:0]	clyde_d2 = clyde_dc * clyde_dc + clyde_dr * clyde_dr;
wire	signed [7:0]	dqc = {qc[6], qc} - tx, dqr = {qr[6], qr} - ty;
wire	[15:0]	qdist = dqc * dqc + dqr * dqr;

wire	want_ok = !q_wall;			// valid in M_PWANT: the tile in the wanted direction is open
wire	[1:0]		rev = cd ^ 2'd2;
wire	cand_ok = !q_wall && k != rev;		// valid in M_GR: direction k is open and not backwards
wire	better = cand_ok && qdist < {2'b0, bestd};
wire	fright_any = (fr_timer != 0);
assign fright_on = fright_any;
assign fright_flash = fright_any && fr_timer < 11'd120 && frame[3];

wire	[5:0]		spd = speed_of(a, gst[a], gfr[a], ay[a], ax[a], level, fright_any);
wire	[5:0]		acc_sum = {1'b0, acc[a]} + spd;

wire	[23:0]	level_next = bcd_add({16'd0, level_bcd}, 24'd1);
wire	[23:0]	ghost_pts = (chain == 2'd0) ? 24'h000200 : (chain == 2'd1) ? 24'h000400 :
								(chain == 2'd2) ? 24'h000800 : 24'h001600;
wire	[7:0]		gdx = (ax[cg] > ax[0]) ? ax[cg] - ax[0] : ax[0] - ax[cg];
wire	[7:0]		gdy = (ay[cg] > ay[0]) ? ay[cg] - ay[0] : ay[0] - ay[cg];

task automatic reset_actors;
	begin
		ax[0] <= HOME_X;      ay[0] <= PAC_Y;    ad[0] <= 2'd1;  gst[0] <= ACTIVE;
		ax[1] <= HOME_X;      ay[1] <= DOOR_Y;   ad[1] <= 2'd1;  gst[1] <= ACTIVE;
		ax[2] <= HOME_X;      ay[2] <= HOUSE_Y;  ad[2] <= 2'd2;  gst[2] <= HOUSE;
		ax[3] <= HOME_X - 8'd16; ay[3] <= HOUSE_Y;  ad[3] <= 2'd0;  gst[3] <= HOUSE;
		ax[4] <= HOME_X + 8'd16; ay[4] <= HOUSE_Y;  ad[4] <= 2'd0;  gst[4] <= HOUSE;
		for (int i = 0; i < 5; i++) begin acc[i] <= 5'd0; gfr[i] <= 1'b0; end
		want <= 2'd1; fr_timer <= 11'd0; chain <= 2'd0; mode_idx <= 3'd0; mode_timer <= mode_frames(3'd0);
		alive_frames <= 10'd0; dots_life <= 8'd0; pac_pause <= 1'b0; mouth_cnt <= 3'd0;
	end
endtask

always @(posedge clk) begin
	snd_dot <= 1'b0; snd_power <= 1'b0; snd_ghost <= 1'b0; snd_death <= 1'b0; snd_intro <= 1'b0;
	ra_we <= 1'b0;
	if (want_set) want <= want_dir;
	if (!rst_n) begin
		gs <= G_FILL; gs_after_fill <= G_ATTRACT; ms <= M_IDLE; fill_addr <= 10'd0; frame <= 8'd0;
		score <= 24'd0; hiscore <= 24'd0; lives <= 4'd3; level <= 8'd1; level_bcd <= 8'h01; extra_given <= 1'b0;
		gtimer <= 10'd0; new_game <= 1'b0;
		reset_actors();
	end else begin
		if (score > hiscore) hiscore <= score;
		if (!extra_given && score >= 24'h010000) begin extra_given <= 1'b1; lives <= lives + 1'b1; end

		case (gs)
		// ---- refill the dots (1024 clocks), then go on
		G_FILL: begin
			ra_addr <= fill_addr; ra_wd <= fill_val; ra_we <= 1'b1;
			fill_addr <= fill_addr + 1'b1;
			if (fill_addr == 10'h3FF) begin
				dots_left <= DOTS_TOTAL;
				reset_actors();
				gs <= gs_after_fill;
				gtimer <= new_game ? 10'd260 : 10'd120;
				if (gs_after_fill == G_READY && new_game) snd_intro <= 1'b1;
				new_game <= 1'b0;
			end
		end
		default: ;
		endcase

		if (tick && !pause) begin
			frame <= frame + 1'b1;
			if (gtimer != 0) gtimer <= gtimer - 1'b1;
			case (gs)
			G_ATTRACT, G_OVER:
				if (start && (gs == G_ATTRACT || gtimer == 0)) begin
					score <= 24'd0; lives <= 4'd3; level <= 8'd1; level_bcd <= 8'h01; extra_given <= 1'b0;
					new_game <= 1'b1; fill_addr <= 10'd0; gs_after_fill <= G_READY; gs <= G_FILL;
				end
			G_READY:
				if (gtimer == 0) gs <= G_PLAY;
			G_PLAY:
				ms <= M_ACTOR;
			G_FREEZE:
				if (gtimer == 0) gs <= G_PLAY;
			G_DYING:
				if (gtimer == 0) begin gs <= G_DEATH; gtimer <= 10'd126; snd_death <= 1'b1; end
			G_DEATH:
				if (gtimer == 0) begin
					if (lives <= 1) begin lives <= 4'd0; gs <= G_OVER; gtimer <= 10'd120; end
					else begin lives <= lives - 1'b1; reset_actors(); gs <= G_READY; gtimer <= 10'd120; end
				end
			G_LEVEL:
				if (gtimer == 0) begin
					level <= level + 1'b1; level_bcd <= level_next[7:0];
					fill_addr <= 10'd0; gs_after_fill <= G_READY; gs <= G_FILL;
				end
			default: ;
			endcase
			a <= 3'd0;
		end

		// ---- the frame's moves, one actor and one pixel at a time
		case (ms)
		M_IDLE: ;
		M_ACTOR: begin
			cx <= ax[a]; cy <= ay[a]; cd <= ad[a]; cst <= gst[a];
			if (a == 3'd0 && pac_pause) begin				// eating a dot costs Pac-Man one frame (the arcade's pause)
				pac_pause <= 1'b0; ms <= M_NEXT;
			end else begin
				acc[a] <= acc_sum[3:0]; steps <= acc_sum[5:4];
				ms <= (acc_sum[5:4] == 2'd0) ? M_NEXT : M_STEP;
			end
		end
		M_STEP:
			if (a == 3'd0) begin
				if (want == (cd ^ 2'd2)) cd <= want;					// reversing is allowed anywhere
				if (at_center) begin
					qc <= $signed({2'b0, tc}) + ddx(want); qr <= $signed({2'b0, tr}) + ddy(want);
					ms <= M_PWANT;
				end else ms <= M_MOVE;
			end else case (cst)
				HOUSE: ms <= M_DONE;
				LEAVE:
					if (cx != HOME_X) begin cd <= (cx < HOME_X) ? 2'd3 : 2'd1; ms <= M_MOVE; end
					else if (cy != DOOR_Y) begin cd <= 2'd0; ms <= M_MOVE; end
					else begin cst <= ACTIVE; cd <= 2'd1; ms <= M_DONE; end
				ENTER:
					if (cx != HOME_X) begin cd <= (cx < HOME_X) ? 2'd3 : 2'd1; ms <= M_MOVE; end
					else if (cy != HOUSE_Y) begin cd <= 2'd2; ms <= M_MOVE; end
					else begin cst <= LEAVE; gfr[a] <= 1'b0; ms <= M_DONE; end
				default:	// ACTIVE, EYES
					if (at_center) begin
						if (cst == EYES && tr == 5'd11 && (tc == 5'd13 || tc == 5'd14)) begin
							cst <= ENTER; ms <= M_DONE;
						end else ms <= M_TGT;
					end else ms <= M_MOVE;
			endcase
		M_PWANT: begin
			qc <= $signed({2'b0, tc}) + ddx(want_ok ? want : cd);
			qr <= $signed({2'b0, tr}) + ddy(want_ok ? want : cd);
			if (want_ok) cd <= want;
			ms <= M_PFWD;
		end
		M_PFWD:
			ms <= q_wall ? M_DONE : M_MOVE;			// a wall ahead: Pac-Man stops at the centre
		M_TGT: begin
			if (cst == EYES) begin tx <= 8'sd13; ty <= 8'sd11; end
			else if (mode_idx[0] == 1'b0 && mode_idx != 3'd7) begin		// scatter: each ghost's corner
				case (a)
					3'd1: begin tx <= 8'sd25; ty <= -8'sd3; end
					3'd2: begin tx <= 8'sd2;  ty <= -8'sd3; end
					3'd3: begin tx <= 8'sd27; ty <= 8'sd31; end
					default: begin tx <= 8'sd0; ty <= 8'sd31; end
				endcase
			end else case (a)
				3'd1: begin tx <= pcol; ty <= prow; end
				3'd2: begin tx <= ahead4_c; ty <= ahead4_r; end
				3'd3: begin tx <= 8'sd2 * ahead2_c - bcol; ty <= 8'sd2 * ahead2_r - brow; end
				default:
					if (clyde_d2 >= 16'd64) begin tx <= pcol; ty <= prow; end
					else begin tx <= 8'sd0; ty <= 8'sd31; end
			endcase
			k <= (gfr[a] && cst == ACTIVE) ? lfsr[1:0] : 2'd0;
			tried <= 3'd0; bestd <= 14'h3FFF; best <= rev;	// rev: only if every way is shut
			ms <= M_GQ;
		end
		M_GQ: begin
			qc <= $signed({2'b0, tc}) + ddx(k); qr <= $signed({2'b0, tr}) + ddy(k);
			ms <= M_GR;
		end
		M_GR:
			if (gfr[a] && cst == ACTIVE) begin				// frightened: the first open way from a random start
				if (cand_ok) begin cd <= k; ms <= M_MOVE; end
				else if (tried == 3'd3) begin cd <= rev; ms <= M_MOVE; end
				else begin k <= k + 1'b1; tried <= tried + 1'b1; ms <= M_GQ; end
			end else begin									// the open way closest to the target (ties: up, left, down, right)
				if (better) begin bestd <= qdist[13:0]; best <= k; end
				if (tried == 3'd3) begin cd <= better ? k : best; ms <= M_MOVE; end
				else begin k <= k + 1'b1; tried <= tried + 1'b1; ms <= M_GQ; end
			end
		M_MOVE: begin
			case (cd)
				2'd0: cy <= cy - 1'b1;
				2'd2: cy <= cy + 1'b1;
				2'd1: cx <= (cx == 8'd0) ? 8'd223 : cx - 1'b1;
				default: cx <= (cx == 8'd223) ? 8'd0 : cx + 1'b1;
			endcase
			if (a == 3'd0) begin mouth_cnt <= mouth_cnt + 1'b1; ms <= M_EAT; end
			else ms <= M_DONE;
		end
		M_EAT:
			if (at_center) begin ra_addr <= {tr, tc}; ms <= M_EAT2; end
			else ms <= M_DONE;
		M_EAT2: ms <= M_EAT3;
		M_EAT3: begin
			if (ra_q != 2'd0) begin
				ra_wd <= 2'd0; ra_we <= 1'b1;
				score <= bcd_add(score, (ra_q == 2'd2) ? 24'h000050 : 24'h000010);
				dots_left <= dots_left - 1'b1; dots_life <= dots_life + 1'b1;
				pac_pause <= 1'b1;
				snd_dot <= 1'b1;
				if (ra_q == 2'd2) begin
					fr_timer <= fright_frames; chain <= 2'd0; snd_power <= 1'b1;
					for (int g = 1; g < 5; g++)
						if (gst[g] == ACTIVE || gst[g] == HOUSE || gst[g] == LEAVE) begin
							gfr[g] <= 1'b1;
							if (gst[g] == ACTIVE) ad[g] <= ad[g] ^ 2'd2;
						end
				end
			end
			ms <= M_DONE;
		end
		M_DONE: begin
			ax[a] <= cx; ay[a] <= cy; ad[a] <= cd;
			if (a != 3'd0) gst[a] <= cst;
			if (steps > 2'd1) begin steps <= steps - 1'b1; ms <= M_STEP; end
			else ms <= M_NEXT;
		end
		M_NEXT:
			if (a == 3'd4) begin cg <= 3'd1; ms <= M_COLL; end
			else begin a <= a + 1'b1; ms <= M_ACTOR; end
		M_COLL: begin
			if (gst[cg] == ACTIVE && gdx <= 8'd4 && gdy <= 8'd4 && gs == G_PLAY) begin
				if (gfr[cg]) begin
					gst[cg] <= EYES; gfr[cg] <= 1'b0;
					score <= bcd_add(score, ghost_pts); chain <= chain + 1'b1;
					snd_ghost <= 1'b1; gs <= G_FREEZE; gtimer <= 10'd30;
				end else if (!invincible) begin
					gs <= G_DYING; gtimer <= 10'd60;
				end
			end
			if (cg == 3'd4) ms <= M_TIMERS;
			else cg <= cg + 1'b1;
		end
		M_TIMERS: begin
			alive_frames <= (alive_frames == 10'h3FF) ? alive_frames : alive_frames + 1'b1;
			if (fright_any) begin
				fr_timer <= fr_timer - 1'b1;
				if (fr_timer == 11'd1) for (int g = 1; g < 5; g++) gfr[g] <= 1'b0;
			end else if (mode_idx != 3'd7) begin
				if (mode_timer == 0) begin
					mode_idx <= mode_idx + 1'b1; mode_timer <= mode_frames(mode_idx + 1'b1);
					for (int g = 1; g < 5; g++) if (gst[g] == ACTIVE) ad[g] <= ad[g] ^ 2'd2;
				end else mode_timer <= mode_timer - 1'b1;
			end
			// leaving the house: Pinky at once, Inky after 30 dots or 4 s, Clyde after 60 dots or 8 s
			if (gst[2] == HOUSE) gst[2] <= LEAVE;
			if (gst[3] == HOUSE && (dots_life >= 8'd30 || alive_frames >= 10'd240)) gst[3] <= LEAVE;
			if (gst[4] == HOUSE && (dots_life >= 8'd60 || alive_frames >= 10'd480)) gst[4] <= LEAVE;
			if (dots_left == 8'd0 && gs == G_PLAY) begin gs <= G_LEVEL; gtimer <= 10'd180; end
			ms <= M_IDLE;
		end
		default: ms <= M_IDLE;
		endcase
	end
end

// ---------------------------------------------------------------- what the screen shows
wire	[9:0]		death_step = (10'd126 - gtimer) >> 3;		// 0..11 over the 96 animation frames
always_comb begin
	pac_mouth = (mouth_cnt[2:1] == 2'd0) ? 2'd0 : (mouth_cnt[2:1] == 2'd2) ? 2'd2 : 2'd1;
	dying_anim = (gs == G_DEATH);
	death_phase = (gtimer > 10'd30) ? death_step[3:0] : 4'd11;
	pac_show = !(gs == G_DEATH && gtimer <= 10'd30) && gs != G_OVER;
	ghosts_show = (gs != G_DEATH) && gs != G_OVER;
	show_ready = (gs == G_READY);
	show_gameover = (gs == G_OVER);
	show_push = (gs == G_ATTRACT);
	maze_white = (gs == G_LEVEL) && gtimer < 10'd120 && frame[3];
end

endmodule
