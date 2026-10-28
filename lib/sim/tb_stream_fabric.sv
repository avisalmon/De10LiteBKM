// Testbench for stream_fabric (lib/rtl/stream_fabric.sv) with the burst controller and the SDRAM model at 100 MHz.
// The units' clock uclk is 13 ns by default (any ratio: the FIFOs cross it); -D UCLK_NS=10 makes it one clock.
// The model's memory starts filled with a pattern of the address (written into the model directly); the channels
// read banks 0-1, the lanes write bank 2, the legacy port bank 3; a reference memory follows every write.
// Phases:
//  A  one channel, BURST 64, greedy consumer: every word, FETCHED, the level back to 0, the done flag.
//  B  everything at once: N channels over random regions with BURST from {1, 7, 64, 100, 256, 0 = 1024} and
//     consumers at random rates; N lanes pushing random results at random rates, half flushed by the unit's pulse,
//     half by the host; the legacy port writing then reading single words with random gaps, its wait measured.
//     Checks every channel word, the lanes' words in the model's memory, pointers, counters, the legacy data and its
//     worst wait (at most the burst in progress plus a refresh), no fault, no overflow, no underrun, no model error.
//  C  throughput: N channels, BURST 256, equal LEN, greedy consumers: words per clock, fairness of the finish times,
//     the BURSTS counter.
//  D  loop mode (the pattern across the wrap), abort (a clean finish with the done flag), soft reset (level 0, the
//     unit_ctrl pulse), then a channel re-reads what a lane wrote.
// python scripts/sim.py lib/sim/tb_stream_fabric.sv               (about 3 ms of simulated time)
// python scripts/sim.py lib/sim/tb_stream_fabric.sv -D N_CH=1     (also 2, 3, 14; -D FAST_REFRESH; -D UCLK_NS=10)
// sim-sources: lib/rtl/stream_fabric.sv lib/rtl/async_fifo.sv lib/rtl/sdram_burst_ctrl.sv lib/sim/sdram_model.sv
`timescale 1ns/1ps

module tb_stream_fabric;

`ifdef N_CH
localparam N = `N_CH;
`else
localparam N = 6;
`endif
localparam ROW_BITS = 6;
localparam WORDS = 4 << (ROW_BITS + 10);				// 256K words: 4 banks x 64 rows x 1024 columns
localparam BANK = 1 << (ROW_BITS + 10);				// 64K words per bank in the aliased index space
localparam DEPTH = 1024, LANE_DEPTH = 64;
localparam MAXE = 2048;										// entries a lane job pushes at most
`ifdef FAST_REFRESH
localparam REFRESH_CLOCKS = 97;
`else
localparam REFRESH_CLOCKS = 750;
`endif
`ifdef UCLK_NS
localparam real UCLK_NS = `UCLK_NS;
`else
localparam real UCLK_NS = 13.0;
`endif
localparam real P_NS = 1.25;								// DRAM_CLK phase behind clk (never 0: a race in simulation)
localparam real REF_FRAC = 12.0 / REFRESH_CLOCKS;		// the bus share a refresh takes (about 12 clocks each)
// the legacy port's bound: one burst in progress (1024 words + 5) plus every refresh that came due during it
localparam LG_BOUND = 1029 + (1029 / REFRESH_CLOCKS + 1) * 14 + 30;
localparam SLOTS = (N + 1) / 2;							// read regions per bank (channels alternate banks 0 and 1)
localparam C_SLOT = BANK / SLOTS;
localparam L_SLOT = BANK / N;								// lane regions, all in bank 2

reg				clk = 0;
always #5 clk = ~clk;
reg				uclk = 0;
always #(UCLK_NS / 2) uclk = ~uclk;
reg				dram_clk = 0;
always @(clk) dram_clk <= #(P_NS) clk;
reg				rst_n = 0, urst_n = 0;
integer			cycles = 0;
always @(posedge clk) cycles = cycles + 1;

