// Stream fabric: N read channels and N write-back lanes between compute units and one burst SDRAM controller, the
// loader's single-word port, a round-robin burst arbiter and the PC-visible registers (examples/15, spec 4 and 5).
//
// Read channel c streams a region of the SDRAM (BASE, LEN words, in bursts of BURST) into a DEPTH-word FIFO that
// its unit pops (show-ahead: ch_dout is the next word while ch_valid). Credit rule: a channel asks for a burst only
// when its FIFO has room for all of it (DEPTH - level - words already granted and not yet arrived), so a granted
// burst never stalls and the controller needs no backpressure. Continuity needs DEPTH >= 2 x BURST.
// Write lane u takes 32-bit results from its unit (wb_valid / wb_ready), keeps them in a LANE_DEPTH-entry FIFO
// plus one head register (the controller reads from a flip-flop, not from the FIFO's M9K output) and
// writes them as 16-bit words, low half first, from WB_BASE on (the pointer advances): one burst of WBURST words
// when it holds that many, or whatever is left when the unit (wb_flush, a pulse after its last push) or the host
// (WB_CTRL bit 16) flushes.
// The legacy port is sdram_ctrl's contract (req with we/addr/wdata when ready; rvalid/rdata; ready returns when
// the access is complete): example 14's loader plugs in unchanged. Its word goes to the controller ahead of the
// arbiter's choice - one word, it cannot hog the bus - so it waits at most for the burst in progress plus a
// refresh (about 10.5 us at 100 MHz with 1024-word bursts, 2.8 us with 256).
// Arbiter: channels and lanes take turns, round-robin, one burst per grant, in three registered steps so it
// runs at 100 MHz: each requester keeps its request in a register (cleared the clock a grant, an abort, a start
// or a new BURST changes its terms, so the arbiter never sees a request that was just withdrawn); the round-robin
// registers its choice (`sel`); and when the command slot is free the choice is granted: the slot takes the
// requester's address and length registers and the credit is spent. The slot holds the command until the
// controller takes it (cmd_ready), so the next command is already waiting when a burst ends. A requester can be
// granted again 4 clocks after a grant at the earliest, which the burst in progress hides.
// Who owns the data: the controller takes the next command before a read burst's last words are out, so every
// accepted command is queued in order (4 deep) and `done` pops one. Read words go to the channel at the head of
// the queue (dones and data come in command order); write words come from the lane whose write burst was accepted
// last (a write burst's data phase cannot overlap another burst).
// Registers: the map of spec.html section 5. reg_rdata is registered once and 0 outside this block's addresses, so
// a top can OR several blocks' rdata (jtag_regs samples rdata 2 clocks after addr). This block owns 0x001 CTRL,
// 0x003 RD_DELAY, 0x004..0x007 the counters, 0x010 + 8c the channels and 0x080 + 4u the lanes; the top owns 0x000 ID
// and 0x002 STATUS (it has pll_locked and the units' busy), the units own 0x100 up.
// Soft reset (CTRL bit 0): abort first and wait for `idle`. It resets the channels' and lanes' state and the
// FIFOs (BASE/LEN/BURST/WBURST/WB_BASE stay), not a burst the controller is in the middle of: read words for a
// channel that is no longer running are dropped, a write burst left without data is fed zeros (the lane notes
// `underrun`, WB_STAT bit 7).
// Clocks: clk is the controller's; uclk is the units' side of the FIFOs (= clk in example 15, any clock later).
// ***********************************************

