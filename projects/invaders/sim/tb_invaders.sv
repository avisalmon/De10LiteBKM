// Space Invaders logic + screen + sound together, no FPGA. A monitor checks the rules after every game step; the
// test plays: power-up -> attract (typed text, the silent demo game) -> two coins -> start -> intro -> play (move,
// march, a shot into a shield, the first bump, two columns shot away, a 300-point saucer, the rest of the wave shot
// down, the pause and the next wave lower) -> deaths until game over -> a second game with the rack's two top rows
// below line 255 (drawn, shot, turned, landed) -> the presets the board is compared with.
// Frames are written as PPM (320 x 240, like de10.py screen).
//   python scripts/sim.py projects/invaders/sim/tb_invaders.sv            (from the repo root; all 10 presets)
//   python scripts/sim.py projects/invaders/sim/tb_invaders.sv -D QUICK   (presets 0..2 only)
// sim-sources: lib/rtl/font8x8.sv ../src/inv_sprites.sv ../src/inv_rack.sv ../src/inv_layers.sv ../src/inv_draw.sv ../src/inv_sound.sv ../src/inv_logic.sv
`timescale 1ns/1ns
`default_nettype none

module tb_invaders;

logic clk = 0;
always #20 clk = ~clk;

logic rst_n = 0, tick = 0, in_left = 0, in_right = 0, in_fire = 0, in_coin = 0, in_start = 0;
logic invincible = 0, pause_tgl = 0, dip_bonus = 0, preset_go = 0;
logic [1:0] dip_ships = 0;
logic [3:0] preset_num = 0;
logic [31:0] pxl_x = 0, pxl_y = 0;

wire [9:0] tb_addr;
wire [7:0] tb_q, sb_addr;
wire [15:0] sb_q;
wire rack_on, old_frame, new_frame, fill, aexp_on, pl_on;
wire [7:0] old_x, old_y, new_x, new_y, aexp_x, aexp_y, pl_x, sh_x, sh_y, sc_x, credits;
wire [5:0] cursor, bm_st, bm_frame;
wire [54:0] alive;
wire [1:0] pl_img, sh_st, sc_st, march_note;
wire [23:0] bm_x, bm_y;
wire [11:0] sc_score, rgb;
wire [223:0] ground;
wire [15:0] score, hiscore;
wire [3:0] lives;
wire in_game, ffwd, paused, busy;
wire snd_die, snd_ufo_hit, snd_extra, snd_hit, snd_shot, snd_march, snd_ufo, buzz;

inv_logic game(.clk(clk), .rst_n(rst_n), .tick(tick), .in_left(in_left), .in_right(in_right), .in_fire(in_fire),
	.in_coin(in_coin), .in_start(in_start), .invincible(invincible), .pause_tgl(pause_tgl), .dip_ships(dip_ships),
	.dip_bonus(dip_bonus), .preset_go(preset_go), .preset_num(preset_num),
	.tb_addr(tb_addr), .tb_q(tb_q), .sb_addr(sb_addr), .sb_q(sb_q),
	.rack_on(rack_on), .old_x(old_x), .old_y(old_y), .new_x(new_x), .new_y(new_y), .old_frame(old_frame),
	.new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive), .aexp_on(aexp_on), .aexp_x(aexp_x),
	.aexp_y(aexp_y), .pl_on(pl_on), .pl_img(pl_img), .pl_x(pl_x), .sh_st(sh_st), .sh_x(sh_x), .sh_y(sh_y),
	.bm_st(bm_st), .bm_x(bm_x), .bm_y(bm_y), .bm_frame(bm_frame), .sc_st(sc_st), .sc_x(sc_x), .sc_score(sc_score),
	.ground(ground), .score(score), .hiscore(hiscore), .credits(credits), .lives(lives), .in_game(in_game),
	.ffwd(ffwd), .paused(paused), .busy(busy), .snd_die(snd_die), .snd_ufo_hit(snd_ufo_hit),
	.snd_extra(snd_extra), .snd_hit(snd_hit), .snd_shot(snd_shot), .snd_march(snd_march),
	.march_note(march_note), .snd_ufo(snd_ufo));

inv_draw draw(.clk(clk), .pxl_x(pxl_x), .pxl_y(pxl_y), .tb_addr(tb_addr), .tb_q(tb_q), .sb_addr(sb_addr),
	.sb_q(sb_q), .rack_on(rack_on), .old_x(old_x), .old_y(old_y), .new_x(new_x), .new_y(new_y),
	.old_frame(old_frame), .new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive),
	.aexp_on(aexp_on), .aexp_x(aexp_x), .aexp_y(aexp_y), .pl_on(pl_on), .pl_img(pl_img), .pl_x(pl_x),
	.sh_st(sh_st), .sh_x(sh_x), .sh_y(sh_y), .bm_st(bm_st), .bm_x(bm_x), .bm_y(bm_y), .bm_frame(bm_frame),
	.sc_st(sc_st), .sc_x(sc_x), .sc_score(sc_score), .ground(ground), .rgb(rgb));