// ---- the design: fabric + controller + model ----
wire				cmd_valid, cmd_ready, cmd_we, wvalid, wready, rvalid, done, init_done, stat_busy, stat_refresh;
wire	[24:0]	cmd_addr;
wire	[10:0]	cmd_len;
wire	[15:0]	wdata, rdata;
wire	[2:0]		rd_delay;
reg				lg_req = 0, lg_we = 0;
reg	[24:0]	lg_addr = 0;
reg	[15:0]	lg_wdata = 0;
wire				lg_ready, lg_rvalid;
wire	[15:0]	lg_rdata;
wire	[N*16-1:0]	ch_dout;
wire	[N-1:0]		ch_valid;
reg	[N-1:0]		ch_rd_en = 0;
reg	[N*32-1:0]	wb_data = 0;
reg	[N-1:0]		wb_valid = 0, wb_flush = 0;
wire	[N-1:0]		wb_ready;
reg	[15:0]	reg_addr = 0;
reg	[31:0]	reg_wdata = 0;
reg				reg_we = 0;
wire	[31:0]	reg_rdata;
wire	[3:0]		unit_ctrl;
wire				any_running, lanes_busy, legacy_busy, idle, fault;
wire	[12:0]	A;
wire	[1:0]		BA;
wire				cas_n, cke, cs_n, ras_n, we_n, ldqm, udqm;
wire	[15:0]	DQ;
integer			model_errors;

stream_fabric #(.N(N), .DEPTH(DEPTH), .LANE_DEPTH(LANE_DEPTH)) uut(
	.clk(clk), .rst_n(rst_n), .uclk(uclk), .urst_n(urst_n),
	.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
	.wdata(wdata), .wvalid(wvalid), .wready(wready), .rdata(rdata), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh), .rd_delay(rd_delay),
	.lg_req(lg_req), .lg_we(lg_we), .lg_addr(lg_addr), .lg_wdata(lg_wdata), .lg_ready(lg_ready),
	.lg_rvalid(lg_rvalid), .lg_rdata(lg_rdata),
	.ch_dout(ch_dout), .ch_valid(ch_valid), .ch_rd_en(ch_rd_en),
	.wb_data(wb_data), .wb_valid(wb_valid), .wb_ready(wb_ready), .wb_flush(wb_flush),
	.reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_we(reg_we), .reg_rdata(reg_rdata),
	.unit_ctrl(unit_ctrl), .any_running(any_running), .lanes_busy(lanes_busy), .legacy_busy(legacy_busy),
	.idle(idle), .fault(fault));
sdram_burst_ctrl #(.CLK_MHZ(100), .REFRESH_CLOCKS(REFRESH_CLOCKS)) ctl(.clk(clk), .rst_n(rst_n), .rd_delay(rd_delay),
	.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
	.wdata(wdata), .wvalid(wvalid), .wready(wready), .rdata(rdata), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh),
	.DRAM_ADDR(A), .DRAM_BA(BA), .DRAM_CAS_N(cas_n), .DRAM_CKE(cke), .DRAM_CS_N(cs_n), .DRAM_DQ(DQ),
	.DRAM_LDQM(ldqm), .DRAM_RAS_N(ras_n), .DRAM_UDQM(udqm), .DRAM_WE_N(we_n));
sdram_model #(.ROW_BITS(ROW_BITS)) mem(.dram_clk(dram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
	.we_n(we_n), .ba(BA), .a(A), .dq(DQ), .errors(model_errors));

// ---- the reference memory, in the model's aliased index space {bank, row[5:0], col} ----
reg	[15:0]	ref_mem [0:WORDS-1];
function [15:0] pattern(input [24:0] a);
	pattern = (a[15:0] * 16'h9E37) ^ {a[24:16], 7'd0} ^ 16'h3C5A;
