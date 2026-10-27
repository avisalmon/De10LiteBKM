// Matrix-vector compute unit for the stream fabric (examples/15, spec section 7): y = W_slice . x for T activation
// vectors at once, the int8 weights streaming from a fabric read channel, the results going to a fabric write lane.
//
// Stream format (model.q8.bin, spec 6): a row of W is K/32 groups; a group is 16 words of int8 pairs (word j =
// {w[2j+1], w[2j]}) followed by one word holding the group's int16 scale s_g. For every row and every vector t the
// unit computes acc_t = sum_g (sum_j w_j * x_t[j]) * s_g exactly (48-bit) and pushes y_t = saturate_int32(acc_t >>>
// SHIFT): T int32 values per row, t = 0..T-1, row after row (the lane writes each as two 16-bit words, low half
// first). The host applies the per-matrix exponent and the activation scale afterwards.
// Per clock, when the FIFO has a word, the unit pops it. A weight word reads x_t[k], x_t[k+1] from every x-buffer
// (T_MAX RAMs of 256 x 32, one M9K each, all at the same address), forms p_t = w0 * x_t[k] + w1 * x_t[k+1] (two
// 9 x 9 multiplies per vector) and adds it to the group sum gsum_t (21-bit). The scale word moves the T group sums
// to a holding bank and starts the scale MAC, acc_t += gsum_t * s_g, one t per clock over the next T (< 17) clocks
// while the next group already streams. The last group of a row completes the row's accumulators; they swap with a
// second bank (ping-pong), so the next row accumulates while this one is read, shifted, saturated and pushed, one
// value per 3 clocks. The stream only waits when a row's results are still being pushed (the lane stalled) as the
// next row's last scale word reaches the FIFO head; CYCLES_STALLED counts those clocks.
// Registers, 16 at REG_BASE (0x100 + 16u), also written through REG_BCAST (0x1F0: every unit takes the write,
// none answers a read):
//   +0 ROWS   rows in this unit's slice; 0 = disabled (ignores the fabric's global start; a direct start sets done)
//   +1 K      row length, a multiple of 32, 32..1024      +2 T   vectors in use, 1..T_MAX      +3 SHIFT  0..47
//   +4 CTRL   bit 0 start (self-clearing), bit 1 abort, bit 2 clear the counters
//   +5 STAT   bit 0 busy, bit 1 done, bit 2 the lane held a result at least once, bit 3 aborted (2..3 sticky to the
//             next start), [15:8] T_MAX
//   +6 CYCLES_BUSY     clocks running (start to the last result pushed)
//   +7 CYCLES_STARVED  clocks running, a word wanted, the FIFO empty: memory was the limit
//   +8 XADDR  [15:12] vector t, [9:2] 4-byte position; +9 XDATA  a write stores 4 bytes of x at XADDR, XADDR += 4
//   +10 ROWS_DONE  rows pushed      +11 CYCLES_STALLED  clocks running, a word ready, held for the lane
//   +12 WORDS  words popped since the counters were cleared      +13..15 read 0
// The fabric's CTRL (0x001) pulses arrive on g_ctrl = {clear counters, abort, start (taken when ROWS != 0), soft
// reset (= abort; the configuration and x stay)}. Byte k of vector t lives at XADDR = {t, k}: the host writes all
// K bytes (zeros over the padding: an unwritten buffer multiplies as X in simulation), 4 per write.
// One clock domain: the fabric's uclk (= clk in example 15, so the register bus needs no crossing).
// ***********************************************

module matvec_unit #(
	parameter T_MAX = 8,								// x-buffers (vectors held at once), 1..15
	parameter ACC_W = 48,							// row accumulator width (> 32)
	parameter [15:0] REG_BASE  = 16'h0100,		// this unit's 16 registers
	parameter [15:0] REG_BCAST = 16'h01F0		// a write here lands in every unit
)(
	input							clk,
	input							rst_n,				// synchronous
	// weight stream from a fabric read channel (show-ahead FIFO: s_data is the next word while s_valid)
	input			[15:0]		s_data,
	input							s_valid,
	output						s_rd_en,
	// results to a fabric write lane
	output		[31:0]		wb_data,
	output reg					wb_valid,
	input							wb_ready,
	output reg					wb_flush,			// one pulse after the job's last result
	// one-clock pulses from the fabric's CTRL register: {clear counters, abort, start, soft reset}
	input			[3:0]			g_ctrl,
	// the jtag_regs bus; reg_rdata is registered once and 0 outside this unit's addresses (OR-able)
	input			[15:0]		reg_addr,
	input			[31:0]		reg_wdata,
	input							reg_we,
	output reg	[31:0]		reg_rdata,
	output						busy
	);