module stream_fabric #(
	parameter N = 6,								// read channels = write lanes, 1..14 (the register map's room)
	parameter DEPTH = 1024,						// channel FIFO, words: a power of two, 8..1024
	parameter LANE_DEPTH = 64,					// lane FIFO, 32-bit entries: a power of two, 4..512
	parameter MAX_BURST = 1024,				// words per burst at most (the controller's limit is 1024)
	parameter [2:0] RD_DELAY_DEFAULT = 3'd3
)(
	input							clk,
	input							rst_n,				// synchronous
	input							uclk,					// the units' clock (FIFO sides that face the units)
	input							urst_n,
	// burst controller (sdram_burst_ctrl)
	output						cmd_valid,
	input							cmd_ready,
	output						cmd_we,
	output		[24:0]		cmd_addr,
	output		[10:0]		cmd_len,
	output		[15:0]		wdata,
	output						wvalid,
	input							wready,
	input			[15:0]		rdata,
	input							rvalid,
	input							done,
	input							init_done,
	input							stat_busy,
	input							stat_refresh,
	output reg	[2:0]			rd_delay,
	// legacy single-word master port (the loader of example 14; sdram_ctrl's contract)
	input							lg_req,
	input							lg_we,
	input			[24:0]		lg_addr,
	input			[15:0]		lg_wdata,
	output						lg_ready,
	output reg					lg_rvalid,
	output reg	[15:0]		lg_rdata,
	// units: channel read sides (uclk), show-ahead
	output		[N*16-1:0]	ch_dout,
	output		[N-1:0]		ch_valid,
	input			[N-1:0]		ch_rd_en,
	// units: lane write sides (uclk)
	input			[N*32-1:0]	wb_data,
	input			[N-1:0]		wb_valid,
	output		[N-1:0]		wb_ready,
	input			[N-1:0]		wb_flush,			// a pulse once the unit's last result of a job is pushed
	// registers (the jtag_regs bus)
	input			[15:0]		reg_addr,
	input			[31:0]		reg_wdata,
	input							reg_we,
	output reg	[31:0]		reg_rdata,
	// to the units, from CTRL (0x001): one-clock pulses {clear counters, abort, start, soft reset}
	output reg	[3:0]			unit_ctrl,
	// status for the top
	output						any_running,		// a channel is running
	output						lanes_busy,			// a lane has a burst granted or pending data to flush
	output						legacy_busy,
	output						idle,					// nothing granted, queued or running: safe to soft-reset
	output reg					fault					// the grant queue under- or overflowed (must never happen)
	);

localparam AW  = $clog2(DEPTH);
localparam LAW = $clog2(LANE_DEPTH);
localparam NR  = 2 * N;									// round-robin requesters: channels then lanes
localparam RW  = (NR > 1) ? $clog2(NR) : 1;
localparam [11:0] DEPTH_W = 12'(DEPTH);
localparam [10:0] MAXB = 11'(MAX_BURST);
localparam [LAW:0] LD = (LAW+1)'(LANE_DEPTH);
localparam [1:0] K_RD = 2'd0, K_WR = 2'd1, K_LGR = 2'd2, K_LGW = 2'd3;	// kinds of a granted burst