endfunction
function [24:0] real_addr(input [17:0] idx);		// an index to the address the design sees (rows 0..63 only)
	real_addr = {idx[17:16], 7'd0, idx[15:0]};
endfunction
integer i;
initial for (i = 0; i < WORDS; i = i + 1) begin
	mem.mem[i] = pattern(real_addr(i));
	ref_mem[i] = pattern(real_addr(i));
end

// ---- the register bus ----
localparam [15:0] A_CTRL = 16'h001, A_RDDEL = 16'h003, A_BUSY = 16'h004, A_TOTAL = 16'h005, A_REFR = 16'h006,
                  A_BURSTS = 16'h007;
localparam R_BASE = 0, R_LEN = 1, R_BURST = 2, R_CTRL = 3, R_STAT = 4, R_FETCHED = 5, R_WAITED = 6;
localparam W_BASE = 0, W_CTRL = 1, W_STAT = 2;
function [15:0] CH(input integer c, input integer r);
	CH = 16'h010 + c * 8 + r;
endfunction
function [15:0] LN(input integer u, input integer r);
	LN = 16'h080 + u * 4 + r;
endfunction
task reg_write(input [15:0] a, input [31:0] d);
	begin
		@(negedge clk);
		reg_addr = a; reg_wdata = d; reg_we = 1;
		@(negedge clk);
		reg_we = 0;
	end
endtask
task reg_read(input [15:0] a, output [31:0] d);
	begin
		@(negedge clk);
		reg_addr = a; reg_we = 0;
		@(negedge clk);
		@(negedge clk);											// registered once; jtag_regs samples 2 clocks after addr
		d = reg_rdata;
	end
endtask

integer			errors = 0;
task fail(input [8*96-1:0] msg);
	begin
		$display("%0t FAIL: %0s", $time, msg);
		errors = errors + 1;
	end
endtask
task check(input cond, input [8*96-1:0] msg);
	if (!cond) fail(msg);
endtask

// ---- channel consumers (uclk): pop at a rate, compare every word with the reference ----
reg	[17:0]	c_base [0:N-1];
integer			c_len [0:N-1];
integer			c_burst [0:N-1];
integer			c_cnt [0:N-1];
integer			c_rate [0:N-1];								// pops per 16 uclk at most; 16 = greedy
integer			c_err [0:N-1];
reg				c_on [0:N-1];
integer			c_fin [0:N-1];									// the clock the channel stopped running
genvar g;
generate for (g = 0; g < N; g = g + 1) begin : cons
	always @(negedge uclk) ch_rd_en[g] = c_on[g] && (($urandom % 16) < c_rate[g]);
	always @(posedge uclk) if (ch_valid[g] && ch_rd_en[g]) begin
		if (ch_dout[g*16 +: 16] !== ref_mem[c_base[g] + (c_cnt[g] % c_len[g])]) begin
			c_err[g] = c_err[g] + 1;
			if (c_err[g] <= 5) $display("%0t FAIL: ch%0d word %0d: got %h want %h", $time, g, c_cnt[g],
				ch_dout[g*16 +: 16], ref_mem[c_base[g] + (c_cnt[g] % c_len[g])]);
		end
		c_cnt[g] = c_cnt[g] + 1;
	end
	always @(negedge uut.ch_running[g]) c_fin[g] = cycles;
end endgenerate

// ---- lane producers (uclk): push random results at a rate, then flush (the unit's pulse or the host) ----
reg	[31:0]	l_exp [0:N*MAXE-1];
reg	[17:0]	l_base [0:N-1];
integer			l_todo [0:N-1], l_pushed [0:N-1], l_rate [0:N-1], l_gap [0:N-1], l_wb [0:N-1];
reg				l_on [0:N-1], l_unit_flush [0:N-1], l_done [0:N-1];
generate for (g = 0; g < N; g = g + 1) begin : prod
	integer after_last = 0;
	always @(negedge uclk) begin
		wb_flush[g] = 0;
		if (l_on[g] && l_pushed[g] < l_todo[g] && (($urandom % 16) < l_rate[g])) begin
			wb_valid[g] = 1;
			wb_data[g*32 +: 32] = l_exp[g*MAXE + l_pushed[g]];
		end
		else begin
			wb_valid[g] = 0;
			wb_data[g*32 +: 32] = 32'hxxxx_xxxx;
		end
		if (l_on[g] && l_pushed[g] == l_todo[g] && !l_done[g]) begin
			after_last = after_last + 1;
			if (after_last == l_gap[g]) begin
				wb_flush[g] = l_unit_flush[g];
				l_done[g] = 1;
			end
		end
		if (!l_on[g]) after_last = 0;
	end
	always @(posedge uclk) if (wb_valid[g] && wb_ready[g]) l_pushed[g] = l_pushed[g] + 1;
end endgenerate

// ---- the legacy master (clk): like the loader, one word at a time, write then read it back ----
reg				lg_on = 0;
integer			lg_state = 0, lg_count = 0, lg_err = 0, lg_max_wait = 0, lg_wait = 0, lg_gap = 0;
reg	[17:0]	lg_idx = 0;
reg	[15:0]	lg_val = 0;
always @(negedge clk) begin
	lg_req = 0;
	case (lg_state)
	0: if (lg_on) begin
			if (lg_gap > 0) lg_gap = lg_gap - 1;
			else if (lg_ready) begin
				lg_idx = 18'h30000 + ($urandom % 18'h10000);
				lg_val = $urandom;
				lg_req = 1; lg_we = 1; lg_addr = real_addr(lg_idx); lg_wdata = lg_val;
				lg_wait = 0;
				lg_state = 1;
			end
		end
	1: begin
			lg_wait = lg_wait + 1;
			if (lg_ready) begin
				ref_mem[lg_idx] = lg_val;
				if (lg_wait > lg_max_wait) lg_max_wait = lg_wait;
				lg_state = 2;
			end
		end
	2: if (lg_ready) begin
			lg_req = 1; lg_we = 0; lg_addr = real_addr(lg_idx);
			lg_wait = 0;
			lg_state = 3;
		end
	3: begin
			lg_wait = lg_wait + 1;
			if (lg_rvalid) begin
				if (lg_rdata !== lg_val) begin
					lg_err = lg_err + 1;
					if (lg_err <= 5) $display("%0t FAIL: legacy read %h: got %h want %h", $time, lg_addr, lg_rdata, lg_val);
				end
				if (lg_wait > lg_max_wait) lg_max_wait = lg_wait;
				lg_count = lg_count + 1;
				lg_gap = $urandom % 300;
				lg_state = 0;
			end
		end
	endcase