localparam GW = 21;									// group sum: |16 words x 2 x 128 x 128| = 2^19
localparam PW = GW + 16;								// group sum x scale
localparam [3:0] TM = 4'(T_MAX);
localparam [4:0] TM5 = 5'(T_MAX);

// ---- registers ----
reg	[19:0]	r_rows = 0;
reg	[10:0]	r_k = 11'd32;
reg	[3:0]		r_t = 4'd1;
reg	[5:0]		r_shift = 0;
reg	[15:0]	r_xaddr = 0;
wire				sel_me = (reg_addr[15:4] == REG_BASE[15:4]);
wire				sel_bc = (reg_addr[15:4] == REG_BCAST[15:4]);
wire				wr = reg_we && (sel_me || sel_bc);
wire	[3:0]		ridx = reg_addr[3:0];
wire				ctrl_wr = wr && (ridx == 4'd4);
wire				x_we = wr && (ridx == 4'd9);

// ---- job state ----
reg				running = 0, done = 0, aborted = 0, lane_stalled = 0;
reg	[19:0]	job_rows = 0;
reg	[5:0]		job_g = 6'd1;						// groups per row = K / 32
reg	[3:0]		job_t = 4'd1;
reg	[5:0]		job_shift = 0;
reg	[4:0]		wcnt = 0;							// word in the group: 0..15 weights, 16 the scale
reg	[5:0]		gcnt = 0;							// group in the row
reg	[19:0]	rcnt = 0;							// rows popped
reg	[19:0]	rows_done = 0;						// rows pushed
reg				row_pending = 0;					// a row's last scale word is in and its results are not all out
localparam [1:0] E_IDLE = 2'd0, E_SEL = 2'd1, E_SHIFT = 2'd2, E_PUSH = 2'd3;
reg	[1:0]		estate = E_IDLE;					// the result path
reg	[3:0]		emit_t = 0;

wire				abort_req = (ctrl_wr && reg_wdata[1]) || g_ctrl[2] || g_ctrl[0];
wire				clear_req = (ctrl_wr && reg_wdata[2]) || g_ctrl[3];
wire				start_req = (ctrl_wr && reg_wdata[0]) || (g_ctrl[1] && (r_rows != 0));
wire				start_go = start_req && !running && !abort_req && (r_rows != 0);
wire				start_empty = ctrl_wr && reg_wdata[0] && !running && !abort_req && (r_rows == 0);
wire				is_scale = (wcnt == 5'd16);
wire				last_g = (gcnt == job_g - 1'b1);
wire				want_pop = running && (rcnt != job_rows);
wire				stall = is_scale && last_g && row_pending;
wire				pop = want_pop && s_valid && !stall;
wire				push = (estate == E_PUSH) && wb_ready;
wire				row_end = push && (emit_t == job_t - 1'b1);
wire				job_end = row_end && (rows_done + 1'b1 == job_rows);
assign s_rd_en = pop;
assign busy = running;

wire	[5:0]		k_groups = r_k[10:5];

always @(posedge clk) begin
	if (!rst_n) begin
		running <= 1'b0;
		done <= 1'b0;
		aborted <= 1'b0;
		lane_stalled <= 1'b0;
	end else begin
		if (abort_req) begin
			if (running) aborted <= 1'b1;
			running <= 1'b0;
		end else if (start_go) begin
			running <= 1'b1;
			done <= 1'b0;
			aborted <= 1'b0;
			lane_stalled <= 1'b0;
			job_rows <= r_rows;
			job_g <= (k_groups == 6'd0) ? 6'd1 : k_groups;
			job_t <= (r_t == 4'd0) ? 4'd1 : (r_t > TM) ? TM : r_t;
			job_shift <= r_shift;
		end else if (job_end) begin
			running <= 1'b0;
			done <= 1'b1;
		end
		if (start_empty) done <= 1'b1;
		if (wb_valid && !wb_ready) lane_stalled <= 1'b1;
	end
end

// ---- the stream: position counters ----
always @(posedge clk) begin
	if (!rst_n || abort_req || start_go) begin
		wcnt <= 0;
		gcnt <= 0;
		rcnt <= 0;
	end else if (pop) begin
		if (is_scale) begin
			wcnt <= 0;
			if (last_g) begin
				gcnt <= 0;
				rcnt <= rcnt + 1'b1;
			end else gcnt <= gcnt + 1'b1;
		end else wcnt <= wcnt + 1'b1;
	end
end

always @(posedge clk) begin
	if (!rst_n || abort_req || start_go) row_pending <= 1'b0;
	else if (pop && is_scale && last_g) row_pending <= 1'b1;
	else if (row_end) row_pending <= 1'b0;
end

// ---- x-buffers: T_MAX RAMs of 256 x 32 (byte k of vector t at word k/4), read at the pair (k, k+1) ----
wire	[7:0]				x_raddr = {gcnt[4:0], wcnt[3:1]};
wire	[T_MAX*32-1:0]	xq;
genvar t;
generate for (t = 0; t < T_MAX; t = t + 1) begin : xb
	reg	[31:0]	mem [0:255];
	reg	[31:0]	q = 0;
	always @(posedge clk) begin
		if (x_we && (r_xaddr[15:12] == t)) mem[r_xaddr[9:2]] <= reg_wdata;
		q <= mem[x_raddr];
	end
	assign xq[32*t +: 32] = q;
end endgenerate

// ---- stage 1: the word and the x pair are both registered ----
reg				v1 = 0, sc1 = 0, lg1 = 0, sel1 = 0;
reg	[15:0]	d1 = 0;
always @(posedge clk) begin
	if (!rst_n || abort_req) v1 <= 1'b0;
	else v1 <= pop;
	sc1 <= is_scale;
	lg1 <= last_g;
	sel1 <= wcnt[0];
	d1 <= s_data;
end

// ---- stage 2: p_t = w0 * x_t[k] + w1 * x_t[k+1] ----
reg				v2 = 0, sc2 = 0, lg2 = 0;
reg	[15:0]	d2 = 0;
wire signed [7:0]		w0 = d1[7:0];
wire signed [7:0]		w1 = d1[15:8];
wire	[T_MAX*17-1:0]	p2;
generate for (t = 0; t < T_MAX; t = t + 1) begin : pr
	wire signed [7:0]	xa = sel1 ? xq[32*t+16 +: 8] : xq[32*t +: 8];
	wire signed [7:0]	xc = sel1 ? xq[32*t+24 +: 8] : xq[32*t+8 +: 8];
	reg signed [16:0]	p = 0;
	always @(posedge clk) p <= w0 * xa + w1 * xc;
	assign p2[17*t +: 17] = p;
end endgenerate
always @(posedge clk) begin
	if (!rst_n || abort_req) v2 <= 1'b0;
	else v2 <= v1;
	sc2 <= sc1;
	lg2 <= lg1;
	d2 <= d1;
end

// ---- stage 3: group sums; the scale word holds them and starts the scale MAC ----
reg signed [GW-1:0]	gsum [0:T_MAX-1];
reg signed [GW-1:0]	ghold [0:T_MAX-1];
reg signed [15:0]		s_hold = 0;
reg						hold_last = 0, mac_run = 0;
reg	[3:0]				mac_cnt = 0;
integer i;
initial for (i = 0; i < T_MAX; i = i + 1) begin gsum[i] = 0; ghold[i] = 0; end
always @(posedge clk) begin
	if (!rst_n || abort_req || start_go) begin
		for (i = 0; i < T_MAX; i = i + 1) gsum[i] <= 0;
		mac_run <= 1'b0;
	end else begin
		if (v2 && !sc2)
			for (i = 0; i < T_MAX; i = i + 1) gsum[i] <= gsum[i] + $signed(p2[17*i +: 17]);
		if (v2 && sc2) begin
			for (i = 0; i < T_MAX; i = i + 1) begin
				ghold[i] <= gsum[i];
				gsum[i] <= 0;
			end
			s_hold <= d2;
			hold_last <= lg2;
			mac_run <= 1'b1;
			mac_cnt <= 0;
		end else if (mac_run) begin
			if (mac_cnt == job_t - 1'b1) mac_run <= 1'b0;
			mac_cnt <= mac_cnt + 1'b1;
		end
	end
end

// ---- the scale MAC: acc_t += ghold_t * s_g, one t per clock, into the accumulating bank ----
reg signed [PW-1:0]		prod = 0;
reg							pv = 0, plast = 0, row_done = 0;
reg	[3:0]					pt = 0;
reg							mbank = 0, ebank = 0;
reg signed [ACC_W-1:0]	acc [0:2*T_MAX-1];
initial for (i = 0; i < 2*T_MAX; i = i + 1) acc[i] = 0;
always @(posedge clk) begin
	if (!rst_n || abort_req) begin
		pv <= 1'b0;
		row_done <= 1'b0;
	end else begin
		pv <= mac_run;
		row_done <= pv && plast;
	end
	prod <= ghold[mac_cnt] * s_hold;
	pt <= mac_cnt;
	plast <= hold_last && (mac_cnt == job_t - 1'b1);
end

// ---- results: the finished bank is read, shifted, saturated and pushed, one value per 3 clocks ----
reg signed [ACC_W-1:0]	selv = 0, sh = 0;
wire	[4:0]					midx = mbank ? (TM5 + {1'b0, pt}) : {1'b0, pt};
wire	[4:0]					eidx = ebank ? (TM5 + {1'b0, emit_t}) : {1'b0, emit_t};
wire							fits = (sh[ACC_W-1:31] == {(ACC_W-31){sh[31]}});
assign wb_data = fits ? sh[31:0] : (sh[ACC_W-1] ? 32'h8000_0000 : 32'h7FFF_FFFF);

always @(posedge clk) begin
	if (!rst_n || abort_req || start_go) begin
		for (i = 0; i < 2*T_MAX; i = i + 1) acc[i] <= 0;
	end else begin
		if (pv) acc[midx] <= acc[midx] + prod;
		if (estate == E_SEL) acc[eidx] <= 0;				// the other bank: read into selv this same clock
	end
end

always @(posedge clk) begin
	wb_flush <= 1'b0;
	if (!rst_n || abort_req || start_go) begin
		estate <= E_IDLE;
		wb_valid <= 1'b0;
		mbank <= 1'b0;
		ebank <= 1'b0;
		emit_t <= 0;
		rows_done <= 0;
	end else case (estate)
		E_IDLE: if (row_done) begin
			ebank <= mbank;
			mbank <= ~mbank;
			emit_t <= 0;
			estate <= E_SEL;
		end
		E_SEL: begin
			selv <= acc[eidx];
			estate <= E_SHIFT;
		end
		E_SHIFT: begin
			sh <= selv >>> job_shift;
			wb_valid <= 1'b1;
			estate <= E_PUSH;
		end
		E_PUSH: if (wb_ready) begin
			wb_valid <= 1'b0;
			if (row_end) begin
				rows_done <= rows_done + 1'b1;
				estate <= E_IDLE;
				if (job_end) wb_flush <= 1'b1;
			end else begin
				emit_t <= emit_t + 1'b1;
				estate <= E_SEL;
			end
		end
	endcase
end

// ---- counters ----
reg	[31:0]	cyc_busy = 0, cyc_starved = 0, cyc_stalled = 0, words = 0;
always @(posedge clk) begin
	if (!rst_n || clear_req) begin
		cyc_busy <= 0;
		cyc_starved <= 0;
		cyc_stalled <= 0;
		words <= 0;
	end else if (running) begin
		cyc_busy <= cyc_busy + 1'b1;
		if (want_pop && !s_valid) cyc_starved <= cyc_starved + 1'b1;
		if (want_pop && s_valid && stall) cyc_stalled <= cyc_stalled + 1'b1;
		if (pop) words <= words + 1'b1;
	end
end

// ---- the register file ----
always @(posedge clk) begin
	if (!rst_n) begin
		r_rows <= 0;
		r_k <= 11'd32;
		r_t <= 4'd1;
		r_shift <= 0;
		r_xaddr <= 0;
	end else if (wr) case (ridx)
		4'd0: r_rows <= reg_wdata[19:0];
		4'd1: r_k <= reg_wdata[10:0];
		4'd2: r_t <= reg_wdata[3:0];
		4'd3: r_shift <= reg_wdata[5:0];
		4'd8: r_xaddr <= reg_wdata[15:0];
		4'd9: r_xaddr <= r_xaddr + 16'd4;
		default: ;
	endcase
end

always @(posedge clk) begin
	if (!sel_me) reg_rdata <= 32'd0;
	else case (ridx)
		4'd0: reg_rdata <= {12'd0, r_rows};
		4'd1: reg_rdata <= {21'd0, r_k};
		4'd2: reg_rdata <= {28'd0, r_t};
		4'd3: reg_rdata <= {26'd0, r_shift};
		4'd5: reg_rdata <= {16'd0, 8'(T_MAX), 4'd0, aborted, lane_stalled, done, running};
		4'd6: reg_rdata <= cyc_busy;
		4'd7: reg_rdata <= cyc_starved;
		4'd8: reg_rdata <= {16'd0, r_xaddr};
		4'd10: reg_rdata <= {12'd0, rows_done};
		4'd11: reg_rdata <= cyc_stalled;
		4'd12: reg_rdata <= words;
		default: reg_rdata <= 32'd0;
	endcase
end

endmodule
