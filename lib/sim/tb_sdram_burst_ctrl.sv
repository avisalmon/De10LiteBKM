// Testbench for sdram_burst_ctrl (lib/rtl/sdram_burst_ctrl.sv) against the SDRAM model, at 100 MHz with DRAM_CLK
// 45 degrees behind clk: the bare chip then puts its read word around the 3rd clock after the READ (rd_delay 3).
// Phases: the power-up time; the burst efficiency sweep (L = 1 .. 1024, 9 bursts back to back, writes then reads,
// the period per burst against the ideal L + 4 read / L + 5 write, refresh pauses allowed for); 400 random bursts
// (random lengths and addresses, bursts across row ends and bank ends, writes with random gaps in wvalid); then
// the model's memory against the reference, word by word. Fails on a data error, a protocol or timing error from
// the model, a wrong count of done pulses or read words, or a refresh interval out of range.
// The model keeps 64 rows per bank (256K words); the reference memory aliases rows the same way.
// python scripts/sim.py lib/sim/tb_sdram_burst_ctrl.sv                   (about 3 ms of simulated time)
// python scripts/sim.py lib/sim/tb_sdram_burst_ctrl.sv -D FAST_REFRESH   (a refresh every 97 clocks: pauses everywhere)
// sim-sources: lib/rtl/sdram_burst_ctrl.sv lib/sim/sdram_model.sv
`timescale 1ns/1ps

module tb_sdram_burst_ctrl;

localparam ROW_BITS = 6;
localparam WORDS = 4 << (ROW_BITS + 10);
`ifdef FAST_REFRESH
localparam REFRESH_CLOCKS = 97;
`else
localparam REFRESH_CLOCKS = 750;
`endif
`ifdef P_NS
localparam real P_NS = `P_NS;							// -D P_NS=2.5 : try another DRAM_CLK phase (ns behind clk)
`else
localparam real P_NS = 1.25;							// DRAM_CLK phase: 45 degrees of 10 ns (never 0: a race in simulation)
`endif
`ifdef RD_DELAY
localparam [2:0] RD_DELAY = `RD_DELAY;				// -D RD_DELAY=4 : try another sample clock
`else
localparam [2:0] RD_DELAY = 3'd3;
`endif
`ifdef DQ_DELAY
localparam real DQ_DELAY = `DQ_DELAY;				// -D DQ_DELAY=5 : the board's extra ns on the data path
`else
localparam real DQ_DELAY = 0.0;
`endif
`ifdef QUICK
localparam N_RANDOM = 30;								// -D QUICK : a short run, for sweeping phase and rd_delay
`else
localparam N_RANDOM = 400;
`endif

reg				clk = 0;
always #5 clk = ~clk;
reg				dram_clk = 0;
always @(clk) dram_clk <= #(P_NS) clk;
reg				rst_n = 0;

reg				cmd_valid = 0, cmd_we = 0;
reg	[24:0]	cmd_addr = 0;
reg	[10:0]	cmd_len = 0;
reg	[15:0]	wdata = 0;
reg				wvalid = 0;
wire				cmd_ready, wready, rvalid, done, init_done, stat_busy, stat_refresh;
wire	[15:0]	rdata;
wire	[12:0]	A;
wire	[1:0]		BA;
wire				cas_n, cke, cs_n, ras_n, we_n, ldqm, udqm;
wire	[15:0]	DQ;
integer			model_errors;

sdram_burst_ctrl #(.CLK_MHZ(100), .REFRESH_CLOCKS(REFRESH_CLOCKS)) dut(.clk(clk), .rst_n(rst_n), .rd_delay(RD_DELAY),
	.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
	.wdata(wdata), .wvalid(wvalid), .wready(wready), .rdata(rdata), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh),
	.DRAM_ADDR(A), .DRAM_BA(BA), .DRAM_CAS_N(cas_n), .DRAM_CKE(cke), .DRAM_CS_N(cs_n), .DRAM_DQ(DQ),
	.DRAM_LDQM(ldqm), .DRAM_RAS_N(ras_n), .DRAM_UDQM(udqm), .DRAM_WE_N(we_n));
sdram_model #(.ROW_BITS(ROW_BITS), .T_DQ_DELAY(DQ_DELAY)) mem(.dram_clk(dram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
	.we_n(we_n), .ba(BA), .a(A), .dq(DQ), .errors(model_errors));

// ---- reference memories, aliased like the model: {bank, row[ROW_BITS-1:0], col} ----
reg	[15:0]	shadow [0:WORDS-1];			// what the sequencer expects, written in command order
reg	[15:0]	ref_mem [0:WORDS-1];		// what the write producer actually delivered
function [ROW_BITS+11:0] aidx(input [24:0] a);
	aidx = {a[24:23], a[ROW_BITS+9:10], a[9:0]};
endfunction
function [15:0] pattern(input [24:0] a, input [15:0] g);
	pattern = a[15:0] ^ {a[24:16], 7'd0} ^ (g * 16'h9E37) ^ 16'h3C5A;
endfunction

// ---- write producer: bursts queued by the sequencer, delivered one word per clock, gaps when asked ----
reg	[24:0]	wq_addr [0:255];
reg	[10:0]	wq_len [0:255];
reg	[15:0]	wq_gen [0:255];
reg				wq_gaps [0:255];
integer			wq_head = 0, wq_tail = 0;
reg	[24:0]	wr_addr = 0;
reg	[15:0]	wr_gen = 0;
integer			wr_pending = 0;
reg				wr_gaps = 0;
integer			n_written = 0;
always @(negedge clk) begin
	if (wr_pending == 0 && wq_head != wq_tail) begin
		wr_addr = wq_addr[wq_head % 256];
		wr_pending = (wq_len[wq_head % 256] == 0) ? 1024 : wq_len[wq_head % 256];
		wr_gen = wq_gen[wq_head % 256];
		wr_gaps = wq_gaps[wq_head % 256];
		wq_head = wq_head + 1;
	end
	if (wr_pending != 0 && !(wr_gaps && ($urandom % 4 == 0))) begin
		wvalid = 1;
		wdata = pattern(wr_addr, wr_gen);
	end
	else begin
		wvalid = 0;
		wdata = 16'hxxxx;
	end
end
always @(posedge clk) if (wvalid && wready) begin
	ref_mem[aidx(wr_addr)] = wdata;
	wr_addr = wr_addr + 1'b1;
	wr_pending = wr_pending - 1;
	n_written = n_written + 1;
end

// ---- read checker: expected words queued by the sequencer, compared as rvalid delivers them ----
reg	[15:0]	rq_val [0:65535];
reg	[24:0]	rq_addr [0:65535];
integer			rq_head = 0, rq_tail = 0;
integer			errors = 0, n_read = 0, n_done = 0, n_refresh = 0, n_cmds = 0;
real				t_last_ref = -1.0, ref_gap_max = 0.0, ref_gap_min = 1.0e9;
always @(posedge clk) begin
	if (rvalid) begin
		if (rq_head == rq_tail) begin
			errors = errors + 1;
			if (errors <= 20) $display("%t ERROR: rvalid with nothing expected (rdata %h)", $time, rdata);
		end
		else begin
			if (rdata !== rq_val[rq_head % 65536]) begin
				errors = errors + 1;
				if (errors <= 20) $display("%t ERROR: addr %h read %h, expected %h", $time, rq_addr[rq_head % 65536], rdata, rq_val[rq_head % 65536]);
			end
			rq_head = rq_head + 1;
		end
		n_read = n_read + 1;
	end
	if (done) n_done = n_done + 1;
	if (stat_refresh) begin
		n_refresh = n_refresh + 1;
		if (t_last_ref >= 0.0) begin
			if ($realtime - t_last_ref > ref_gap_max) ref_gap_max = $realtime - t_last_ref;
			if ($realtime - t_last_ref < ref_gap_min) ref_gap_min = $realtime - t_last_ref;
		end
		t_last_ref = $realtime;
	end
end

// ---- the sequencer ----
reg	[15:0]	gen = 0;
real				t_accept;

// present a command, queue its words, wait for the controller to take it (the next command may follow at once)
task burst(input we, input [24:0] a, input [10:0] len, input gaps);
	integer n, i;
	begin
		n = (len == 0) ? 1024 : len;
		@(negedge clk);
		cmd_valid = 1;
		cmd_we = we;
		cmd_addr = a;
		cmd_len = len;
		gen = gen + 1'b1;
		if (we) begin
			for (i = 0; i < n; i = i + 1) shadow[aidx(a + i)] = pattern(a + i, gen);
			wq_addr[wq_tail % 256] = a;
			wq_len[wq_tail % 256] = len;
			wq_gen[wq_tail % 256] = gen;
			wq_gaps[wq_tail % 256] = gaps;
			wq_tail = wq_tail + 1;
		end
		else begin
			for (i = 0; i < n; i = i + 1) begin
				rq_val[rq_tail % 65536] = shadow[aidx(a + i)];
				rq_addr[rq_tail % 65536] = a + i;
				rq_tail = rq_tail + 1;
			end
		end
		@(posedge clk);
		while (!cmd_ready) @(posedge clk);
		t_accept = $realtime;
		n_cmds = n_cmds + 1;
		@(negedge clk);
		cmd_valid = 0;
	end
endtask

task wait_quiet;											// all data delivered, controller idle
	begin
		while (rq_head != rq_tail || wq_head != wq_tail || wr_pending != 0 || n_done != n_cmds) @(posedge clk);
		repeat (20) @(posedge clk);
	end
endtask

// 9 bursts of L words back to back: the period per burst, against the ideal, with the refresh pauses allowed for
task sweep(input we, input [10:0] len);
	integer k, n, nref0, clocks, ideal, allowed;
	real t0;
	begin
		n = (len == 0) ? 1024 : len;
		nref0 = n_refresh;
		for (k = 0; k < 9; k = k + 1) begin
			burst(we, k * n, len, 0);
			if (k == 0) t0 = t_accept;
		end
		clocks = (t_accept - t0) / 10.0 / 8.0;			// real to integer rounds
		ideal = we ? n + 5 : n + 4;
		if (ideal < 7) ideal = 7;								// tRC: an activate every 63 ns at least
		allowed = 8 * ideal + (n_refresh - nref0) * 13 + 8;
		$display("%s L = %4d: %6.1f clocks per burst, ideal %4d, %5.1f%% of the clocks carry data, %0d refreshes",
			we ? "write" : "read ", n, (t_accept - t0) / 80.0, ideal, 100.0 * n * 80.0 / (t_accept - t0), n_refresh - nref0);
		if ((t_accept - t0) / 10.0 > allowed) begin
			errors = errors + 1;
			$display("ERROR: %0d clocks for 8 bursts, allowed %0d", (t_accept - t0) / 10, allowed);
		end
		wait_quiet;
	end
endtask

integer			i, n, r, bad;
reg	[24:0]	a;
reg	[10:0]	len;
real				t_rst;

initial begin
	for (i = 0; i < WORDS; i = i + 1) begin			// the chip comes up with a known pattern, like a loaded memory
		mem.mem[i] = i[15:0] ^ 16'hA5C3;
		shadow[i] = i[15:0] ^ 16'hA5C3;
		ref_mem[i] = i[15:0] ^ 16'hA5C3;
	end
	repeat (3) @(negedge clk);
	rst_n = 1;
	t_rst = $realtime;
	@(posedge init_done);
	$display("init done %.1f us after reset", ($realtime - t_rst) / 1000.0);
	if ($realtime - t_rst < 105_000.0 || $realtime - t_rst > 107_000.0) begin
		errors = errors + 1;
		$display("ERROR: init time");
	end

	// 1. a few words by hand
	burst(1, 25'h0000000, 11'd4, 0);
	burst(0, 25'h0000000, 11'd4, 0);
	burst(1, 25'h1F003FE, 11'd5, 0);				// across a row end and into the next row
	burst(0, 25'h1F003FC, 11'd9, 0);
	wait_quiet;
	$display("directed bursts: %0d errors", errors);

	// 2. efficiency sweep
	sweep(1, 11'd1);    sweep(0, 11'd1);
	sweep(1, 11'd8);    sweep(0, 11'd8);
	sweep(1, 11'd32);   sweep(0, 11'd32);
	sweep(1, 11'd64);   sweep(0, 11'd64);
	sweep(1, 11'd128);  sweep(0, 11'd128);
`ifndef QUICK
	sweep(1, 11'd256);  sweep(0, 11'd256);
	sweep(1, 11'd512);  sweep(0, 11'd512);
	sweep(1, 11'd0);    sweep(0, 11'd1024);			// both spellings of 1024