end

// ---- monitors ----
reg	[3:0]		uc_seen = 0;
always @(posedge clk) uc_seen = uc_seen | unit_ctrl;
reg				fault_seen = 0;
always @(posedge clk) if (fault) fault_seen = 1;

// ---- helpers for the sequence ----
reg	[31:0]	d, d2;
integer			c, u, k, t0, t1, tmin, tmax, total;
integer			bursts_expected;
real				util, thr_util;

task setup_channel(input integer ch, input [17:0] base, input integer len, input integer burst, input integer rate,
                   input loop);
	begin
		c_base[ch] = base; c_len[ch] = len; c_cnt[ch] = 0; c_rate[ch] = rate; c_err[ch] = 0; c_on[ch] = 1;
		c_fin[ch] = 0; c_burst[ch] = burst;
		reg_write(CH(ch, R_BASE), real_addr(base));
		reg_write(CH(ch, R_LEN), len);
		reg_write(CH(ch, R_BURST), burst);
		reg_write(CH(ch, R_CTRL), {30'd0, loop, 1'b1});			// enabled; CTRL bit 1 starts all enabled channels
	end
endtask

task wait_channel_done(input integer ch);
	integer t;
	begin
		t = 0; d = 0;
		while (!d[17] && t < 400000) begin
			reg_read(CH(ch, R_STAT), d);
			t = t + 1;
		end
		if (!d[17]) fail("channel did not finish");
	end
endtask

task wait_consumed(input integer ch);
	integer t;
	begin
		t = 0;
		while (c_cnt[ch] < c_len[ch] && t < 4000000) begin
			@(negedge uclk);
			t = t + 1;
		end
		if (c_cnt[ch] < c_len[ch]) fail("consumer did not get every word");
	end
endtask

task check_channel(input integer ch);
	begin
		wait_consumed(ch);
		repeat (8) @(negedge clk);									// STAT's level is the writer's view: 3 clocks behind a pop
		check(c_err[ch] == 0, "channel data errors");
		check(c_cnt[ch] == c_len[ch], "channel word count");
		reg_read(CH(ch, R_STAT), d);
		check(d[10:0] == 0, "channel level not 0 after draining");
		check(d[16] == 0, "channel still running");
		check(d[17] == 1, "channel done flag not set");
		check(d[18] == 0, "channel FIFO overflow");
		reg_read(CH(ch, R_FETCHED), d);
		check(d == c_len[ch], "FETCHED != LEN");
	end
endtask

function integer pick_burst(input integer r);
	case (r % 6)
		0: pick_burst = 1;
		1: pick_burst = 7;
		2: pick_burst = 64;
		3: pick_burst = 100;
		4: pick_burst = 256;
		default: pick_burst = 0;								// 0 = 1024
	endcase
