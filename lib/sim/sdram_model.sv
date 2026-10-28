// Behavioral model of the DE10-Lite SDRAM (IS42S16320D-7, 32M x 16, 4 banks) for testbenches.
//
// Decodes every command on the rising edge of dram_clk: MRS, ACT, READ, WRITE (burst length 1, with or without
// auto-precharge), PRE (one bank or all), AUTO REFRESH. Keeps the row state of the 4 banks and the mode register.
// Read data is driven only in its valid window, as the data sheet defines it (JEDEC): for CAS latency CL the word of
// a READ registered at edge T0 is driven from edge T(CL-1) + tAC (5.4 ns) until edge T(CL) + tOH (2.7 ns), then 'x'
// until the chip lets go of the bus at T(CL) + tHZ (5.4 ns). A controller that samples at the wrong edge reads 'x'.
// On the real board the DRAM_CLK pin and the data return path add a few ns on top of this; T_DQ_DELAY models that
// if a testbench wants to (default 0: the bare chip; the board's window is measured in examples/15).
//
// Checks (each one counts in `errors` and prints the first 20): a command before the mode register is set, ACT to an
// open bank, READ/WRITE to a closed bank, REFRESH or MRS with an open bank, and the data-sheet timings tRCD, tRP,
// tRC, tRRD, tRAS min and max, tWR (2 clocks) before a precharge, tRFC, tMRD, and the refresh interval (no gap
// longer than 2 x 7.8 us once the mode register is set). CHECK_TIMING = 0 switches the timing checks off.
//
// Storage: {bank, row[ROW_BITS-1:0], col}: rows alias modulo 2^ROW_BITS (the default 4 keeps the old 64K words;
// 8 is 1M words = 2 MB of simulator memory). A testbench's reference memory must alias the same way.
`timescale 1ns/1ps

module sdram_model #(
	parameter ROW_BITS = 4,
	parameter CHECK_TIMING = 1,
	parameter real T_DQ_DELAY = 0.0,		// extra delay on the data out (board: clock pin + trace + pad), ns
	parameter real T_AC = 5.4, T_OH = 2.7, T_HZ = 5.4,
	parameter real T_RCD = 20.0, T_RP = 20.0, T_RC = 63.0, T_RRD = 14.0, T_RAS = 42.0, T_RAS_MAX = 100_000.0,
	parameter real T_RFC = 63.0, T_REFI_MAX = 15_600.0,
	parameter integer T_WR_CK = 2, T_MRD_CK = 2
)(
	input					dram_clk,
	input					cke, cs_n, ras_n, cas_n, we_n,
	input		[1:0]		ba,
	input		[12:0]	a,
	inout		[15:0]	dq,
	output integer		errors
	);

localparam WORDS = 4 << (ROW_BITS + 10);
reg	[15:0]	mem [0:WORDS-1];
reg	[12:0]	open_row [0:3];
reg	[3:0]		is_open = 0;
reg				mode_set = 0;
integer			cl = 3;
real				t_act [0:3];			// time of the ACT that opened the bank
real				t_ready [0:3];			// time the bank may be activated again (precharge done)
real				t_wr [0:3];				// time of the last write to the bank
reg	[3:0]		ras_max_said = 0;
real				t_ref_ready = -1.0, t_mrd_ready = -1.0, t_last_ref = -1.0;
real				t_prev_edge = -1.0, tck = 10.0;
real				now;
integer			drivers = 0;			// read words currently driving dq (1 during a burst, 2 at a hand-over)
reg	[15:0]	dq_drive = 16'hxxxx;
integer			i, idx;
initial errors = 0;
initial for (i = 0; i < 4; i = i + 1) begin t_act[i] = -1.0e9; t_ready[i] = -1.0; t_wr[i] = -1.0e9; end
assign dq = (drivers != 0) ? dq_drive : 16'hzzzz;

task fail(input string what);
	begin
		errors = errors + 1;
		if (errors <= 20) $display("%t sdram_model ERROR: %s", $time, what);
	end
endtask

// precharge of one bank: tRAS min and tWR must be met, then tRP until the bank can be activated again
task precharge(input integer b, input string by);
	begin
		if (is_open[b]) begin
			if (CHECK_TIMING && now - t_act[b] < T_RAS - 0.01)
				fail($sformatf("%s bank %0d: tRAS %.1f ns after ACT (min %.1f)", by, b, now - t_act[b], T_RAS));
			if (CHECK_TIMING && now - t_wr[b] < T_WR_CK * tck - 0.01)
				fail($sformatf("%s bank %0d: %.1f ns after the last WRITE (tWR %0d clocks)", by, b, now - t_wr[b], T_WR_CK));
		end
		is_open[b] = 0;
		if (now + T_RP > t_ready[b]) t_ready[b] = now + T_RP;
	end
endtask

// one read word: driven from edge T(CL-1) + tAC, 'x' from edge T(CL) + tOH, bus let go at T(CL) + tHZ
// (the extra T_DQ_DELAY shifts the data, not the edges, so a large delay still holds for one clock only)
task automatic read_word(input [15:0] v, input integer lat);
	begin
		repeat (lat - 1) @(posedge dram_clk);
		fork
			begin
				#(T_AC + T_DQ_DELAY);
				drivers = drivers + 1;
				dq_drive = v;
			end
			begin
				@(posedge dram_clk);
				#(T_OH + T_DQ_DELAY) dq_drive = 16'hxxxx;
				#(T_HZ - T_OH) drivers = drivers - 1;
			end
		join
	end
endtask

always @(posedge dram_clk) begin
	now = $realtime;
	if (t_prev_edge >= 0.0) tck = now - t_prev_edge;
	t_prev_edge = now;
	// a row open for too long (tRAS max) is a design bug: the row's charge leaks away
	for (i = 0; i < 4; i = i + 1)
		if (CHECK_TIMING && is_open[i] && !ras_max_said[i] && now - t_act[i] > T_RAS_MAX) begin
			ras_max_said[i] = 1;
			fail($sformatf("bank %0d open for %.1f us (tRAS max %.1f us)", i, (now - t_act[i]) / 1000.0, T_RAS_MAX / 1000.0));
		end
	if (cke && !cs_n) case ({ras_n, cas_n, we_n})
		3'b000: begin																// MRS
			if (is_open != 0) fail("MRS with an open bank");
			if (CHECK_TIMING && (now < t_ref_ready - 0.01)) fail("MRS inside tRFC");
			for (i = 0; i < 4; i = i + 1) if (CHECK_TIMING && now < t_ready[i] - 0.01) fail("MRS inside tRP");
			if (a[2:0] != 3'b000) fail($sformatf("mode register burst length code %0d: the model supports BL 1 only", a[2:0]));
			if (a[6:4] != 3'd2 && a[6:4] != 3'd3) fail($sformatf("mode register CAS latency code %0d", a[6:4]));
			cl = a[6:4];
			mode_set = 1;
			t_mrd_ready = now + T_MRD_CK * tck;
		end
		3'b011: begin																// ACT
			if (!mode_set) fail("ACT before the mode register is set");
			if (is_open[ba]) fail($sformatf("ACT to bank %0d which is already open", ba));
			if (CHECK_TIMING) begin
				if (now < t_ready[ba] - 0.01) fail($sformatf("ACT bank %0d inside tRP (%.1f ns early)", ba, t_ready[ba] - now));
				if (now - t_act[ba] < T_RC - 0.01) fail($sformatf("ACT bank %0d: tRC %.1f ns (min %.1f)", ba, now - t_act[ba], T_RC));
				for (i = 0; i < 4; i = i + 1)
					if (i != ba && now - t_act[i] < T_RRD - 0.01) fail($sformatf("ACT bank %0d: tRRD %.1f ns after bank %0d", ba, now - t_act[i], i));
				if (now < t_ref_ready - 0.01) fail("ACT inside tRFC");
				if (now < t_mrd_ready - 0.01) fail("ACT inside tMRD");
			end
			open_row[ba] = a;
			is_open[ba] = 1;
			ras_max_said[ba] = 0;
			t_act[ba] = now;
			t_wr[ba] = -1.0e9;
		end
		3'b010: begin																// PRE (A10: all banks)
			if (a[10]) for (i = 0; i < 4; i = i + 1) precharge(i, "PRE ALL");
			else precharge(ba, "PRE");
		end
		3'b001: begin																// AUTO REFRESH
			if (is_open != 0) fail("REFRESH with an open bank");
			if (CHECK_TIMING) begin
				for (i = 0; i < 4; i = i + 1) if (now < t_ready[i] - 0.01) fail("REFRESH inside tRP");
				if (now < t_ref_ready - 0.01) fail("REFRESH inside tRFC");
				if (now < t_mrd_ready - 0.01) fail("REFRESH inside tMRD");
				if (mode_set && t_last_ref >= 0.0 && now - t_last_ref > T_REFI_MAX)
					fail($sformatf("%.1f us since the last REFRESH (limit %.1f us)", (now - t_last_ref) / 1000.0, T_REFI_MAX / 1000.0));
			end
			t_last_ref = now;
			t_ref_ready = now + T_RFC;
		end
		3'b100, 3'b101: begin														// WRITE / READ
			if (!mode_set || !is_open[ba]) fail($sformatf("%s to bank %0d not ready", we_n ? "READ" : "WRITE", ba));
			else if (CHECK_TIMING) begin
				if (now - t_act[ba] < T_RCD - 0.01) fail($sformatf("%s bank %0d: tRCD %.1f ns (min %.1f)", we_n ? "READ" : "WRITE", ba, now - t_act[ba], T_RCD));
				if (now < t_mrd_ready - 0.01) fail("READ/WRITE inside tMRD");
			end
			idx = {ba, open_row[ba][ROW_BITS-1:0], a[9:0]};
			if (!we_n) begin
				mem[idx] = dq;
				t_wr[ba] = now;
				if (a[10]) begin												// auto-precharge after tWR: the controller must still respect tRAS
					if (CHECK_TIMING && now + T_WR_CK * tck - t_act[ba] < T_RAS - 0.01) fail("WRITE with auto-precharge would precharge before tRAS min");
					is_open[ba] = 0;
					t_ready[ba] = now + T_WR_CK * tck + T_RP;
				end
			end
			else begin
				fork
					read_word(mem[idx], cl);
				join_none
				if (a[10]) begin												// auto-precharge at the end of the (1-word) burst
					if (CHECK_TIMING && now + tck - t_act[ba] < T_RAS - 0.01) fail("READ with auto-precharge would precharge before tRAS min");
					is_open[ba] = 0;
					t_ready[ba] = now + tck + T_RP;
				end
			end
		end
		default: ;																	// NOP (and the unused combination 110)
	endcase
end

endmodule