`endif

	// 3. random bursts: lengths, addresses, row and bank ends, gaps in the write stream
	for (i = 0; i < N_RANDOM; i = i + 1) begin
		r = $urandom % 8;
		len = (r < 3) ? 1 + $urandom % 8 : (r < 5) ? 1 + $urandom % 64 : (r < 7) ? 1 + $urandom % 1024 : 0;
		a = $urandom;
		r = $urandom % 8;
		n = $urandom % 4;
		if (r == 0) a[9:0] = 10'd1023 - n[9:0];										// crosses the row end
		if (r == 1) a[22:0] = {13'h1FFF, 10'd1023 - n[9:0]};						// crosses the bank end
		if (r == 2 && i > 0) a = cmd_addr;											// the same place as the last burst
		burst(($urandom % 2) == 0, a, len, $urandom % 2);
	end
	burst(1, 25'h1FFFFFC, 11'd8, 0);						// over the end of memory: wraps to address 0
	burst(0, 25'h1FFFFFC, 11'd8, 0);
	wait_quiet;

	// 4. the model's memory against the reference
	bad = 0;
	for (i = 0; i < WORDS; i = i + 1) begin
		if (mem.mem[i] !== ref_mem[i] || shadow[i] !== ref_mem[i]) bad = bad + 1;
	end
	if (bad != 0) begin
		errors = errors + 1;
		$display("ERROR: %0d words differ between the SDRAM and the reference", bad);
	end
	if (n_read != rq_tail) begin
		errors = errors + 1;
		$display("ERROR: %0d read words delivered, %0d expected", n_read, rq_tail);
	end
	if (n_done != n_cmds) begin
		errors = errors + 1;
		$display("ERROR: %0d done pulses for %0d bursts", n_done, n_cmds);
	end
	if (ref_gap_max > 15_600.0 || ref_gap_min < REFRESH_CLOCKS * 10.0) begin
		errors = errors + 1;
		$display("ERROR: refresh interval %.2f .. %.2f us", ref_gap_min / 1000.0, ref_gap_max / 1000.0);
	end
	$display("%0d bursts, %0d words written, %0d words read, %0d refreshes (interval %.2f .. %.2f us), %0d errors, %0d model errors",
		n_cmds, n_written, n_read, n_refresh, ref_gap_min / 1000.0, ref_gap_max / 1000.0, errors, model_errors);
	if (errors == 0 && model_errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

initial begin
	#20_000_000;
	$display("FAIL: timeout");
	$finish;
end

endmodule