endfunction
function integer pick_rate(input integer r);
	case (r % 5)
		0, 1: pick_rate = 16;
		2: pick_rate = 8;
		3: pick_rate = 4;
		default: pick_rate = 2;
	endcase
endfunction
function integer pick_wburst(input integer r);
	case (r % 5)
		0: pick_wburst = 2;
		1: pick_wburst = 7;
		2: pick_wburst = 8;
		3: pick_wburst = 64;
		default: pick_wburst = 128;
	endcase
endfunction
function integer imin(input integer a, input integer b);
	imin = (a < b) ? a : b;
endfunction

initial begin : main
	for (k = 0; k < N; k = k + 1) begin
		c_on[k] = 0; c_len[k] = 1; c_cnt[k] = 0; c_rate[k] = 0; c_err[k] = 0; c_base[k] = 0; c_fin[k] = 0;
		l_on[k] = 0; l_todo[k] = 0; l_pushed[k] = 0; l_done[k] = 0; l_rate[k] = 0; l_gap[k] = 1; l_wb[k] = 0;
		l_unit_flush[k] = 0; l_base[k] = 0;
	end
	repeat (5) @(negedge clk);
	rst_n = 1;
	repeat (4) @(negedge uclk);
	urst_n = 1;
	wait (init_done);
	$display("%0t init done (N = %0d, uclk %0.1f ns)", $time, N, UCLK_NS);
	reg_read(A_RDDEL, d);
	check(d == uut.RD_DELAY_DEFAULT, "RD_DELAY default");
	// the board needs 4 (the pad and input register add a clock); the model with DRAM_CLK 1.25 ns behind needs 3
	reg_write(A_RDDEL, 3);

	// ---------------- phase A: one channel ----------------
	$display("%0t phase A: one channel, BURST 64, 1000 words", $time);
	setup_channel(0, 18'h00100, 1000, 64, 16, 0);
	reg_write(CH(0, R_CTRL), 32'h5);								// enabled + start this channel
	wait_channel_done(0);
	check_channel(0);
	c_on[0] = 0;
	$display("%0t phase A done: %0d errors so far", $time, errors);

	// ---------------- phase B: everything at once ----------------
	$display("%0t phase B: %0d channels, %0d lanes, the legacy port, random everything", $time, N, N);
	for (c = 0; c < N; c = c + 1) begin
		setup_channel(c, (c % 2) * BANK + (c / 2) * C_SLOT + ($urandom % 256),
			1 + ($urandom % imin(C_SLOT - 512, 8192)), pick_burst($urandom), pick_rate($urandom), 0);
		$display("   ch%0d: base %h len %0d burst %0d rate %0d/16", c, c_base[c], c_len[c], c_burst[c], c_rate[c]);
	end
	for (u = 0; u < N; u = u + 1) begin
		l_base[u] = 2 * BANK + u * L_SLOT + ($urandom % 64);
		l_todo[u] = 1 + ($urandom % imin((L_SLOT - 128) / 2, 1792));
		for (k = 0; k < l_todo[u]; k = k + 1) l_exp[u*MAXE + k] = $urandom;
		l_pushed[u] = 0; l_done[u] = 0; l_rate[u] = pick_rate($urandom); l_gap[u] = 1 + ($urandom % 5);
		l_unit_flush[u] = (u % 2 == 0); l_wb[u] = pick_wburst($urandom);
		reg_write(LN(u, W_BASE), real_addr(l_base[u]));
		reg_write(LN(u, W_CTRL), l_wb[u] | (1 << 17));			// WBURST, clear words / underrun
		$display("   lane%0d: base %h entries %0d wburst %0d rate %0d/16 flush by %0s", u, l_base[u], l_todo[u],
			l_wb[u], l_rate[u], l_unit_flush[u] ? "unit" : "host");
	end
	reg_write(A_CTRL, 32'h8);											// clear counters
	lg_on = 1;
	reg_write(A_CTRL, 32'h2);											// start all enabled channels
	for (u = 0; u < N; u = u + 1) l_on[u] = 1;
	// wait for the producers, flush the host-flushed lanes, then for everything to settle
	for (u = 0; u < N; u = u + 1) begin
		k = 0;
		while (!l_done[u] && k < 4000000) begin @(negedge uclk); k = k + 1; end
		if (!l_done[u]) fail("lane producer did not finish");
	end
	for (u = 0; u < N; u = u + 1) if (!l_unit_flush[u]) reg_write(LN(u, W_CTRL), l_wb[u] | (1 << 16));
	for (c = 0; c < N; c = c + 1) wait_channel_done(c);
	k = 0;
	while (lanes_busy && k < 400000) begin @(negedge clk); k = k + 1; end
	check(!lanes_busy, "lanes still busy after flush");
	lg_on = 0;
	k = 0;
	while (lg_state != 0 && k < 10000) begin @(negedge clk); k = k + 1; end
	for (c = 0; c < N; c = c + 1) begin
		check_channel(c);
		reg_read(CH(c, R_WAITED), d);
		$display("   ch%0d: %0d words ok, waited %0d clocks", c, c_cnt[c], d);
		c_on[c] = 0;
	end
	for (u = 0; u < N; u = u + 1) begin
		reg_read(LN(u, W_BASE), d);
		check(d == real_addr(l_base[u]) + 2 * l_todo[u], "lane pointer");
		reg_read(LN(u, W_STAT), d);
		check(d[6:0] == 0, "lane level not 0");
		check(d[7] == 0, "lane underrun");
		check(d[31:8] == 2 * l_todo[u], "lane words count");
		k = 0;
		for (i = 0; i < l_todo[u]; i = i + 1) begin
			if (mem.mem[l_base[u] + 2*i] !== l_exp[u*MAXE + i][15:0] ||
			    mem.mem[l_base[u] + 2*i + 1] !== l_exp[u*MAXE + i][31:16]) begin
				k = k + 1;
				if (k <= 3) $display("%0t FAIL: lane%0d entry %0d: memory %h %h want %h", $time, u, i,
					mem.mem[l_base[u] + 2*i + 1], mem.mem[l_base[u] + 2*i], l_exp[u*MAXE + i]);
			end
			ref_mem[l_base[u] + 2*i] = l_exp[u*MAXE + i][15:0];
			ref_mem[l_base[u] + 2*i + 1] = l_exp[u*MAXE + i][31:16];
		end
		check(k == 0, "lane data in memory");
		$display("   lane%0d: %0d entries ok", u, l_todo[u]);
		l_on[u] = 0;
	end
	check(lg_err == 0, "legacy data");
	check(lg_count > 0, "legacy port never completed an access");
	check(lg_max_wait <= LG_BOUND, "legacy wait over one burst + refresh");
	$display("   legacy: %0d write/read pairs ok, worst wait %0d clocks (bound %0d)", lg_count, lg_max_wait, LG_BOUND);
	reg_read(A_BUSY, d); reg_read(A_TOTAL, d2);
	$display("   counters: busy %0d of %0d clocks", d, d2);
	reg_read(A_REFR, d); reg_read(A_BURSTS, d2);
	$display("   counters: %0d refreshes, %0d bursts", d, d2);
	check(!fault_seen, "fabric fault");
	check(model_errors == 0, "SDRAM model errors");
	$display("%0t phase B done: %0d errors so far", $time, errors);

	// ---------------- phase C: throughput and fairness ----------------
	$display("%0t phase C: %0d channels, BURST 256, 8192 words each, greedy consumers", $time, N);
	for (c = 0; c < N; c = c + 1)
		setup_channel(c, (c % 2) * BANK + (c / 2) * C_SLOT, imin(8192, C_SLOT - 512), 256, 16, 0);
	reg_write(A_CTRL, 32'h8);
	t0 = cycles;
	reg_write(A_CTRL, 32'h2);
	k = 0;
	while (!any_running && k < 100) begin @(negedge clk); k = k + 1; end
	k = 0;
	while (any_running && k < 2000000) begin @(negedge clk); k = k + 1; end
	check(!any_running, "phase C channels did not finish");
	tmin = c_fin[0]; tmax = c_fin[0];
	for (c = 1; c < N; c = c + 1) begin
		if (c_fin[c] < tmin) tmin = c_fin[c];
		if (c_fin[c] > tmax) tmax = c_fin[c];
	end
	total = 0;
	for (c = 0; c < N; c = c + 1) total = total + c_len[c];
	util = 100.0 * total / (tmax - t0);
	thr_util = 85.0 * N * 10.0 / UCLK_NS;						// consumer-bound when N x uclk is slower than clk
	if (thr_util > 90.0) thr_util = 90.0;
	thr_util = thr_util * (1.0 - REF_FRAC);						// minus the refresh share of the bus
	$display("   %0d words in %0d clocks: %0.1f%% of the bus (threshold %0.0f%%); finish times %0d..%0d",
		total, tmax - t0, util, thr_util, tmin - t0, tmax - t0);
	for (c = 0; c < N; c = c + 1) $display("   ch%0d finished at clock %0d", c, c_fin[c] - t0);
	check(util >= thr_util, "throughput below threshold");
	check((tmax - t0) * 100 <= (tmin - t0) * 110, "finish times differ by more than 10%");
	bursts_expected = 0;
	for (c = 0; c < N; c = c + 1) bursts_expected = bursts_expected + (c_len[c] + 255) / 256;
	reg_read(A_BURSTS, d);
	check(d == bursts_expected, "BURSTS counter");
	$display("   counters: %0d bursts (expected %0d)", d, bursts_expected);
	reg_read(A_BUSY, d); reg_read(A_TOTAL, d2);
	$display("   counters: busy %0d of %0d clocks", d, d2);
	for (c = 0; c < N; c = c + 1) begin
		check_channel(c);
		c_on[c] = 0;
	end
	$display("%0t phase C done: %0d errors so far", $time, errors);

	// ---------------- phase D: loop, abort, soft reset, re-read ----------------
	$display("%0t phase D: loop mode, abort, soft reset, re-read of a lane's region", $time);
	setup_channel(N - 1, 18'h04100, 100, 64, 8, 1);
	reg_write(CH(N - 1, R_CTRL), 32'h7);							// en + loop + start
	k = 0;
	while (c_cnt[N - 1] < 1500 && k < 400000) begin @(negedge uclk); k = k + 1; end
	check(c_cnt[N - 1] >= 1500, "loop mode did not keep streaming");
	check(c_err[N - 1] == 0, "loop mode data (across the wrap)");
	reg_read(CH(N - 1, R_STAT), d);
	check(d[16] == 1, "loop channel not running");
	reg_write(CH(N - 1, R_CTRL), 32'hB);							// en + loop + abort
	wait_channel_done(N - 1);
	reg_read(CH(N - 1, R_STAT), d);
	check(d[16] == 0, "aborted channel still running");
	c_on[N - 1] = 0;
	k = 0;
	while (!idle && k < 10000) begin @(negedge clk); k = k + 1; end
	check(idle, "fabric not idle after the abort");
	check(c_err[N - 1] == 0, "loop mode data after abort");
	uc_seen = 0;
	reg_write(A_CTRL, 32'h1);											// soft reset
	repeat (30) @(negedge clk);
	check(uc_seen[0], "unit_ctrl soft-reset pulse");
	reg_read(CH(N - 1, R_STAT), d);
	check(d[10:0] == 0, "FIFO level not 0 after the soft reset");
	check(d[16] == 0, "running after the soft reset");
	check(idle, "not idle after the soft reset");
	reg_read(CH(N - 1, R_LEN), d);
	check(d == 100, "LEN lost over the soft reset");
	// a channel re-reads what lane 0 wrote in phase B (ref_mem was updated from the lane's expected words)
	setup_channel(0, l_base[0], 2 * l_todo[0], 128, 16, 0);
	reg_write(CH(0, R_CTRL), 32'h5);
	wait_channel_done(0);
	check_channel(0);
	c_on[0] = 0;
	$display("   re-read of lane 0's %0d words ok", 2 * l_todo[0]);
	check(!fault_seen, "fabric fault");
	check(model_errors == 0, "SDRAM model errors");
	$display("%0t phase D done: %0d errors so far", $time, errors);

	if (errors == 0) $display("PASS: stream_fabric N=%0d, uclk %0.1f ns, %0d model errors", N, UCLK_NS, model_errors);
	else $display("FAIL: %0d errors", errors);
	$finish;
end

initial begin
	#40_000_000;
	$display("FAIL: timeout");
	$finish;
end

endmodule