// ---- register decode ----
wire			sel_glob = (reg_addr[15:4] == 12'h000);								// 0x000..0x00F
wire			sel_ch   = (reg_addr[15:7] == 9'd0) && (reg_addr[6:3] >= 4'd2);	// 0x010..0x07F
wire	[3:0]	ch_idx   = reg_addr[6:3] - 4'd2;
wire	[2:0]	ch_reg   = reg_addr[2:0];
wire			sel_ln   = (reg_addr[15:7] == 9'd1);									// 0x080..0x0FF
wire	[4:0]	ln_idx   = reg_addr[6:2];
wire	[1:0]	ln_reg   = reg_addr[1:0];
wire			ctrl_we  = reg_we && sel_glob && (reg_addr[3:0] == 4'd1);
wire			ctrl_soft  = ctrl_we && reg_wdata[0];
wire			ctrl_start = ctrl_we && reg_wdata[1];
wire			ctrl_abort = ctrl_we && reg_wdata[2];
wire			ctrl_clear = ctrl_we && reg_wdata[3];

// ---- soft reset: 8 clocks wide, crossed to uclk (both FIFO sides must see it) ----
reg	[3:0]	srst_cnt = 0;
wire			srst = (srst_cnt != 0);
reg			srst_u1 = 0, srst_u2 = 0;
always @(posedge clk) begin
	if (!rst_n) srst_cnt <= 0;
	else if (ctrl_soft) srst_cnt <= 4'd8;
	else if (srst) srst_cnt <= srst_cnt - 1'b1;
end
always @(posedge uclk) begin
	srst_u1 <= srst;
	srst_u2 <= srst_u1;
end
wire			frst_n  = rst_n && !srst;				// channels, lanes, the FIFO sides on clk
wire			ufrst_n = urst_n && !srst_u2;			// the FIFO sides on uclk

// ---- the command slot (the round-robin's choice, waiting for the controller) and the grant queue ----
reg			cmd_v = 0, cmd_w = 0;
reg	[24:0]	cmd_a = 0;
reg	[10:0]	cmd_l = 0;
reg	[1:0]		g_kind = 0;
reg	[3:0]		g_id = 0;

// ---- legacy port ----
reg			lg_pend = 0, lg_busy = 0, lg_we_r = 0;
reg	[24:0]	lg_addr_r = 0;
reg	[15:0]	lg_wdata_r = 0;
assign lg_ready = init_done && !lg_pend && !lg_busy && !lg_req;
assign legacy_busy = lg_pend || lg_busy;

// the command the controller sees: the pending legacy word first (one word, it cannot hog the bus), else the slot
assign cmd_valid = lg_pend || cmd_v;
assign cmd_we    = lg_pend ? lg_we_r   : cmd_w;
assign cmd_addr  = lg_pend ? lg_addr_r : cmd_a;
assign cmd_len   = lg_pend ? 11'd1     : cmd_l;
wire			accept_lg = lg_pend && cmd_ready;
wire			accept_rr = cmd_v && !lg_pend && cmd_ready;
wire			accept    = accept_lg || accept_rr;
wire			slot_free = !cmd_v || accept_rr;
wire	[1:0]	a_kind = lg_pend ? (lg_we_r ? K_LGW : K_LGR) : g_kind;		// what is being accepted
wire	[3:0]	a_id   = lg_pend ? 4'd0 : g_id;

reg	[5:0]	q_mem [0:3];								// {kind, id} of accepted bursts, in order
reg	[1:0]	q_wr = 0, q_rd = 0;
reg	[2:0]	q_cnt = 0;
wire			q_empty = (q_cnt == 0);
wire	[1:0]	h_kind = q_mem[q_rd][5:4];
wire	[3:0]	h_id   = q_mem[q_rd][3:0];
wire			pop = done && !q_empty;
integer		qi;
initial for (qi = 0; qi < 4; qi = qi + 1) q_mem[qi] = 0;

// the lane (or the legacy port) feeding the write burst the controller is running; the lane is one-hot so the
// data mux is an AND-OR, two LUT levels for N <= 8
reg			wr_act = 0, wr_lg = 0;
reg	[N-1:0]	wr_sel = 0;

// ---- round-robin over channels (0..N-1) and lanes (N..2N-1) ----
// Step 1 lives in the channel and lane blocks: the request `req_q` is a register the arbiter can trust (never a
// stale 1; a stale 0 costs a clock). Step 2: the first requester after the last one served (or after `sel`, the
// one already chosen and waiting for the slot, which is skipped) is registered into `sel`. Step 3: when the slot
// is free, `sel` is granted with that requester's address and length as they stand: only a grant can shrink its
// credit or change its next burst, and it has had none since it asked (an abort, start or BURST write cancels
// the choice instead). Every step reads registers only, so no path crosses the whole arbiter in one clock.
wire	[N-1:0]		ch_req, ln_req;								// the registered requests
wire	[N-1:0]		ch_kill;											// a channel's abort, start or BURST write this clock
wire	[N*25-1:0]	ch_addr_f, ln_addr_f;
wire	[N*11-1:0]	ch_len_f, ln_len_f;
reg					sel_v = 0, sel_lane = 0;
reg	[3:0]			sel_id = 0;
reg	[RW-1:0]		sel_idx = 0, rr_last = 0;
wire	[NR-1:0]		sel_mask = sel_v ? (NR'(1) << sel_idx) : NR'(0);
wire	[NR-1:0]		rr_req = {ln_req, ch_req} & ~sel_mask & ~{{N{1'b0}}, ch_kill};
wire	[RW-1:0]		rr_base = sel_v ? sel_idx : rr_last;
wire	[2*NR-1:0]	rr_dbl = {rr_req, rr_req};
reg	[RW:0]		win;
reg					win_v;
integer				ka;
always_comb begin											// the first requester after rr_base, wrapping
	win = 0;
	win_v = 0;
	for (ka = 2*NR - 1; ka >= 0; ka = ka - 1)
		if (rr_dbl[ka] && (ka > rr_base)) begin
			win = (ka >= NR) ? (ka - NR) : ka;
			win_v = 1'b1;
		end
end
wire			grant = sel_v && slot_free;
wire	[N-1:0]	ch_grant, ln_grant;
reg	[24:0]	sel_addr;
reg	[10:0]	sel_len;
reg			sel_kill;
integer		ks;
always_comb begin											// the chosen requester's address and length (an N-way select)
	sel_addr = 25'd0;
	sel_len = 11'd0;
	sel_kill = 1'b0;
	for (ks = 0; ks < N; ks = ks + 1)
		if (sel_id == ks) begin
			sel_addr = sel_lane ? ln_addr_f[ks*25 +: 25] : ch_addr_f[ks*25 +: 25];
			sel_len  = sel_lane ? ln_len_f[ks*11 +: 11] : ch_len_f[ks*11 +: 11];
			sel_kill = !sel_lane && ch_kill[ks];
		end
end
genvar g;
generate for (g = 0; g < N; g = g + 1) begin : gg
	assign ch_grant[g] = grant && !sel_lane && (sel_id == g);
	assign ln_grant[g] = grant && sel_lane && (sel_id == g);
end endgenerate

always @(posedge clk) begin
	if (grant || !sel_v) begin								// the slot took the choice (or there was none): choose again
		sel_v <= win_v;
		sel_idx <= win[RW-1:0];
		sel_lane <= (win >= N);
		sel_id <= (win >= N) ? 4'(win - N) : 4'(win);
	end
	else if (sel_kill) sel_v <= 1'b0;						// the chosen channel was aborted or reprogrammed: choose again
	if (accept_rr) cmd_v <= 1'b0;
	if (grant) begin
		cmd_v <= 1'b1;
		cmd_w <= sel_lane;
		cmd_a <= sel_addr;
		cmd_l <= sel_len;
		g_kind <= sel_lane ? K_WR : K_RD;
		g_id <= sel_id;
		rr_last <= sel_idx;
	end
	if (!frst_n) sel_v <= 1'b0;
	if (!rst_n) begin
		cmd_v <= 1'b0;
		rr_last <= 0;
	end
end

// the queue: push on accept, pop on done
always @(posedge clk) begin
	if (accept) begin
		q_mem[q_wr] <= {a_kind, a_id};
		q_wr <= q_wr + 1'b1;
	end
	if (pop) q_rd <= q_rd + 1'b1;
	q_cnt <= q_cnt + (accept ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);
	if ((accept && q_cnt == 3'd4) || (done && q_empty)) fault <= 1'b1;
	// write-data owner
	if (accept && a_kind[0]) begin
		wr_act <= 1'b1;
		wr_lg <= (a_kind == K_LGW);
		wr_sel <= (a_kind == K_LGW) ? N'(0) : (N'(1) << a_id);
	end
	else if (pop && h_kind[0]) begin
		wr_act <= 1'b0;
		wr_sel <= N'(0);
	end
	if (!rst_n) begin
		q_wr <= 0;
		q_rd <= 0;
		q_cnt <= 0;
		fault <= 1'b0;
		wr_act <= 1'b0;
		wr_sel <= N'(0);
	end
end

// legacy port state
always @(posedge clk) begin
	lg_rvalid <= 1'b0;
	if (lg_req) begin											// only comes when lg_ready was high the clock before
		lg_pend <= 1'b1;
		lg_we_r <= lg_we;
		lg_addr_r <= lg_addr;
		lg_wdata_r <= lg_wdata;
	end
	if (accept_lg) begin
		lg_pend <= 1'b0;
		lg_busy <= 1'b1;
	end
	if (pop && h_kind[1]) lg_busy <= 1'b0;
	if (rvalid && !q_empty && h_kind == K_LGR) begin
		lg_rvalid <= 1'b1;
		lg_rdata <= rdata;
	end
	if (!rst_n) begin
		lg_pend <= 1'b0;
		lg_busy <= 1'b0;
		lg_rvalid <= 1'b0;
		lg_rdata <= 16'd0;
	end
end

// ---- write data to the controller ----
wire	[N*16-1:0]	ln_word_f;
reg	[15:0]		ln_word;
integer				kb;
always_comb begin
	ln_word = 16'd0;
	for (kb = 0; kb < N; kb = kb + 1)
		ln_word = ln_word | (ln_word_f[kb*16 +: 16] & {16{wr_sel[kb]}});
end
assign wdata = wr_lg ? lg_wdata_r : ln_word;
assign wvalid = wr_act;

// ---- read channels ----
wire	[N-1:0]		ch_running;
wire	[N*32-1:0]	ch_rd_f;
generate for (g = 0; g < N; g = g + 1) begin : ch
	reg	[24:0]	base = 0, len = 0;
	reg	[10:0]	burst = 11'd256, burst_e = 11'd256;	// BURST as written, and clamped (0 or > MAX_BURST -> MAX_BURST)
	reg				en = 0, loop = 0;
	reg				running = 0, done_f = 0;
	reg	[24:0]	naddr = 0, remain = 0;
	reg	[10:0]	inflight = 0;
	reg	[10:0]	this_len = 0;						// words of the next burst, min(burst_e, remain), a clock behind
	reg	[11:0]	room = 0;							// DEPTH - level - inflight, a clock behind: pushes leave it as it
	                                             // is (level up, inflight down), pops only grow it, grants shrink it
	reg				req_q = 0, hold = 0;
	reg	[31:0]	fetched = 0, waited = 0;
	wire	[AW:0]	wlevel;
	wire				full, empty, ovf;
	wire				my_reg = reg_we && sel_ch && (ch_idx == g);
	wire				start = (my_reg && ch_reg == 3'd3 && reg_wdata[2]) || (ctrl_start && en);
	wire				abort = (my_reg && ch_reg == 3'd3 && reg_wdata[3]) || ctrl_abort;
	wire				clear = (my_reg && ch_reg == 3'd3 && reg_wdata[4]) || ctrl_clear;
	wire				burst_wr = my_reg && (ch_reg == 3'd2);
	wire				push = rvalid && !q_empty && (h_kind == K_RD) && (h_id == g) && running;
	wire				last_of_pass = (remain == {14'd0, this_len});
	wire				live_req = running && (remain != 25'd0) && (room >= {1'b0, this_len});

	assign ch_req[g] = req_q;
	assign ch_kill[g] = abort || start || burst_wr;
	assign ch_addr_f[g*25 +: 25] = naddr;
	assign ch_len_f[g*11 +: 11] = this_len;
	assign ch_running[g] = running;

	always @(posedge clk) begin
		if (my_reg) case (ch_reg)
			3'd0: base <= reg_wdata[24:0];
			3'd1: len <= reg_wdata[24:0];
			3'd2: begin
				burst <= reg_wdata[10:0];
				burst_e <= (reg_wdata[10:0] == 11'd0 || reg_wdata[10:0] > MAXB) ? MAXB : reg_wdata[10:0];
			end
			3'd3: {loop, en} <= reg_wdata[1:0];
			default: ;
		endcase
		this_len <= (remain > {14'd0, burst_e}) ? burst_e : remain[10:0];
		room <= DEPTH_W - {{(11-AW){1'b0}}, wlevel} - {1'b0, inflight};
		// the request the arbiter sees: cleared by whatever changes its terms (a grant, abort, start, a new
		// BURST) and held low one more clock while this_len and room catch up with the new state
		hold <= ch_grant[g] || ch_kill[g];
		req_q <= live_req && !hold;
		if (ch_grant[g] || ch_kill[g]) req_q <= 1'b0;
		inflight <= inflight + (ch_grant[g] ? this_len : 11'd0) - (push ? 11'd1 : 11'd0);
		if (push) fetched <= fetched + 1'b1;
		if (req_q && !ch_grant[g]) waited <= waited + 1'b1;
		if (ch_grant[g]) begin
			if (last_of_pass && loop) begin
				naddr <= base;
				remain <= len;
			end
			else begin
				naddr <= naddr + {14'd0, this_len};
				remain <= remain - {14'd0, this_len};
			end
		end
		if (running && remain == 25'd0 && inflight == 11'd0 && !push) begin
			running <= 1'b0;
			done_f <= 1'b1;
		end
		if (start) begin
			naddr <= base;
			remain <= len;
			running <= 1'b1;
			done_f <= 1'b0;
		end
		if (abort) remain <= 25'd0;
		if (clear) begin
			fetched <= 0;
			waited <= 0;
		end
		if (!frst_n) begin
			running <= 1'b0;
			done_f <= 1'b0;
			remain <= 0;
			inflight <= 0;
			req_q <= 1'b0;
			hold <= 1'b0;
			fetched <= 0;
			waited <= 0;
		end
	end

	async_fifo #(.WIDTH(16), .DEPTH(DEPTH)) fifo(
		.wclk(clk), .wrst_n(frst_n), .wr_en(push), .wdata(rdata), .full(full), .wlevel(wlevel), .overflow(ovf),
		.rclk(uclk), .rrst_n(ufrst_n), .rd_en(ch_rd_en[g]), .rdata(ch_dout[g*16 +: 16]), .empty(empty),
		.rlevel(), .underflow());
	assign ch_valid[g] = !empty;

	reg	[31:0]	rd;
	always @(*) begin
		rd = 32'd0;
		if (sel_ch && ch_idx == g) case (ch_reg)
			3'd0: rd = {7'd0, base};
			3'd1: rd = {7'd0, len};
			3'd2: rd = {21'd0, burst};
			3'd3: rd = {30'd0, loop, en};
			3'd4: rd = {13'd0, ovf, done_f, running, 5'd0, 11'(wlevel)};
			3'd5: rd = fetched;
			3'd6: rd = waited;
			default: rd = 32'd0;
		endcase
	end
	assign ch_rd_f[g*32 +: 32] = rd;
end endgenerate

// ---- write-back lanes ----
wire	[N-1:0]		ln_busy;
wire	[N*32-1:0]	ln_rd_f;
generate for (g = 0; g < N; g = g + 1) begin : ln
	reg	[24:0]	ptr = 0;
	reg	[10:0]	wburst = 11'd64;
	reg	[23:0]	words = 0;
	reg				flush_pend = 0, busy = 0, half = 0, underrun = 0;
	reg				fl_tog = 0, fl_s1 = 0, fl_s2 = 0, fl_s3 = 0, fl_s4 = 0;
	wire	[LAW:0]	rlevel;
	wire	[31:0]	frd;
	wire				full, empty;
	// the head entry sits in a register: the controller takes its two half-words straight from a flip-flop
	// instead of from the FIFO's M9K output (2.5 ns after the edge, then two muxes: too slow at 100 MHz). The
	// FIFO shows the next entry the clock after a pop, so the register refills without a bubble, and the lane
	// holds LANE_DEPTH + 1 entries. `lvl` is what the lane really has; it does not move when the head loads.
	reg	[31:0]	hq = 0;
	reg				hv = 0;
	wire	[LAW:0]	lvl = rlevel + {{LAW{1'b0}}, hv};
	wire				my_reg = reg_we && sel_ln && (ln_idx == g);
	wire	[9:0]		wb_ent = wburst[10:1];									// WBURST in entries (2 words each)
	wire	[LAW:0]	thr = (wb_ent == 10'd0) ? {{LAW{1'b0}}, 1'b1} :
	                    (wb_ent > LANE_DEPTH) ? LD : wb_ent[LAW:0];
	wire				thr_ok = (lvl >= thr);
	reg	[LAW:0]	n_ent = 0;								// entries of the next write burst, a clock behind lvl
	                                                // (which only grows while the lane waits for a grant)
	reg				req_q = 0;
	wire				live_req = !busy && (thr_ok || (flush_pend && lvl != 0));
	wire				sel = wr_sel[g];
	wire				take = sel && wready;
	wire				hload = (!hv || (take && half)) && !empty;		// head empty, or emptied this clock: refill
	wire				fl_pulse = fl_s3 ^ fl_s4;

	assign ln_req[g] = req_q;
	assign ln_addr_f[g*25 +: 25] = ptr;
	assign ln_len_f[g*11 +: 11] = 11'({n_ent, 1'b0});
	assign ln_busy[g] = busy || flush_pend;
	assign ln_word_f[g*16 +: 16] = !hv ? 16'd0 : (half ? hq[31:16] : hq[15:0]);

	// the unit's flush pulse crosses as a toggle (pulses at least 8 uclk apart), one clock later than a pointer
	always @(posedge uclk) if (wb_flush[g]) fl_tog <= ~fl_tog;
	always @(posedge clk) begin
		fl_s1 <= fl_tog;
		fl_s2 <= fl_s1;
		fl_s3 <= fl_s2;
		fl_s4 <= fl_s3;
	end

	always @(posedge clk) begin
		if (my_reg) case (ln_reg)
			2'd0: ptr <= reg_wdata[24:0];
			2'd1: wburst <= reg_wdata[10:0];
			default: ;
		endcase
		n_ent <= thr_ok ? thr : lvl;
		req_q <= live_req;									// busy goes up the clock of the grant: never a stale 1
		if (ln_grant[g]) req_q <= 1'b0;
		if (fl_pulse || (my_reg && ln_reg == 2'd1 && reg_wdata[16])) flush_pend <= 1'b1;
		else if (flush_pend && !busy && lvl == 0) flush_pend <= 1'b0;
		if (ln_grant[g]) begin
			busy <= 1'b1;
			half <= 1'b0;
			ptr <= ptr + {14'd0, n_ent, 1'b0};
		end
		if (pop && h_kind == K_WR && h_id == g) busy <= 1'b0;
		if (take) begin
			half <= !half;
			words <= words + 1'b1;
			if (!hv) underrun <= 1'b1;
		end
		if (hload) begin
			hq <= frd;
			hv <= 1'b1;
		end else if (take && half)
			hv <= 1'b0;
		if (my_reg && ln_reg == 2'd1 && reg_wdata[17]) begin
			words <= 0;
			underrun <= 1'b0;
		end
		if (ctrl_clear) words <= 0;
		if (!frst_n) begin
			flush_pend <= 1'b0;
			busy <= 1'b0;
			half <= 1'b0;
			hv <= 1'b0;
			underrun <= 1'b0;
			req_q <= 1'b0;
			words <= 0;
		end
	end

	async_fifo #(.WIDTH(32), .DEPTH(LANE_DEPTH)) fifo(
		.wclk(uclk), .wrst_n(ufrst_n), .wr_en(wb_valid[g] && !full), .wdata(wb_data[g*32 +: 32]), .full(full),
		.wlevel(), .overflow(),
		.rclk(clk), .rrst_n(frst_n), .rd_en(hload), .rdata(frd), .empty(empty), .rlevel(rlevel),
		.underflow());
	assign wb_ready[g] = !full;

	reg	[31:0]	rd;
	always @(*) begin
		rd = 32'd0;
		if (sel_ln && ln_idx == g) case (ln_reg)
			2'd0: rd = {7'd0, ptr};
			2'd1: rd = {21'd0, wburst};
			2'd2: rd = {words, underrun, 7'(lvl)};
			default: rd = 32'd0;
		endcase
	end
	assign ln_rd_f[g*32 +: 32] = rd;
end endgenerate

// ---- counters, status, the register read ----
reg	[31:0]	busy_clocks = 0, total_clocks = 0, refreshes = 0, bursts = 0;
always @(posedge clk) begin
	unit_ctrl <= {ctrl_clear, ctrl_abort, ctrl_start, ctrl_soft};
	if (reg_we && sel_glob && reg_addr[3:0] == 4'd3) rd_delay <= reg_wdata[2:0];
	total_clocks <= total_clocks + 1'b1;
	if (stat_busy) busy_clocks <= busy_clocks + 1'b1;
	if (stat_refresh) refreshes <= refreshes + 1'b1;
	if (accept) bursts <= bursts + 1'b1;
	if (ctrl_clear || !rst_n) begin
		total_clocks <= 0;
		busy_clocks <= 0;
		refreshes <= 0;
		bursts <= 0;
	end
	if (!rst_n) begin
		rd_delay <= RD_DELAY_DEFAULT;
		unit_ctrl <= 0;
	end
end

assign any_running = |ch_running;
assign lanes_busy = |ln_busy;
assign idle = !any_running && !lanes_busy && !legacy_busy && !sel_v && !cmd_v && q_empty;

reg	[31:0]	glob_rd, ch_rd_or, ln_rd_or;
integer		kc;
always @(*) begin
	glob_rd = 32'd0;
	if (sel_glob) case (reg_addr[3:0])
		4'd3: glob_rd = {29'd0, rd_delay};
		4'd4: glob_rd = busy_clocks;
		4'd5: glob_rd = total_clocks;
		4'd6: glob_rd = refreshes;
		4'd7: glob_rd = bursts;
		default: glob_rd = 32'd0;
	endcase
	ch_rd_or = 32'd0;
	ln_rd_or = 32'd0;
	for (kc = 0; kc < N; kc = kc + 1) begin
		ch_rd_or = ch_rd_or | ch_rd_f[kc*32 +: 32];
		ln_rd_or = ln_rd_or | ln_rd_f[kc*32 +: 32];
	end
end
always @(posedge clk) reg_rdata <= rst_n ? (glob_rd | ch_rd_or | ln_rd_or) : 32'd0;

endmodule