inv_sound sound(.clk(clk), .tick(tick), .mute(1'b0), .snd_die(snd_die), .snd_ufo_hit(snd_ufo_hit),
	.snd_extra(snd_extra), .snd_hit(snd_hit), .snd_shot(snd_shot), .snd_march(snd_march),
	.march_note(march_note), .snd_ufo(snd_ufo), .buzz(buzz));

// ---------------------------------------------------------------- helpers
integer errors = 0;
task automatic check(input cond, input [8*72-1:0] what);
	if (cond !== 1'b1) begin errors = errors + 1; $display("FAIL: %0s", what); end
	else $display("ok:   %0s", what);
endtask

// one game step: a tick, then wait until the logic is idle again
integer steps_run = 0;
task automatic step();
	integer n;
	begin
		@(negedge clk) tick = 1;
		@(negedge clk) tick = 0;
		n = 0;
		while (busy && n < 40000) begin @(negedge clk); n = n + 1; end
		if (busy) begin $display("FAIL: a step never ended (state %0d)", game.ms); $finish; end
		steps_run = steps_run + 1;
		#1;		// the monitor counts this step on the same clock edge: let it run before the test reads its counts
	end
endtask

task automatic steps(input integer k);
	repeat (k) step();
endtask

// the text screen holds s (n characters, first one leftmost) at (row, col)
function automatic logic text_is(input integer row, input integer col, input [8*28-1:0] s, input integer n);
	integer k;
	begin
		text_is = 1'b1;
		for (k = 0; k < n; k = k + 1)
			if (game.tram[row * 32 + col + k] !== s[8 * (n - 1 - k) +: 8]) text_is = 1'b0;
	end
endfunction

// print the text screen (for debugging a failed text check)
task automatic dump_text();
	integer r, c;
	logic [7:0] ch;
	logic [8*28-1:0] line;
	for (r = 0; r < 32; r = r + 1) begin
		line = '0;
		for (c = 0; c < 28; c = c + 1) begin
			ch = game.tram[r * 32 + c];
			line = {line[8*27-1:0], (ch >= 8'h20 && ch < 8'h7F) ? ch : 8'h23};
		end
		$display("%2d |%s|", r, line);
	end
endtask

// render the screen as the board shows it (every 2nd scan pixel) into a PPM
task automatic render(input [8*32-1:0] name);
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
		pxl_x = 0; pxl_y = 0;
		$display("wrote %0s", name);
	end
endtask

// one line of the game's screen (ay 8..247) as the board shows it: line_rgb[ax], ax 0..223
logic [11:0] line_rgb [0:223];
task automatic scan_line(input integer ay);
	integer x;
	begin
		pxl_y = 2 * (ay - 8);
		pxl_x = 32'hFFFFFFFF;
		for (x = 0; x < 640; x = x + 1) begin
			@(negedge clk) pxl_x = x;
			#1 if (x[0] == 0 && x >= 96 && x <= 542) line_rgb[x / 2 - 48] = rgb;
		end
		pxl_x = 0; pxl_y = 0;
	end
endtask

// ---------------------------------------------------------------- reference functions (written apart from the RTL)
function automatic [15:0] bcd_add16(input [15:0] a, input [15:0] b);
	integer i, s, c;
	begin
		c = 0;
		for (i = 0; i < 4; i = i + 1) begin
			s = a[4*i +: 4] + b[4*i +: 4] + c;
			c = (s > 9);
			bcd_add16[4*i +: 4] = c ? s - 10 : s;
		end
	end
endfunction

function automatic [7:0] sc_ref(input [3:0] i);		// the saucer's value in tens, by shots fired mod 15
	case (i)
	4'd1, 4'd2, 4'd7, 4'd12:	sc_ref = 8'h05;
	4'd4, 4'd13:				sc_ref = 8'h15;
	4'd8:						sc_ref = 8'h30;
	default:					sc_ref = 8'h10;
	endcase
endfunction

function automatic integer ones(input [255:0] v);
	integer i;
	begin
		ones = 0;
		for (i = 0; i < 256; i = i + 1) ones = ones + v[i];
	end
endfunction

function automatic integer ones55(input [54:0] v);
	integer i;
	begin
		ones55 = 0;
		for (i = 0; i < 55; i = i + 1) ones55 = ones55 + v[i];
	end
endfunction

function automatic [31:0] bcd4(input [15:0] v);		// 4 BCD digits as text
	bcd4 = {8'h30 + v[15:12], 8'h30 + v[11:8], 8'h30 + v[7:4], 8'h30 + v[3:0]};
endfunction

function automatic integer shield_bits(input integer s);	// lit pixels left in shield s (0..3)
	integer x;
	begin
		shield_bits = 0;
		for (x = 32 + 45 * s; x < 54 + 45 * s; x = x + 1) shield_bits = shield_bits + ones({240'd0, game.smem[x]});
	end
endfunction

// ---------------------------------------------------------------- the monitor: rules checked after every step
integer n_shot = 0, n_hit = 0, n_die = 0, n_march = 0, n_ufo_hit = 0, n_extra = 0, n_ufo_on = 0, n_buzz = 0;
integer n_buzz_march = 0, n_buzz_shot = 0;
integer n_fired = 0, waves = 0, saucers = 0, longest = 0, cur_len = 0, mon_steps = 0;
integer sc_hist [0:3];									// saucers scored: 50, 100, 150, 300
logic [15:0] sc_points = 0;								// BCD, saucer points scored in live games
logic busy_d = 0, buzz_d = 0, hit_seen = 0, extra_d = 0, wclr_d = 0;
logic [1:0] sc_st_d = 0;
logic [2:0] gm_d = 0;
logic [15:0] score_d = 0;
logic [3:0] lives_d = 0;
initial for (int i = 0; i < 4; i++) sc_hist[i] = 0;

// Rule B, what is drawn: after each step the monitor picks the next live invader on the screen and one of its lit
// pixels (from the testbench's own model of the rack), puts that pixel on a second copy of the rack's pixel logic,
// and one clock later the copy must say "lit, by that invader". The draw and the shot both use this logic.
logic [7:0] ck_x = 0, ck_y = 0;
logic [5:0] ck_want = 0;
logic ck_pending = 0;
integer ck_next = 0;
wire ck_lit;
wire [5:0] ck_idx;
inv_rack_pixel ck_rack(.x(ck_x), .y(ck_y), .old_x(old_x), .old_y(old_y), .old_frame(old_frame), .new_x(new_x),
	.new_y(new_y), .new_frame(new_frame), .cursor(cursor), .fill(fill), .alive(alive), .lit(ck_lit), .index(ck_idx));

task automatic zero_counts();
	n_shot = 0; n_hit = 0; n_die = 0; n_march = 0; n_ufo_hit = 0; n_extra = 0; n_ufo_on = 0; n_buzz = 0;
	n_buzz_march = 0; n_buzz_shot = 0; n_fired = 0;
endtask

task automatic mon_fail(input [8*72-1:0] what);
	errors = errors + 1;
	if (errors < 20) $display("FAIL: step %0d: %0s", mon_steps, what);
endtask

task automatic after_step();
	integer q, bad_i, bad_x, bad_y, cx, cy;
	begin
		mon_steps = mon_steps + 1;
		if (cur_len > longest) longest = cur_len;
		cur_len = 0;
		if ((^{game.ms, game.gm, game.sub, game.sp, game.pst, game.n_alive, game.dx, game.sc_timer, game.sc_ptr,
		       game.wv, score, hiscore, credits, lives, pl_x, new_x, new_y, old_x, old_y, cursor, alive, sh_st, sh_x,
		       sh_y, sc_st, sc_x, bm_st, bm_x, bm_y, ground, aexp_on, rack_on, fill}) === 1'bx)
			mon_fail("X in the game state");
		if (game.n_alive != ones55(alive)) mon_fail("n_alive is not the number of live invaders");
		if (pl_x < 16 || pl_x > 185) mon_fail("the cannon left its track (16..185)");
		if (gm_d == 3'd3 && game.gm == 3'd3 && score < score_d && score_d < 16'h9000) mon_fail("the score went down");
		if (sc_st_d == 2'd1 && sc_st == 2'd2 && game.sc_val !== sc_ref(game.sc_ptr))
			mon_fail("saucer value is not the table's entry for the shot count");
		if (sc_st_d == 2'd2 && sc_st == 2'd3) begin
			saucers = saucers + 1;
			if (sc_score !== {game.sc_val, 4'h0}) mon_fail("the saucer shows the wrong score");
			if (!game.attract_demo) begin
				if (!hit_seen && score !== bcd_add16(score_d, {4'h0, game.sc_val, 4'h0}))
					mon_fail("the saucer's points were not added");
				sc_points = bcd_add16(sc_points, {4'h0, game.sc_val, 4'h0});
			end
			case (game.sc_val)
			8'h05: sc_hist[0] = sc_hist[0] + 1;
			8'h10: sc_hist[1] = sc_hist[1] + 1;
			8'h15: sc_hist[2] = sc_hist[2] + 1;
			default: sc_hist[3] = sc_hist[3] + 1;
			endcase
		end
		if (game.extra_done && !extra_d) begin
			if (score < (dip_bonus ? 16'h1000 : 16'h1500)) mon_fail("extra ship below the bonus score");
			if (lives !== lives_d + 4'd1) mon_fail("the extra ship did not add a life");
		end
		if (game.wclr && !wclr_d) waves = waves + 1;
		if (game.gm == 3'd3 && rack_on && game.n_alive == 6'd0 && game.pst == 2'd0 && !game.wclr)
			mon_fail("the wave is empty but not cleared");
		// Rule A: every live invader's cell is on the screen, both coordinates taken modulo 256 like the arcade's
		// (x 0..208: the bump turns the rack at x 9 and 213; y 40..216: a top-left at 216 is a landing)
		if (game.gm == 3'd3 && rack_on) begin
			bad_i = -1;
			for (q = 0; q < 55; q = q + 1)
				if (alive[q]) begin
					cx = (((q < cursor) ? new_x : old_x) + 16 * (q % 11)) & 255;
					cy = (((q < cursor) ? new_y : old_y) - 16 * (q / 11)) & 255;
					if (bad_i < 0 && (cx > 208 || cy < 40 || cy > 216)) begin bad_i = q; bad_x = cx; bad_y = cy; end
				end
			if (bad_i >= 0) begin
				if (errors < 20) $display("      invader %0d at (%0d, %0d)", bad_i, bad_x, bad_y);
				mon_fail("a live invader left the screen");
			end
			if (game.n_alive != 6'd0) ck_pick();
		end
		sc_st_d = sc_st; gm_d = game.gm; score_d = score; lives_d = lives; extra_d = game.extra_done;
		wclr_d = game.wclr; hit_seen = 1'b0;
	end
endtask

always @(negedge clk) begin
	if (ck_pending) begin			// rule B, one clock after the pick (the rack registers do not change in between)
		ck_pending = 1'b0;
		if (!(ck_lit === 1'b1 && ck_idx === ck_want)) begin
			if (errors < 20)
				$display("      invader %0d at (%0d, %0d): lit %b, index %0d", ck_want, ck_x, ck_y, ck_lit, ck_idx);
			mon_fail("a live invader is not drawn where it is");
		end
	end
	if (snd_shot) n_shot = n_shot + 1;
	if (snd_hit) n_hit = n_hit + 1;
	if (snd_die) n_die = n_die + 1;
	if (snd_march) n_march = n_march + 1;
	if (snd_ufo_hit) n_ufo_hit = n_ufo_hit + 1;
	if (snd_extra) n_extra = n_extra + 1;
	if (snd_ufo) n_ufo_on = n_ufo_on + 1;
	if (game.p_shot) n_fired = n_fired + 1;
	if (game.p_hit) hit_seen = 1'b1;
	if (buzz !== buzz_d) begin
		n_buzz = n_buzz + 1; buzz_d = buzz;
		if (sound.half >= 17'd60000) n_buzz_march = n_buzz_march + 1;	// only the march notes are this low
		if (sound.shot_t != 5'd0) n_buzz_shot = n_buzz_shot + 1;
	end
	if (busy === 1'b1) cur_len = cur_len + 1;
	if (busy_d === 1'b1 && busy === 1'b0) after_step();
	busy_d = busy;
end

// ---------------------------------------------------------------- moves the test uses
task automatic wait_idle();
	while (busy !== 1'b0) @(negedge clk);
endtask

task automatic step_gap(input integer gap);		// a step, then the rest of a (shortened) frame for the buzzer
	step();
	repeat (gap) @(negedge clk);
endtask

task automatic coin();								// a coin: 2 steps in the slot, 2 steps out
	in_coin = 1; steps(2); in_coin = 0; steps(2);
endtask

function automatic [54:0] col_mask(input integer c);	// the 5 invaders of column c
	integer r;
	begin
		col_mask = 55'd0;
		for (r = 0; r < 5; r = r + 1) col_mask[r * 11 + c] = 1'b1;
	end
endfunction

// ---------------------------------------------------------------- the wave-clear bot
// To clear a wave before it lands, the test must shoot like a good player. It shoots the edge columns first (a
// narrower rack walks further between bumps, so it drops less often) and wastes no shot. Before every step it plays
// the rack forward exactly as inv_logic will move it: one live invader per step, the bump at the edge, the drop, the
// freeze while an invader explodes, the shot still in flight. Then, for the lowest invader of each column and each
// delay d, it finds the x where a shot fired d steps from now meets that invader's lit pixels, through a shield gap,
// past the bombs already falling, and if it can, beside the lane where the invader's own bombs fall. It walks to
// the cheapest such x (cost: d, plus 25 per column away from the edge) and fires when d is 0.

// the invader pictures, from the screen's own ROM: inv_bm[16 * {kind, frame, row} +: 16], bit 0 = the leftmost
wire [1023:0] inv_bm;
genvar ga;
generate for (ga = 0; ga < 64; ga = ga + 1) begin : g_bm
	localparam [5:0] A = ga;
	inv_invader_rom u_bm(.kind(A[5:4]), .frame(A[3]), .row(A[2:0]), .bits(inv_bm[16 * ga +: 16]));
end endgenerate

logic [15:0] cols_t [0:5];							// the lit columns of each {kind, frame} (the 8 rows ORed)
task automatic init_bot();
	integer k, f, r;
	for (k = 0; k < 3; k = k + 1)
		for (f = 0; f < 2; f = f + 1) begin
			cols_t[k * 2 + f] = 16'h0000;
			for (r = 0; r < 8; r = r + 1)
				cols_t[k * 2 + f] = cols_t[k * 2 + f] | inv_bm[16 * (k * 16 + f * 8 + r) +: 16];
		end
endtask

function automatic integer kind_of(input integer i);	// 0: rows 0-1 (10 points), 1: rows 2-3, 2: row 4
	kind_of = (i >= 44) ? 2 : (i >= 22) ? 1 : 0;
endfunction

function automatic [255:0] rotl(input [255:0] v, input integer n);	// bit b moves to bit (b + n) mod 256
	integer k;
	begin
		k = n & 255;
		rotl = (k == 0) ? v : ((v << k) | (v >> (256 - k)));
	end
endfunction

function automatic [255:0] span_mask(input integer lo, input integer hi);	// bits lo..hi
	span_mask = ({256{1'b1}} >> (255 - (hi - lo))) << lo;
endfunction

// invader i of a rack (references nx/ny new, ox/oy old, the cursor, the frames): is it lit at (x, y)? Both
// coordinates wrap modulo 256, like the arcade's (and inv_rack_pixel's): the rack's reference passes line 255 when
// the bottom rows are shot away.
function automatic logic lit_at(input integer i, input integer x, input integer y, input integer nx,
	input integer ny, input integer ox, input integer oy, input integer cu, input integer nf, input integer of);
	integer xi, yi, b, v;
	logic [15:0] row;
	begin
		xi = (((i < cu) ? nx : ox) + 16 * (i % 11)) & 255;
		yi = (((i < cu) ? ny : oy) - 16 * (i / 11)) & 255;
		b = (x - xi) & 255;
		v = (y - yi) & 255;
		lit_at = 1'b0;
		if (v < 8 && b < 16) begin
			row = inv_bm[16 * (kind_of(i) * 16 + ((i < cu) ? nf : of) * 8 + v) +: 16];
			lit_at = row[b];
		end
	end
endfunction

// the same, in any of its 8 rows (the bump tests a whole column of the screen)
function automatic logic lit_col(input integer i, input integer x, input integer nx, input integer ox,
	input integer cu, input integer nf, input integer of);
	integer xi, b;
	logic [15:0] cols;
	begin
		xi = (((i < cu) ? nx : ox) + 16 * (i % 11)) & 255;
		b = (x - xi) & 255;
		cols = cols_t[kind_of(i) * 2 + ((i < cu) ? nf : of)];
		lit_col = (b < 16) ? cols[b] : 1'b0;
	end
endfunction

// rule B's pick (the monitor): the next live invader on the screen after the last one checked, and one of its lit
// pixels (a different one each step)
task automatic ck_pick();
	integer q, j, fr, xi, yi, r, c, n, want;
	logic [15:0] bits;
	begin
		j = -1;
		for (q = 1; q <= 55 && j < 0; q = q + 1)
			if (alive[(ck_next + q) % 55] && !(fill && (ck_next + q) % 55 >= cursor)) j = (ck_next + q) % 55;
		if (j >= 0) begin
			fr = (j < cursor) ? new_frame : old_frame;
			xi = (((j < cursor) ? new_x : old_x) + 16 * (j % 11)) & 255;
			yi = (((j < cursor) ? new_y : old_y) - 16 * (j / 11)) & 255;
			n = 0;
			for (r = 0; r < 8; r = r + 1) n = n + ones({240'd0, inv_bm[16 * (kind_of(j) * 16 + fr * 8 + r) +: 16]});
			want = mon_steps % n;
			n = 0;
			for (r = 0; r < 8; r = r + 1) begin
				bits = inv_bm[16 * (kind_of(j) * 16 + fr * 8 + r) +: 16];
				for (c = 0; c < 16; c = c + 1)
					if (bits[c]) begin
						if (n == want) begin ck_x = (xi + c) & 255; ck_y = (yi + r) & 255; end
						n = n + 1;
					end
			end
			ck_want = j; ck_next = j; ck_pending = 1'b1;
		end
	end
endtask

task automatic col_range(input [54:0] a, output integer cmin, output integer cmax);
	integer i;
	begin
		cmin = 11; cmax = -1;
		for (i = 0; i < 55; i = i + 1)
			if (a[i]) begin
				if (i % 11 < cmin) cmin = i % 11;
				if (i % 11 > cmax) cmax = i % 11;
			end
	end
endtask

localparam FM = 160;									// steps played forward
integer fm_nx [0:FM], fm_ny [0:FM], fm_ox [0:FM], fm_oy [0:FM], fm_cu [0:FM], fm_nf [0:FM], fm_of [0:FM];
integer bot_dmin = 0, bot_cmin = 0, bot_cmax = 10, bot_gx = -1, bot_gd = -1, bot_gj = -1;
logic [54:0] bot_al = 0;								// the live invaders once the shot in flight has hit
logic [255:0] bot_pass = 0;							// the x where a shot passes the shields

// Play the rack forward: fm_*[m] = the rack after m more steps. In step m the edge column is tested first (the
// bump turns the rack and sets the drop), then the shot in flight moves up 4 lines and tests the rack, then the next
// live invader after the cursor moves to the new reference; past the last one, the references step by dx (and down
// 8) first. Nothing moves in the step an invader is hit, nor in the 15 after it. bot_dmin = in how many steps a new
// shot can be fired.
task automatic play_rack();
	integer m, nx, ny, ox, oy, cu, nf, of, dxs, drp, frz, na, cmin, cmax, q, r, i, hit, w0, v, vy, y, shy, sx, fly;
	integer cn, co;
	logic [54:0] a;
	begin
		nx = new_x; ny = new_y; ox = old_x; oy = old_y; cu = cursor; nf = new_frame; of = old_frame;
		dxs = game.dx[7] ? game.dx - 256 : game.dx;
		drp = game.drop;
		a = alive; na = game.n_alive;
		frz = aexp_on ? game.aexp_t : 0;
		fly = (sh_st == 2'd1); shy = sh_y; sx = sh_x;
		if (aexp_on) bot_dmin = game.aexp_t;			// the explosion ends; the next step can fire
		else if (sh_st == 2'd2) bot_dmin = game.sh_t;	// the burst ends; the next step can fire
		else if (sh_st == 2'd0) bot_dmin = game.armed ? 0 : 1;
		else bot_dmin = 0;								// in flight: found below
		col_range(a, cmin, cmax);
		for (m = 0; m <= FM; m = m + 1) begin
			fm_nx[m] = nx; fm_ny[m] = ny; fm_ox[m] = ox; fm_oy[m] = oy; fm_cu[m] = cu; fm_nf[m] = nf; fm_of[m] = of;
			if (m < FM && frz > 0) frz = frz - 1;
			else if (m < FM && na > 0) begin
				hit = 0;
				for (r = 0; r < 5; r = r + 1) begin
					i = r * 11 + ((dxs < 0) ? cmin : cmax);
					if (a[i] && lit_col(i, (dxs < 0) ? 9 : 213, nx, ox, cu, nf, of)) hit = 1;
				end
				if (hit) begin dxs = (dxs < 0) ? ((na == 1) ? 3 : 2) : -2; drp = 1; end
				v = -1;
				if (fly) begin
					w0 = shy - 4;
					if (w0 <= 36) begin fly = 0; bot_dmin = m + 17; end
					else begin
						shy = w0; vy = 999;
						cn = ((sx - nx) & 255) >> 4; co = ((sx - ox) & 255) >> 4;
						for (r = 0; r < 5; r = r + 1) begin
							i = r * 11 + cn;
							if (cn < 11 && i < cu && a[i])
								for (y = w0; y <= w0 + 3; y = y + 1)
									if (y < vy && lit_at(i, sx, y, nx, ny, ox, oy, cu, nf, of)) begin v = i; vy = y; end
							i = r * 11 + co;
							if (co < 11 && i >= cu && a[i])
								for (y = w0; y <= w0 + 3; y = y + 1)
									if (y < vy && lit_at(i, sx, y, nx, ny, ox, oy, cu, nf, of)) begin v = i; vy = y; end
						end
						if (v >= 0) begin
							fly = 0; bot_dmin = m + 16; a[v] = 1'b0; na = na - 1; frz = 15;
							col_range(a, cmin, cmax);
						end
					end
				end
				if (v < 0) begin
					q = cu;
					while (q < 55 && !a[q]) q = q + 1;
					if (q >= 55) begin
						ox = nx; oy = ny; nx = (nx + dxs) & 255; ny = (ny + (drp ? 8 : 0)) & 255; drp = 0;
						of = nf; nf = 1 - nf; q = 0;
						while (q < 55 && !a[q]) q = q + 1;
					end
					cu = q + 1;
				end
			end
		end
		bot_al = a; bot_cmin = cmin; bot_cmax = cmax;
	end
endtask

// A shot fired d steps from now at invader j (the lowest of its column): H = the x where it meets j's lit pixels,
// L = the lane where j's own bombs fall (x + 7..9) while the cannon walks and the shot flies.
task automatic shot_masks(input integer j, input integer d, output logic [255:0] H, output logic [255:0] L);
	integer s, m, w0, yj, xj, fr, y, lx, ylo, yhi, row, col, done;
	begin
		H = '0; L = '0; lx = -1;
		row = j / 11; col = j % 11;
		done = 0;
		for (m = (d > 20) ? d - 20 : 0; m <= d + 43 && !done; m = m + 1) begin
			xj = (((j < fm_cu[m]) ? fm_nx[m] : fm_ox[m]) + 16 * col) & 255;
			if (xj != lx) begin
				L[(xj + 7) & 255] = 1'b1; L[(xj + 8) & 255] = 1'b1; L[(xj + 9) & 255] = 1'b1; lx = xj;
			end
			s = m - d;
			if (s >= 1) begin
				w0 = 212 - 4 * s;
				yj = (((j < fm_cu[m]) ? fm_ny[m] : fm_oy[m]) - 16 * row) & 255;
				if (w0 + 3 < yj) done = 1;
				else if (w0 <= yj + 7) begin
					fr = (j < fm_cu[m]) ? fm_nf[m] : fm_of[m];
					ylo = (w0 > yj) ? w0 : yj;
					yhi = (w0 + 3 < yj + 7) ? w0 + 3 : yj + 7;
					for (y = ylo; y <= yhi; y = y + 1)
						H = H | rotl({240'd0, inv_bm[16 * (kind_of(j) * 16 + fr * 8 + (y - yj)) +: 16]}, xj);
				end
			end
		end
	end
endtask

// where the bombs now on the screen will be in the shot's way if it is fired d steps from now
function automatic [255:0] bomb_mask(input integer d);
	integer k, b;
	begin
		bomb_mask = '0;
		for (k = 0; k < 3; k = k + 1) begin
			if (bm_st[2 * k +: 2] == 2'd1 && bm_y[8 * k +: 8] + 4 * ((d + 1) / 3) <= 215)
				for (b = 0; b < 3; b = b + 1) bomb_mask[(bm_x[8 * k +: 8] + b) & 255] = 1'b1;
			if (bm_st[2 * k +: 2] == 2'd2 && bm_y[8 * k +: 8] <= 215 && d < 12)
				for (b = 0; b < 6; b = b + 1) bomb_mask[(bm_x[8 * k +: 8] + b) & 255] = 1'b1;
		end
	end
endfunction

// the plan: bot_gx (where the shot leaves), bot_gd (in how many steps), bot_gj (the invader); bot_gx -1: none
task automatic plan();
	integer key, side, c, r, j, d, cost, bestc, sxn, lo, hi, dd, fx, xx;
	logic [255:0] H, L, V, P, R;
	begin
		sxn = pl_x + 8;
		bestc = 1000000; bot_gx = -1; bot_gd = -1; bot_gj = -1;
		for (xx = 24; xx <= 193; xx = xx + 1) bot_pass[xx] = (game.smem[xx] == 16'h0000);
		for (key = 0; key <= 5; key = key + 1)
			for (side = 0; side < 2; side = side + 1) begin
				c = side ? bot_cmax - key : bot_cmin + key;
				j = -1;
				if (side ? (bot_cmax - key > bot_cmin + key) : (bot_cmin + key <= bot_cmax - key))
					for (r = 4; r >= 0; r = r - 1) if (bot_al[r * 11 + c]) j = r * 11 + c;
				if (j >= 0)
					for (d = bot_dmin; d <= FM - 43 && d + 25 * key < bestc; d = d + 1) begin
						lo = (sxn - d - 1 < 24) ? 24 : sxn - d - 1;
						hi = (sxn + d + 1 > 193) ? 193 : sxn + d + 1;
						shot_masks(j, d, H, L);
						V = H & bot_pass & ~bomb_mask(d) & span_mask(lo, hi);
						if (V != '0) begin
							P = V & ~L;
							cost = d + 25 * key + ((P != '0) ? 0 : 12);
							if (cost < bestc) begin
								R = (P != '0) ? P : V;
								fx = -1;
								for (dd = 0; fx < 0 && dd < 256; dd = dd + 1)
									if (sxn - dd >= lo && R[sxn - dd]) fx = sxn - dd;
									else if (sxn + dd <= hi && R[sxn + dd]) fx = sxn + dd;
								bestc = cost; bot_gx = fx; bot_gd = d; bot_gj = j;
							end
						end
					end
			end
	end
endtask

// one step of the bot: play the rack forward, plan, then walk toward the plan's x and fire when it says now
task automatic bot_move();
	begin
		play_rack();
		plan();
		in_left = 0; in_right = 0; in_fire = 0;
		if (bot_gx >= 0) begin
			if (bot_gx > pl_x + 8) in_right = 1;
			else if (bot_gx < pl_x + 8) in_left = 1;
			if (bot_gd == 0) in_fire = 1;
		end
	end
endtask

// the flight step in which a shot fired now from x meets invader j (0: never), from the rack played forward
function automatic integer hit_step(input integer j, input integer x);
	integer s, y, w0;
	begin
		hit_step = 0;
		for (s = 1; s <= 43 && hit_step == 0; s = s + 1) begin
			w0 = 212 - 4 * s;
			for (y = w0; y <= w0 + 3; y = y + 1)
				if (hit_step == 0 &&
				    lit_at(j, x, y, fm_nx[s], fm_ny[s], fm_ox[s], fm_oy[s], fm_cu[s], fm_nf[s], fm_of[s]))
					hit_step = s;
		end
	end
endfunction

integer t, d, p, x, goal, aim, sx, x42, x43, d42, d43, s0, s1, x0, n_presets, lo, hi, k, ey, w0;
integer j, wv0, w1, n_lives, y12, nf0, n_kills, n_pred, pred_j, pred_t;
integer ay, ax, n_lit, n_bad, s_nx, s_ox, s_cu, s_nf, s_of;
logic [54:0] al_last;
logic [3:0] lv;
logic [15:0] w16;
logic [54:0] targets;

initial begin
	$display("tb_invaders: power-up");
	repeat (4) @(negedge clk);
	rst_n = 1;
	wait_idle();

	// 1. power-up: the header, the credit label, then the score line
	check(text_is(1, 0, " SCORE<1> HI-SCORE SCORE<2> ", 28), "power-up: the header on row 1");
	check(text_is(30, 17, "CREDIT ", 7), "power-up: 'CREDIT ' on row 30");
	check(game.gm == 3'd0 && credits == 8'h00, "power-up: attract mode, no credits");
	step();
	check(text_is(30, 24, "00", 2), "the score line shows the credits, 00");
	check(text_is(3, 3, "0000", 4) && text_is(3, 11, "0000", 4) && text_is(3, 21, "0000", 4),
		"the score line: score, hi-score and player 2 at 0000");

	// 2. attract: typed text, the score table, the silent demo game, insert coin
	t = 0; while (game.sp < 5'd4 && t < 400) begin step(); t = t + 1; end
	check(text_is(8, 12, "PLAY", 4) && text_is(11, 7, "SPACE  INVADERS", 15),
		"attract: 'PLAY' and 'SPACE  INVADERS' typed");
	t = 0; while (game.sp < 5'd14 && t < 1000) begin step(); t = t + 1; end
	check(text_is(15, 4, "*SCORE ADVANCE TABLE*", 21), "attract: the score table's title");
	check(game.tram[17*32+7] == 8'h88 && game.tram[17*32+8] == 8'h89 && game.tram[17*32+9] == 8'h8A,
		"attract: the saucer icon");
	check(game.tram[19*32+8] == 8'h86 && game.tram[19*32+9] == 8'h87 && game.tram[21*32+8] == 8'h84 &&
		game.tram[21*32+9] == 8'h85 && game.tram[23*32+8] == 8'h82 && game.tram[23*32+9] == 8'h83,
		"attract: the three invader icons");
	check(text_is(17, 10, "=? MYSTERY", 10) && text_is(19, 10, "=30 POINTS", 10) &&
		text_is(21, 10, "=20 POINTS", 10) && text_is(23, 10, "=10 POINTS", 10), "attract: the four values typed");
	render("attract.ppm");
	t = 0; while (!(game.gm == 3'd3 && game.attract_demo) && t < 300) begin step(); t = t + 1; end
	check(game.gm == 3'd3 && game.attract_demo && !in_game, "attract: the demo game starts (not a game)");
	zero_counts();
	t = 0;
	while (game.gm == 3'd3 && t < 12000) begin
		step(); t = t + 1;
		if (t == 200) render("demo.ppm");
	end
	$display("      the demo game lasted %0d steps; its cannon fired %0d shots", t, n_fired);
	check(game.gm == 3'd0, "attract: the demo ends when its cannon is hit");
	check(n_fired > 0, "attract: the demo's cannon fires");
	check(n_shot + n_hit + n_die + n_march + n_ufo_hit + n_extra == 0 && n_ufo_on == 0 && n_buzz == 0,
		"attract: the demo is silent");
	check(score == 16'h0000 && hiscore == 16'h0000, "attract: the demo scores nothing");
	t = 0; while (game.sp < 5'd20 && t < 400) begin step(); t = t + 1; end
	check(text_is(14, 8, "INSERT  COIN", 12) && text_is(17, 4, "*1 PLAYER  1 COIN", 17),
		"attract: 'INSERT  COIN' and '*1 PLAYER  1 COIN'");

	// 3. two coins
	invincible = 1;			// for the play tests (the demo ignores it); off again for the deaths
	coin(); coin();
	check(credits == 8'h02 && game.gm == 3'd1, "two coins: 02 credits, the credit screen");
	check(text_is(8, 12, "PUSH", 4) && text_is(11, 4, "ONLY 1PLAYER  BUTTON", 20),
		"credit screen: 'PUSH' and 'ONLY 1PLAYER  BUTTON'");
	check(text_is(30, 24, "02", 2), "credit screen: the score line shows 02");
	render("credit.ppm");

	// 4. start: one credit used, the intro
	in_start = 1; step(); in_start = 0;
	check(credits == 8'h01 && game.gm == 3'd2, "start: one credit used, the intro");
	steps(2);
	check(text_is(11, 7, "PLAY PLAYER<1>", 14), "intro: 'PLAY PLAYER<1>'");
	render("intro.ppm");

	// 5. play: the first wave, the shields, the spare cannons
	t = 0; while (!(game.gm == 3'd3 && rack_on) && t < 200) begin step(); t = t + 1; end
	w0 = steps_run - 1;									// play steps count from the one that set up the wave
	check(game.gm == 3'd3 && rack_on && in_game, "play: the game starts (a real game, not the demo)");
	check(alive == {55{1'b1}} && game.n_alive == 6'd55, "play: 55 invaders");
	check(new_x == 8'd24 && new_y == 8'd128 && cursor == 6'd1 && game.dx == 8'd2,
		"play: the rack at (24, 128), the first invader moved, marching right");
	check(pl_x == 8'd16 && lives == 4'd3 && game.pst == 2'd0, "play: the cannon at x 16, 3 lives");
	check(ground == {224{1'b1}}, "play: the ground line is whole");
	check(game.tram[30*32+1] == 8'h33 && game.tram[30*32+3] == 8'h80 && game.tram[30*32+4] == 8'h81 &&
		game.tram[30*32+5] == 8'h80 && game.tram[30*32+6] == 8'h81 && game.tram[30*32+7] == 8'h20,
		"play: '3' and two spare cannons on row 30");
	d = 0;
	for (x = 0; x < 256; x = x + 1)
		if ((game.smem[x] != 16'h0000) !== ((x >= 32 && x < 54) || (x >= 77 && x < 99) || (x >= 122 && x < 144) ||
			(x >= 167 && x < 189))) d = d + 1;
	check(d == 0, "play: four shields, 22 columns each, at x 32, 77, 122, 167");
	check(shield_bits(0) == 288 && shield_bits(1) == 288 && shield_bits(2) == 288 && shield_bits(3) == 288,
		"play: each shield has its 288 pixels");
	steps(56);
	render("play.ppm");

	// 6. the cannon moves and stops at its edge; the pause freezes the game
	in_left = 1; steps(5); in_left = 0;
	check(pl_x == 8'd16, "move: the cannon stops at its left edge, x 16");
	in_right = 1; steps(18); in_right = 0;
	check(pl_x == 8'd34, "move: 18 steps right, x 34");
	x = game.frame;
	@(negedge clk) pause_tgl = 1;
	@(negedge clk) pause_tgl = 0;
	check(paused, "pause: paused");
	in_right = 1; steps(3); in_right = 0;
	check(pl_x == 8'd34 && game.frame == x[7:0], "pause: no step runs, the cannon stays");
	@(negedge clk) pause_tgl = 1;
	@(negedge clk) pause_tgl = 0;
	check(!paused, "pause: running again");

	// 7. the march: two sweeps of the rack, 2 px each, with the march notes on the buzzer
	zero_counts();
	x0 = new_x;
	repeat (110) step_gap(20000);
	check(new_x == x0 + 4, "march: two sweeps moved the rack 4 px right");
	check(n_march >= 2, "march: the march notes sound");
	check(n_buzz_march >= 1, "march: the buzzer plays them");

	// 8. a shot into a shield: it bursts on the shield's lowest lit pixel and bites a hole
	zero_counts();
	s0 = shield_bits(0);
	w16 = game.smem[42];
	ey = 0;
	for (k = 5; k >= 2; k = k - 1) if (w16[20 - 4 * k +: 4] != 4'd0) ey = 210 - 4 * k;
	in_fire = 1; step(); in_fire = 0;
	check(sh_st == 2'd1 && sh_x == 8'd42 && sh_y == 8'd212, "shot: fired from the cannon's middle, x 42, y 212");
	x = 0; d = 0; t = 0;
	while (sh_st != 2'd0 && t < 30) begin
		step_gap(16000); t = t + 1;
		if (sh_st == 2'd2 && x == 0) begin x = sh_x; d = sh_y; end
	end
	$display("      the burst at (%0d, %0d), expected (39, %0d)", x, d, ey);
	check(x == 39 && d == ey && ey != 0, "shot: the burst sits on the shield's edge (x 39)");
	check(sh_st == 2'd0, "shot: the burst ends");
	check(shield_bits(0) < s0, "shot: the burst bit a hole in the shield");
	check(score == 16'h0000, "shot: a shield is worth nothing");
	check(n_shot == 1 && n_buzz_shot >= 4, "shot: one shot sound, played on the buzzer");

	// 9. the first bump: the rack reaches the right edge, turns and drops 8 px
	t = 0; while (game.dx != 8'hFE && t < 400) begin step(); t = t + 1; end
	check(game.dx == 8'hFE && new_x == 8'd40 && game.drop, "bump: at x 40 the rack turns left and will drop");
	t = 0; while (new_x == 8'd40 && t < 60) begin step(); t = t + 1; end
	check(new_x == 8'd38 && new_y == 8'd136, "bump: the next sweep moves 2 px left and 8 px down");

	// 10. shoot away columns 4 and 5, always through the gap between shields 1 and 2 (x 99..121)
	targets = col_mask(4) | col_mask(5);
	sc_points = 0;
	t = 0;
	while ((alive & targets) != 55'd0 && t < 4000) begin
		aim = -1;
		if ((alive & col_mask(4)) != 55'd0 && new_x >= 27 && new_x <= 49) aim = new_x + 72;
		else if ((alive & col_mask(5)) != 55'd0 && new_x >= 11 && new_x <= 33) aim = new_x + 88;
		goal = aim - 8;
		in_left = 0; in_right = 0; in_fire = 0;
		if (aim >= 0) begin
			if (pl_x < goal) in_right = 1;
			else if (pl_x > goal) in_left = 1;
			else if (sh_st == 2'd0 && game.armed && game.pst == 2'd0) in_fire = 1;
		end
		step(); t = t + 1;
	end
	in_left = 0; in_right = 0; in_fire = 0;
	$display("      columns 4 and 5 took %0d steps", t);
	check(alive == ~targets, "columns: columns 4 and 5 shot away, the rest alive");
	check(score == bcd_add16(16'h0180, sc_points), "columns: 10 invaders, 180 points");
	check(text_is(3, 3, bcd4(score), 4), "columns: the score line shows the score");
	render("columns.ppm");

	// 11. the 300-point saucer: count the shots so the 8th of the wave (mod 15) is the one that hits it.
	// The lane: the shield gap (101..119) where it meets the empty columns 4 and 5 (rack x + 66..93).
	s1 = sc_hist[3];
	t = 0;
	while (sc_hist[3] == s1 && t < 6000) begin
		lo = (new_x + 66 > 101) ? new_x + 66 : 101;
		hi = (new_x + 93 < 119) ? new_x + 93 : 119;
		sx = pl_x + 8;
		in_left = 0; in_right = 0; in_fire = 0;
		if (sx < lo || sx > hi) begin
			goal = new_x + 80;
			if (goal < 101) goal = 101;
			if (goal > 119) goal = 119;
			goal = goal - 8;
			if (pl_x < goal) in_right = 1;
			else if (pl_x > goal) in_left = 1;
		end else if (sh_st == 2'd0 && game.armed && game.pst == 2'd0) begin
			if (sc_st == 2'd0) begin
				if (game.sc_ptr != 4'd7 && !game.sc_due && game.sc_timer > 11'd60) in_fire = 1;
			end else if (sc_st == 2'd1) begin
				// where the saucer is when the shot reaches its rows: 14 moves (15 for the top rows if the
				// fire step is the saucer's turn)
				x42 = game.sc_dir ? sc_x + 28 : sc_x - 28;
				x43 = x42 + ((game.bslot == 2'd2) ? (game.sc_dir ? 2 : -2) : 0);
				d42 = sx - x42; d43 = sx - x43;
				if (game.sc_ptr == 4'd7) begin
					if (d42 >= 8 && d42 <= 15) in_fire = 1;
				end else if ((d42 < 2 || d42 > 21) && (d43 < 2 || d43 > 21)) in_fire = 1;
			end
		end
		step(); t = t + 1;
	end
	in_left = 0; in_right = 0; in_fire = 0;
	$display("      the 300-point saucer took %0d steps (play step %0d); saucers 50/100/150/300: %0d %0d %0d %0d",
		t, steps_run - w0, sc_hist[0], sc_hist[1], sc_hist[2], sc_hist[3]);
	check(sc_hist[3] > s1, "saucer: the 8th shot hits the saucer for 300");
	check(score == bcd_add16(16'h0180, sc_points), "saucer: its points added to the score");

	// 12. the rest of the wave, shot by the bot (above): the edge columns first, each shot aimed where its invader
	// will be when the shot gets there. Every invader hit must be the one the bot aimed at, in the step its own model
	// of the rack predicted. The last one hit stops the game for 64 steps; then the next wave starts lower.
	wv0 = game.wv; w1 = waves;
	zero_counts();
	init_bot();
	y12 = new_y; n_kills = 0; n_pred = 0; pred_j = -1; pred_t = 0; al_last = alive;
	t = 0;
	while (!game.wclr && game.wv == wv0 && t < 20000) begin
		bot_move();
		nf0 = n_fired;
		step(); t = t + 1;
		if (n_fired != nf0) begin pred_j = bot_gj; pred_t = t + hit_step(bot_gj, sh_x); end
		if (alive != al_last) begin
			for (j = 0; j < 55; j = j + 1) if (al_last[j] && !alive[j]) k = j;
			n_kills = n_kills + 1;
			if (k == pred_j && t == pred_t) n_pred = n_pred + 1;
			pred_j = -1;
		end
		al_last = alive;
	end
	in_left = 0; in_right = 0; in_fire = 0;
	$display("      the rest of the wave took %0d steps (play step %0d, %0d shots, %0d drops: the rack at y %0d)",
		t, steps_run - w0, n_fired, (new_y - y12) / 8, new_y);
	$display("      %0d of %0d invaders hit as the bot predicted", n_pred, n_kills);
	check(n_kills == 45 && n_pred == n_kills, "wave: each hit the invader aimed at, in the step the bot predicted");
	check(game.wclr && game.n_alive == 6'd0 && game.wv == wv0, "wave: all 55 invaders shot down, no invasion");
	check(waves == w1 + 1, "wave: cleared once");
	check(score == bcd_add16(16'h0990, sc_points), "wave: 55 invaders, 990 points (and the saucers)");
	n_lives = lives; w16 = score; x = pl_x;
	d = 0;
	in_right = 1;										// held, and still the cannon must not move
	t = 0;
	while (game.wclr && t < 200) begin
		if (t == 32) in_right = 0;
		step(); t = t + 1;
		if (game.wclr && pl_x != x) d = d + 1;
	end
	in_right = 0;
	$display("      the pause lasted %0d steps", t);
	check(t == 65 && d == 0, "wave: 64 steps with everything stopped, the cannon too");
	check(alive == {55{1'b1}} && game.n_alive == 6'd55 && game.wv == wv0 + 1,
		"next wave: 55 invaders again, the wave count up");
	check(new_x == 8'd24 && new_y == 8'd152 && old_y == 8'd152 && cursor == 6'd1 && game.dx == 8'd2,
		"next wave: the rack at (24, 152), 24 px lower than the first");
	check(pl_x == 8'd16 && game.pst == 2'd0 && sh_st == 2'd0 && bm_st == 6'd0 && sc_st == 2'd0,
		"next wave: the cannon at x 16, no shot, bombs or saucer");
	check(shield_bits(0) == 288 && shield_bits(1) == 288 && shield_bits(2) == 288 && shield_bits(3) == 288 &&
		ground == {224{1'b1}}, "next wave: four whole shields and the whole ground line");
	check(lives == n_lives && score == w16, "next wave: the lives and the score carried over");
	render("wave2.ppm");

	// 13. deaths until game over (an extra ship at 1,500 adds one): stand between shields 0 and 1 until a bomb hits
	invincible = 0;
	zero_counts();
	n_lives = lives;
	for (d = 1; d <= n_lives; d = d + 1) begin
		t = 0;
		while (game.pst == 2'd0 && t < 3000) begin
			in_right = (pl_x < 8'd58); in_left = (pl_x > 8'd58);
			step(); t = t + 1;
		end
		in_left = 0; in_right = 0;
		$display("      death %0d at play step %0d (rack at y %0d)", d, steps_run - w0, new_y);
		check(game.pst != 2'd0, "death: a bomb hits the cannon");
		lv = lives;
		t = 0; while (game.pst != 2'd0 && game.gm == 3'd3 && t < 400) begin step(); t = t + 1; end
		if (d < n_lives) check(lives == lv - 4'd1 && pl_x == 8'd16 && game.pst == 2'd0,
			"death: one life less, a new cannon at x 16");
		else check(game.gm == 3'd4 && lives == 4'd0, "death: the last life lost, game over");
	end
	check(n_die == n_lives, "death: one explosion sound per death");

	// 14. game over: typed, the score kept as the hi-score, then the credit screen (one credit left)
	t = 0; while (!text_is(5, 9, "GAME OVER", 9) && t < 200) begin step(); t = t + 1; end
	check(text_is(5, 9, "GAME OVER", 9), "game over: 'GAME OVER' typed");
	check(hiscore == score && score != 16'h0000 && text_is(3, 11, bcd4(hiscore), 4),
		"game over: the score becomes the hi-score");
	render("gameover.ppm");
	t = 0; while (game.gm != 3'd1 && t < 300) begin step(); t = t + 1; end
	check(game.gm == 3'd1 && credits == 8'h01 && text_is(30, 24, "01", 2),
		"game over: the credit screen, 01 credit");

	// 15. a second game: the rack's two top rows below line 255. With the bottom three rows shot away the rack walks
	// on down, and its reference (the bottom row's top line) passes 255 and wraps to 0, like the arcade's 8-bit y.
	// Rows 3 and 4 are then still on the screen (lines 208 and 192) and must be drawn, hit by the shot, turned at the
	// edge and land on line 216. The test puts the rack there directly, between two steps, and plays it out. The
	// invincible switch is on: bombs miss, and the landing starts the next wave instead of ending the game.
	invincible = 1;
	steps(4);											// the credit screen finishes
	in_start = 1; step(); in_start = 0;
	check(credits == 8'h00 && game.gm == 3'd2, "second game: the last credit used, the intro");
	t = 0; while (!(game.gm == 3'd3 && rack_on) && t < 200) begin step(); t = t + 1; end
	t = 0; while (fill && t < 80) begin step(); t = t + 1; end
	check(game.gm == 3'd3 && rack_on && !fill && game.wv == 3'd0 && in_game,
		"second game: the first wave is in place");
	@(negedge clk); #2;
	game.alive = {22'h3FFFFF, 33'd0}; game.n_alive = 6'd22;
	game.new_x = 8'd24; game.old_x = 8'd24; game.new_y = 8'd0; game.old_y = 8'd0;
	game.cursor = 6'd0; game.dx = 8'd2; game.drop = 1'b0; ck_pending = 1'b0;
	render("rack_low.ppm");
	n_lit = 0; n_bad = 0;
	for (ay = 192; ay < 216; ay = ay + 1)
		if (ay < 200 || ay >= 208) begin
			scan_line(ay);
			for (ax = 0; ax < 224; ax = ax + 1) begin
				d = 0;
				for (j = 33; j < 55; j = j + 1)
					if (lit_at(j, ax, ay, new_x, new_y, old_x, old_y, cursor, new_frame, old_frame)) d = 1;
				if (d) begin
					n_lit = n_lit + 1;
					if (line_rgb[ax] === 12'h000 || (^line_rgb[ax]) === 1'bx) n_bad = n_bad + 1;
				end
			end
		end
	$display("      rows 3 and 4 at lines 208 and 192 (reference y 0): %0d lit pixels, %0d of them black",
		n_lit, n_bad);
	check(n_lit > 100 && n_bad == 0, "low rack: every lit pixel of rows 3 and 4 is on the screen");

	// the crab above the cannon: the shot's first test covers lines 208..211, where row 3 is lit in columns 2..12
	w16 = score; al_last = alive;
	t = 0;
	while (alive == al_last && t < 300) begin
		aim = (((38 < cursor) ? new_x : old_x) + 88) & 255;
		goal = aim - 8;
		in_left = 0; in_right = 0; in_fire = 0;
		if (pl_x < goal) in_right = 1;
		else if (pl_x > goal) in_left = 1;
		else if (sh_st == 2'd0 && game.armed && game.pst == 2'd0) in_fire = 1;
		step(); t = t + 1;
	end
	in_left = 0; in_right = 0; in_fire = 0;
	k = -1; for (j = 0; j < 55; j = j + 1) if (al_last[j] && !alive[j]) k = j;
	$display("      the shot at x %0d hit invader %0d after %0d steps", aim, k, t);
	check(k == 38 && alive == (al_last & ~(55'd1 << 38)) && score == bcd_add16(w16, 16'h0020),
		"low rack: the shot hits the crab in row 3, 20 points");

	// the bump: the right edge column (invaders 43 and 54) reaches x 213 when the reference is at x 42
	t = 0;
	while (game.dx != 8'hFE && t < 600) begin
		s_nx = new_x; s_ox = old_x; s_cu = cursor; s_nf = new_frame; s_of = old_frame;
		step(); t = t + 1;
	end
	$display("      the bump after %0d steps, the rack at x %0d", t, new_x);
	check(game.dx == 8'hFE && game.drop && new_x == 8'd42 && new_y == 8'd0 &&
		((alive[43] && lit_col(43, 213, s_nx, s_ox, s_cu, s_nf, s_of)) ||
		 (alive[54] && lit_col(54, 213, s_nx, s_ox, s_cu, s_nf, s_of))),
		"low rack: the edge probe sees rows 3 and 4 at x 213, the rack turns");

	// the drop to reference y 8 puts row 3 on line 216: a landing (with the invincible switch, the next wave)
	wv0 = game.wv; w1 = waves; n_lives = lives; w16 = score;
	t = 0; while (new_y != 8'd8 && t < 60) begin step(); t = t + 1; end
	check(new_y == 8'd8 && game.wave_req && game.wv == wv0 && game.n_alive == 6'd21,
		"low rack: the drop puts row 3 on line 216, a landing");
	step();
	check(game.wv == wv0 + 1 && alive == {55{1'b1}} && game.n_alive == 6'd55 && new_x == 8'd24 && new_y == 8'd152,
		"low rack: invincible, the landing starts the next wave at y 152");
	check(waves == w1 && lives == n_lives && score == w16, "low rack: no wave cleared, no life lost, no points");
	invincible = 0;

	// 16. the presets the board is compared with: each runs its steps at full speed, then pauses
`ifdef QUICK
	n_presets = 3;
`else
	n_presets = 10;
`endif
	for (p = 0; p < n_presets; p = p + 1) begin
		score_d = 0; gm_d = 0; waves = 0; saucers = 0;
		@(negedge clk) begin preset_num = p; preset_go = 1; end
		@(negedge clk) preset_go = 0;
		t = 0;
		while (!(paused && !busy && !ffwd) && t < 50000000) begin @(negedge clk); t = t + 1; end
		if (p == 0) check(paused && !in_game && (game.gm == 3'd0 || game.attract_demo),
			"preset 0: the attract screen, paused");
		else check(paused && game.gm == 3'd3 && in_game, "preset: a game in play, paused");
		render({"preset_", 8'h30 + p[7:0], ".ppm"});
		$display("      preset %0d: score %h, wave %0d (%0d cleared), %0d saucers, %0d lives, %0d invaders",
			p, score, game.wv, waves, saucers, lives, game.n_alive);
	end

	// 17. the timing budget and the totals
	// the tick is the start of vertical sync: 35 lines of 800 clocks are left before the first visible line
	check(longest < 28000, "every game step ends before the picture starts (35 lines x 800 clocks)");
	$display("      longest step %0d clocks; %0d game steps; saucers 50/100/150/300: %0d %0d %0d %0d",
		longest, mon_steps, sc_hist[0], sc_hist[1], sc_hist[2], sc_hist[3]);
	if (errors == 0) $display("PASS (%0d game steps)", mon_steps);
	else $display("FAIL: %0d checks failed", errors);
	$finish;
end

endmodule

