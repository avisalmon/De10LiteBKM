// Testbench for matvec_unit (lib/rtl/matvec_unit.sv): the stream fabric's int8 matrix-vector compute unit.
// The stream comes from a model of a show-ahead FIFO (random empty gaps = starvation), the results go to a model
// of a write lane (random wb_ready, long holds), the registers are driven like jtag_regs does. For every case the
// bench draws W (int8), x (T vectors of int8) and the group scales (int16), builds the model.q8.bin word stream
// (16 words of pairs, then the scale), computes every y with 64-bit integer math exactly as spec 7 says (sum of
// group sums times scales, arithmetic shift, saturate to int32) and compares bit for bit, in order.
// Cases: a small job at full rate; T = 8 with gaps and a slow lane; extreme values (saturation both ways) at
// SHIFT 0 and 20; K = 1024 (32 groups); K = 32 rows at T = 8 (the row's results take longer than the next row
// streams, so the stream must wait: CYCLES_STALLED > 0, nothing lost); the lane held for 400 clocks; abort and a
// restart from the fabric's start pulse; the broadcast address (writes land, reads return 0); ROWS = 0 ignores
// the global start and a direct start just sets done. Checks: every y, WORDS, ROWS_DONE, CYCLES_BUSY against the
// bench's clock count, STARVED / STALLED where they must or must not count, one flush exactly after the last
// result, wb_data held while the lane stalls, never a pop without data.
// python scripts/sim.py lib/sim/tb_matvec_unit.sv                   (about 0.3 ms of simulated time)
// sim-sources: lib/rtl/matvec_unit.sv
`timescale 1ns/1ps

module tb_matvec_unit;

localparam T_MAX = 8;
localparam [15:0] BASE = 16'h0120, BCAST = 16'h01F0;	// unit 2 of the map

reg				clk = 0;
always #5 clk = ~clk;
reg				rst_n = 0;
integer		cycles = 0;
always @(posedge clk) cycles <= cycles + 1;

// ---- the stream source: a show-ahead FIFO with random empty gaps ----
reg	[15:0]	stream [0:(1<<17)-1];
integer		sp = 0, slen = 0, gap_pct = 0;
reg				gap = 0;
wire				s_valid = (sp < slen) && !gap;
wire	[15:0]	s_data = stream[sp];
wire				s_rd_en;

// ---- the lane sink ----
reg				wb_ready = 1;
integer		ready_pct = 100, hold_low = 0;
wire	[31:0]	wb_data;
wire				wb_valid, wb_flush;
reg	[31:0]	got [0:(1<<15)-1];
integer		ngot = 0, nflush = 0, nexp = 0, flush_bad = 0;
reg	[31:0]	wb_q = 0;
reg				stalled_q = 0;

// ---- registers ----
reg	[15:0]	reg_addr = 0;
reg	[31:0]	reg_wdata = 0;
reg				reg_we = 0;
wire	[31:0]	reg_rdata;
reg	[3:0]		g_ctrl = 0;
wire				busy;
integer		errors = 0;

matvec_unit #(.T_MAX(T_MAX), .REG_BASE(BASE), .REG_BCAST(BCAST)) uut(
	.clk(clk), .rst_n(rst_n),
	.s_data(s_data), .s_valid(s_valid), .s_rd_en(s_rd_en),
	.wb_data(wb_data), .wb_valid(wb_valid), .wb_ready(wb_ready), .wb_flush(wb_flush),
	.g_ctrl(g_ctrl),
	.reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_we(reg_we), .reg_rdata(reg_rdata),
	.busy(busy));

always @(posedge clk) begin
	if (s_rd_en && !s_valid) begin
		errors = errors + 1;
		$display("  FAIL: pop while the FIFO shows nothing at %0t", $time);
	end
	if (s_rd_en) sp <= sp + 1;
	gap <= (($urandom % 100) < gap_pct);
	if (hold_low > 0) begin
		wb_ready <= 1'b0;
		hold_low <= hold_low - 1;
	end else wb_ready <= (($urandom % 100) < ready_pct);
	if (wb_valid && wb_ready) begin
		got[ngot] <= wb_data;
		ngot <= ngot + 1;
	end
	if (wb_flush) begin
		nflush <= nflush + 1;
		if (ngot != nexp) flush_bad = flush_bad + 1;
	end
	stalled_q <= wb_valid && !wb_ready;
	wb_q <= wb_data;
	if (stalled_q && wb_valid && (wb_data !== wb_q)) begin
		errors = errors + 1;
		$display("  FAIL: wb_data changed while the lane stalled at %0t", $time);
	end
end

// ---- the register bus, as jtag_regs drives it ----
task reg_write(input [15:0] a, input [31:0] d);
	begin
		@(negedge clk);
		reg_addr = a;
		reg_wdata = d;
		reg_we = 1;
		@(negedge clk);
		reg_we = 0;
	end
endtask

task reg_read(input [15:0] a, output [31:0] d);
	begin
		@(negedge clk);
		reg_addr = a;
		@(negedge clk);
		@(negedge clk);
		d = reg_rdata;
	end
endtask

task pulse(input [3:0] p);
	begin
		@(negedge clk);
		g_ctrl = p;
		@(negedge clk);
		g_ctrl = 0;
	end
endtask

task check(input [8*48-1:0] what, input [31:0] got_v, input [31:0] exp_v);
	begin
		if (got_v !== exp_v) begin
			errors = errors + 1;
			$display("  FAIL: %0s = %0d (0x%08x), expected %0d (0x%08x)", what, got_v, got_v, exp_v, exp_v);
		end
	end
endtask

task check_range(input [8*48-1:0] what, input integer got_v, input integer lo, input integer hi);
	begin
		if (got_v < lo || got_v > hi) begin
			errors = errors + 1;
			$display("  FAIL: %0s = %0d, expected %0d..%0d", what, got_v, lo, hi);
		end
	end
endtask

// ---- the reference ----
integer		ROWS, K, T, SHIFT, G;
reg signed [7:0]	W [0:15][0:1023];
reg signed [7:0]	X [0:T_MAX-1][0:1023];
reg signed [15:0]	S [0:15][0:31];
reg	[31:0]	expct [0:(1<<15)-1];
integer		nsat;

task build_case(input integer rows, input integer k, input integer tt, input integer shift, input integer extreme);
	integer	i, g, j, kk, t;
	longint	acc, gs;
	begin
		ROWS = rows; K = k; T = tt; SHIFT = shift; G = K / 32;
		for (i = 0; i < ROWS; i = i + 1)
			for (kk = 0; kk < K; kk = kk + 1)
				W[i][kk] = extreme ? ((($urandom % 2) == 0) ? 8'sd127 : -8'sd127) : $random;
		for (t = 0; t < T; t = t + 1)
			for (kk = 0; kk < K; kk = kk + 1)
				X[t][kk] = extreme ? ((($urandom % 2) == 0) ? 8'sd127 : -8'sd128) : $random;
		for (i = 0; i < ROWS; i = i + 1)
			for (g = 0; g < G; g = g + 1)
				S[i][g] = extreme ? ((($urandom % 2) == 0) ? 16'sd32767 : -16'sd32768) : $random;
		slen = 0;
		for (i = 0; i < ROWS; i = i + 1)
			for (g = 0; g < G; g = g + 1) begin
				for (j = 0; j < 16; j = j + 1) begin
					stream[slen] = {W[i][32*g + 2*j + 1], W[i][32*g + 2*j]};
					slen = slen + 1;
				end
				stream[slen] = S[i][g];
				slen = slen + 1;
			end
		nexp = 0;
		nsat = 0;
		for (i = 0; i < ROWS; i = i + 1)
			for (t = 0; t < T; t = t + 1) begin
				acc = 0;
				for (g = 0; g < G; g = g + 1) begin
					gs = 0;
					for (j = 0; j < 32; j = j + 1) gs = gs + W[i][32*g + j] * X[t][32*g + j];
					acc = acc + gs * S[i][g];
				end
				acc = acc >>> SHIFT;
				if (acc > 64'sd2147483647) begin acc = 64'sd2147483647; nsat = nsat + 1; end
				else if (acc < -64'sd2147483648) begin acc = -64'sd2147483648; nsat = nsat + 1; end
				expct[nexp] = acc[31:0];
				nexp = nexp + 1;
			end
	end
endtask

task write_x;
	integer	t, kk;
	reg	[31:0]	d;
	begin
		for (t = 0; t < T; t = t + 1) begin
			reg_write(BASE + 16'd8, t << 12);
			for (kk = 0; kk < K; kk = kk + 4)
				reg_write(BASE + 16'd9, {X[t][kk+3], X[t][kk+2], X[t][kk+1], X[t][kk]});
			reg_read(BASE + 16'd8, d);
			check("XADDR after a vector", d, (t << 12) + K);
		end
	end
endtask

task configure(input [15:0] at);
	begin
		reg_write(at + 16'd0, ROWS);
		reg_write(at + 16'd1, K);
		reg_write(at + 16'd2, T);
		reg_write(at + 16'd3, SHIFT);
	end
endtask

task wait_done(input integer limit);
	integer	n;
	begin
		n = 0;
		while (!busy && n < 20) begin @(negedge clk); n = n + 1; end
		if (!busy) begin errors = errors + 1; $display("  FAIL: the unit never got busy"); end
		n = 0;
		while (busy && n < limit) begin @(negedge clk); n = n + 1; end
		if (busy) begin errors = errors + 1; $display("  FAIL: still busy after %0d clocks", limit); end
		repeat (3) @(negedge clk);									// the flush pulse follows the last push by a clock
	end
endtask

task compare_results;
	integer	i;
	begin
		check("results pushed", ngot, nexp);
		for (i = 0; i < nexp && i < ngot; i = i + 1)
			if (got[i] !== expct[i]) begin
				errors = errors + 1;
				if (errors < 12) $display("  FAIL: y[%0d] (row %0d, t %0d) = 0x%08x, expected 0x%08x",
					i, i / T, i % T, got[i], expct[i]);
			end
		check("flush pulses", nflush, 1);
		check("flushes before the last result", flush_bad, 0);
		check("stream words consumed", sp, slen);
	end
endtask

// run one job through the unit's own CTRL and check everything about it
task run_case(input [8*48-1:0] name, input integer rows, input integer k, input integer tt, input integer shift,
              input integer extreme, input integer gaps, input integer rdy, input integer hold_after,
              input integer want_starve, input integer want_stall);
	integer	t0, t1, e0;
	reg	[31:0]	d;
	begin
		e0 = errors;
		$display("[%0s] ROWS %0d K %0d T %0d SHIFT %0d, extreme %0d, gaps %0d%%, ready %0d%%, hold after %0d",
			name, rows, k, tt, shift, extreme, gaps, rdy, hold_after);
		build_case(rows, k, tt, shift, extreme);
		gap_pct = gaps;
		ready_pct = rdy;
		sp = 0; ngot = 0; nflush = 0; flush_bad = 0;
		write_x;
		configure(BASE);
		reg_write(BASE + 16'd4, 32'h4);							// clear the counters
		t0 = cycles;
		reg_write(BASE + 16'd4, 32'h1);							// start
		if (hold_after >= 0) begin
			while (ngot < hold_after) @(negedge clk);
			hold_low = 400;
		end
		wait_done(400000);
		t1 = cycles;
		compare_results;
		reg_read(BASE + 16'd5, d);
		check("STAT busy/done", d[1:0], 2'b10);
		check("STAT T_MAX", d[15:8], T_MAX);
		if (hold_after >= 0) check("STAT lane stalled", d[2], 1);
		reg_read(BASE + 16'd10, d);
		check("ROWS_DONE", d, rows);
		reg_read(BASE + 16'd12, d);
		check("WORDS", d, slen);
		reg_read(BASE + 16'd6, d);
		check_range("CYCLES_BUSY", d, t1 - t0 - 8, t1 - t0);
		reg_read(BASE + 16'd7, d);
		if (want_starve) check_range("CYCLES_STARVED", d, 1, 1 << 30);
		else check("CYCLES_STARVED", d, 0);
		reg_read(BASE + 16'd11, d);
		if (want_stall) check_range("CYCLES_STALLED", d, 1, 1 << 30);
		else check("CYCLES_STALLED", d, 0);
		$display("  %0d words, %0d results (%0d saturated) in %0d clocks: %0s",
			slen, ngot, nsat, t1 - t0, (errors == e0) ? "ok" : "FAIL");
	end
endtask

reg	[31:0]	d;
integer	n;

initial begin
	repeat (3) @(negedge clk);
	rst_n = 1;
	repeat (2) @(negedge clk);

	run_case("A basic", 3, 64, 1, 0, 0, 0, 100, -1, 0, 0);
	run_case("B T=8 gaps slow lane", 5, 192, 8, 10, 0, 50, 70, -1, 1, 0);
	run_case("C saturation", 4, 288, 3, 0, 1, 0, 100, -1, 0, 0);
	if (nsat == 0) begin errors = errors + 1; $display("  FAIL: case C saturated nothing"); end
	run_case("D extreme shifted", 4, 288, 3, 20, 1, 0, 100, -1, 0, 0);
	run_case("E K=1024", 2, 1024, 8, 20, 0, 30, 100, -1, 1, 0);
	run_case("F short rows T=8", 6, 32, 8, 4, 0, 0, 100, -1, 0, 1);
	run_case("G lane held", 6, 64, 2, 0, 0, 0, 100, 1, 0, 1);

	// ---- H: abort, then a restart from the fabric's start pulse ----
	$display("[H] abort and restart");
	build_case(8, 1024, 8, 12, 0);
	gap_pct = 0; ready_pct = 100;
	sp = 0; ngot = 0; nflush = 0; flush_bad = 0;
	write_x;
	configure(BASE);
	reg_write(BASE + 16'd4, 32'h1);
	repeat (600) @(negedge clk);
	if (!busy) begin errors = errors + 1; $display("  FAIL: not busy before the abort"); end
	reg_write(BASE + 16'd4, 32'h2);								// abort
	repeat (4) @(negedge clk);
	check("busy after abort", busy, 0);
	reg_read(BASE + 16'd5, d);
	check("STAT after abort (aborted, not done)", d[3:0], 4'b1000);
	repeat (20) @(negedge clk);
	sp = 0; ngot = 0; nflush = 0; flush_bad = 0;				// the fabric would soft-reset the FIFOs here
	pulse(4'b1000);													// clear the counters
	n = cycles;
	pulse(4'b0010);													// the global start
	wait_done(400000);
	compare_results;
	reg_read(BASE + 16'd5, d);
	check("STAT after the restart", d[3:0], 4'b0010);
	reg_read(BASE + 16'd10, d);
	check("ROWS_DONE", d, 8);
	reg_read(BASE + 16'd12, d);
	check("WORDS", d, slen);
	$display("  %0d results after the restart: %0s", ngot, (ngot == nexp) ? "ok" : "FAIL");

	// ---- I: the broadcast address ----
	$display("[I] broadcast writes, quiet reads");
	reg_write(BCAST + 16'd0, 32'd77);
	reg_write(BCAST + 16'd1, 32'd320);
	reg_write(BCAST + 16'd2, 32'd5);
	reg_write(BCAST + 16'd3, 32'd33);
	reg_read(BASE + 16'd0, d); check("ROWS via broadcast", d, 77);
	reg_read(BASE + 16'd1, d); check("K via broadcast", d, 320);
	reg_read(BASE + 16'd2, d); check("T via broadcast", d, 5);
	reg_read(BASE + 16'd3, d); check("SHIFT via broadcast", d, 33);
	reg_read(BCAST + 16'd0, d); check("a broadcast read", d, 0);
	reg_read(16'h0130, d); check("another unit's address", d, 0);

	// ---- J: ROWS = 0 ----
	$display("[J] ROWS = 0: the global start is ignored, a direct start sets done");
	reg_write(BASE + 16'd0, 32'd0);
	pulse(4'b0010);
	repeat (5) @(negedge clk);
	check("busy after a global start with ROWS = 0", busy, 0);
	reg_write(BASE + 16'd4, 32'h1);
	repeat (3) @(negedge clk);
	reg_read(BASE + 16'd5, d);
	check("STAT after a direct start with ROWS = 0 (done, idle)", d[1:0], 2'b10);
	check("busy", busy, 0);

	if (errors == 0) $display("PASS: matvec_unit");
	else $display("FAIL: matvec_unit, %0d errors", errors);
	$finish;
end

initial begin
	#20_000_000;
	$display("FAIL: watchdog");
	$finish;
end

endmodule
