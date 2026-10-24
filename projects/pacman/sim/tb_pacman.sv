// Pac-Man logic + screen together, no FPGA. Renders frames to PPM (320 x 240, like the board's screen capture)
// and plays: attract -> start -> READY -> moving and eating -> a long self-steering game with checks.
//   python scripts/sim.py my_designs/pacman/sim/tb_pacman.sv          (run from the repo root)
// sim-sources: lib/rtl/font8x8.sv ../src/maze_tiles.sv ../src/pac_logic.sv ../src/ghost_sprite.sv ../src/pac_draw.sv
`timescale 1ns/1ns
`default_nettype none

module tb_pacman;

logic clk = 0;
always #20 clk = ~clk;

logic rst_n = 0, tick = 0, want_set = 0, start = 0, invincible = 0;
logic [1:0] want_dir = 0;
logic [31:0] pxl_x = 0, pxl_y = 0;

wire [9:0] rb_addr;
wire [1:0] rb_q;
wire [7:0] pac_x, pac_y, level_bcd, frame;
wire [1:0] pac_dir, pac_mouth;
wire [3:0] death_phase, g_fright, lives;
wire dying_anim, pac_show, ghosts_show, fright_flash, show_ready, show_gameover, show_push, maze_white;
wire [31:0] g_x, g_y;
wire [7:0] g_dir;
wire [11:0] g_state, rgb;
wire [23:0] score, hiscore;
wire snd_dot, snd_power, snd_ghost, snd_death, snd_intro, fright_on;

pac_logic logic_(.clk(clk), .rst_n(rst_n), .tick(tick), .want_set(want_set), .want_dir(want_dir), .start(start),
	.invincible(invincible), .pause(1'b0), .rb_addr(rb_addr), .rb_q(rb_q),
	.pac_x(pac_x), .pac_y(pac_y), .pac_dir(pac_dir), .pac_mouth(pac_mouth), .death_phase(death_phase),
	.dying_anim(dying_anim), .pac_show(pac_show), .g_x(g_x), .g_y(g_y), .g_dir(g_dir), .g_state(g_state),
	.g_fright(g_fright), .ghosts_show(ghosts_show), .fright_flash(fright_flash), .score(score), .hiscore(hiscore),
	.lives(lives), .level_bcd(level_bcd), .show_ready(show_ready), .show_gameover(show_gameover),
	.show_push(show_push), .maze_white(maze_white), .frame(frame),
	.snd_dot(snd_dot), .snd_power(snd_power), .snd_ghost(snd_ghost), .snd_death(snd_death), .snd_intro(snd_intro),
	.fright_on(fright_on));

pac_draw #(.WALLS("../assets/walls.bin")) draw(.clk(clk), .pxl_x(pxl_x), .pxl_y(pxl_y), .rb_addr(rb_addr), .rb_q(rb_q),
	.pac_x(pac_x), .pac_y(pac_y), .pac_dir(pac_dir), .pac_mouth(pac_mouth), .death_phase(death_phase),
	.dying_anim(dying_anim), .pac_show(pac_show), .g_x(g_x), .g_y(g_y), .g_dir(g_dir), .g_state(g_state),
	.g_fright(g_fright), .ghosts_show(ghosts_show), .fright_flash(fright_flash), .score(score), .hiscore(hiscore),
	.lives(lives), .level_bcd(level_bcd), .show_ready(show_ready), .show_gameover(show_gameover),
	.show_push(show_push), .maze_white(maze_white), .frame(frame), .rgb(rgb));

integer errors = 0;
task automatic check(input cond, input [8*64-1:0] what);
	if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
	else $display("ok:   %0s", what);
endtask

// one game frame: a tick, then enough clocks for the logic to finish
task automatic frames(input integer n);
	repeat (n) begin
		@(negedge clk) tick = 1;
		@(negedge clk) tick = 0;
		repeat (600) @(negedge clk);
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
		$display("wrote %0s", name);
	end
endtask

function automatic [2:0] gst(input integer g);
	gst = g_state[3*g-3 +: 3];
endfunction

integer i, t, left_house, stuck;
logic [23:0] s0;
logic [7:0] last_x, last_y;
logic [3:0] lives0;

initial begin
	repeat (5) @(negedge clk);
	rst_n = 1;
	repeat (1100) @(negedge clk);			// the dot fill
	frames(2);
	check(show_push, "attract screen says PUSH START");
	render("attract.ppm");

	start = 1; frames(1); start = 0;
	repeat (1100) @(negedge clk);
	frames(5);
	check(show_ready, "Start -> READY!");
	render("ready.ppm");
	frames(260);
	check(!show_ready, "READY! ends, the game runs");
	s0 = score;
	frames(40);
	check(score > s0, "Pac-Man moves left and eats dots");
	check(pac_y == 8'd188 && pac_x < 8'd112, "he went left along row 23");
	render("play.ppm");

	// long game: steer at random, ghosts harmless; every ghost must leave the house and keep moving
	invincible = 1; left_house = 0; stuck = 0;
	for (t = 0; t < 3000; t = t + 1) begin
		if (t % 23 == 0) begin
			@(negedge clk) begin want_set = 1; want_dir = $urandom % 4; end
			@(negedge clk) want_set = 0;
		end
		if (t % 8 == 0) begin last_x = g_x[7:0]; last_y = g_y[7:0]; end
		frames(1);
		if (^{pac_x, pac_y, g_x, g_y, g_state, score} === 1'bx) begin
			errors = errors + 1; $display("FAIL: X in the game state at frame %0d", t); t = 99999;
		end
		// Blinky still on the same pixel after 8 frames of play = stuck (frightened ghosts move every other frame)
		if (t % 8 == 7 && g_x[7:0] == last_x && g_y[7:0] == last_y && logic_.gs == 4'd3) stuck = stuck + 1;
		for (i = 1; i <= 4; i = i + 1) if (gst(i) != 3'd0) left_house = left_house | (1 << i);
		if (t == 1500) render("mid.ppm");
	end
	check(left_house == 5'b11110, "all four ghosts left the house");
	check(stuck == 0, "Blinky never stops for 8 frames while the game runs");
	check(score > 24'h000500, "the self-steering game scored over 500");
	$display("score %h, high %h, lives %0d, level %h, Blinky (%0d,%0d)", score, hiscore, lives, level_bcd,
	         g_x[7:0], g_y[7:0]);

	// a ghost now kills: wait for a life to go
	invincible = 0; lives0 = lives;
	for (t = 0; t < 6000 && lives == lives0 && !show_gameover; t = t + 1) begin
		if (t % 23 == 0) begin
			@(negedge clk) begin want_set = 1; want_dir = $urandom % 4; end
			@(negedge clk) want_set = 0;
		end
		frames(1);
		if (dying_anim && death_phase == 4'd5) render("dying.ppm");
	end
	check(lives == lives0 - 1 || show_gameover, "a ghost catches Pac-Man and a life goes");

	if (errors == 0) $display("PASS"); else $display("FAIL: %0d checks", errors);
	$finish;
end

endmodule
