// Unit test: sdram_loader + sdram_ctrl + the SDRAM model, the JTAG side driven the way the USB-Blaster drives it
// (TCK 6 MHz, asynchronous to the 50 MHz clock, back-to-back scans with the shortest gap the TAP allows).
// Writes 700 words in 6 scans of different lengths, checks STATUS (count, CRC32 = zlib's), reads them back in
// 4 scans, restarts reading in the middle (a stale word waits in the mailbox), writes a second block across a row
// boundary, catches a READ without RADDR (underrun) and a write while the SDRAM port is held busy (FIFO overflow),
// and CRCs both blocks on the board (CHECK) while polling STATUS without IR scans.
// python scripts/sim.py lib/sim/tb_sdram_loader.sv -D SDRAM_LOADER_SIM
// sim-sources: lib/rtl/sdram_ctrl.sv lib/rtl/sdram_loader.sv lib/sim/sdram_model.sv
`timescale 1ns/1ps

module tb_sdram_loader;

`ifndef TCK_HALF
`define TCK_HALF 83.333			// 6 MHz, the USB-Blaster's TCK
`endif
localparam real HALF = `TCK_HALF;
localparam [3:0] IR_WADDR = 1, IR_WRITE = 2, IR_RADDR = 3, IR_READ = 4, IR_STATUS = 5, IR_CHECK = 6;

reg				clk = 0, reset_n = 0;
always #10 clk = ~clk;
wire				dram_clk = ~clk;

wire				req, we, ready, rvalid, init_done;
wire	[24:0]	addr;
wire	[15:0]	wdata, rdata;
wire	[12:0]	A;
wire	[1:0]		BA;
wire				cas_n, cke, cs_n, ras_n, we_n, ldqm, udqm;
wire	[15:0]	DQ;
integer			model_errors;
wire	[31:0]	written;
wire				reading, check_busy, busy, error;

reg				tck = 0, tdi = 0, cdr = 0, sdr = 0, udr = 0, uir = 0;
reg				stall = 0;			// holds the SDRAM port busy, as another master would, to overflow the write FIFO
reg	[3:0]		ir_in = 0, ir_next = 0;
wire				tdo;
always @(posedge tck) if (uir) ir_in <= ir_next;		// the hub updates ir_in on the UIR edge

sdram_ctrl #(.CLK_MHZ(50), .READ_DELAY(4)) ctrl(.clk(clk), .reset_n(reset_n), .rd_delay(3'd4), .req(req), .we(we),
	.addr(addr), .wdata(wdata), .ready(ready), .rvalid(rvalid), .rdata(rdata), .init_done(init_done),
	.DRAM_ADDR(A), .DRAM_BA(BA), .DRAM_CAS_N(cas_n), .DRAM_CKE(cke), .DRAM_CS_N(cs_n), .DRAM_DQ(DQ),
	.DRAM_LDQM(ldqm), .DRAM_RAS_N(ras_n), .DRAM_UDQM(udqm), .DRAM_WE_N(we_n));
sdram_model mem(.dram_clk(dram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
	.ba(BA), .a(A), .dq(DQ), .errors(model_errors));
sdram_loader dut(.clk(clk), .reset_n(reset_n), .req(req), .we(we), .addr(addr), .wdata(wdata), .ready(ready && !stall),
	.rvalid(rvalid), .rdata(rdata), .init_done(init_done), .user0(32'h12345678), .user1(32'h9ABCDEF0),
	.words_written(written), .reading(reading), .check_busy(check_busy), .busy(busy), .error(error),
	.sim_tck(tck), .sim_tdi(tdi), .sim_ir_in(ir_in), .sim_cdr(cdr), .sim_sdr(sdr), .sim_udr(udr), .sim_uir(uir),
	.sim_tdo(tdo));

integer			errors = 0;
reg	[15:0]	data [0:999];			// what the PC sends: block A = 0..699, block B = 700..999
reg	[15:0]	back [0:999];			// what comes back
reg	[31:0]	st [0:9];				// STATUS words
integer			i, n, t;

task fail(input [8*80-1:0] what, input [31:0] got, input [31:0] want);
	begin
		errors = errors + 1;
		$display("FAIL: %0s: got %h, want %h", what, got, want);
	end
endtask

// ---- the JTAG side, one TAP state per TCK edge ----
task edge_;					// one TCK period: the posedge acts on the signals set before it
	begin
		#(HALF) tck = 1;
		#(HALF) tck = 0;
	end
endtask

task set_ir(input [3:0] v);	// a virtual IR scan: USER1 IR + DR scans, then the IR scan back to USER0
	begin
		repeat (20) edge_;
		ir_next = v;
		uir = 1; edge_; uir = 0;
		repeat (14) edge_;
	end
endtask

task dr_begin;					// Select-DR, Capture-DR
	begin
		edge_;
		cdr = 1; edge_; cdr = 0;
		sdr = 1;
	end
endtask

task dr_end;					// Exit1-DR, Update-DR, then straight to Select-DR (the shortest gap)
	begin
		sdr = 0; edge_;
		udr = 1; edge_; udr = 0;
	end
endtask

task shift_bit(input b, output o);
	begin
		tdi = b;
		#(HALF) o = tdo;		// what the hub's TDO register holds at this posedge
		tck = 1;
		#(HALF) tck = 0;
	end
endtask

task cmd64(input [3:0] op, input [63:0] v);
	reg o;
	integer k;
	begin
		set_ir(op);
		dr_begin;
		for (k = 0; k < 64; k = k + 1) shift_bit(v[k], o);
		dr_end;
	end
endtask

task write_scan(input integer first, input integer count);	// one WRITE scan: data[first .. first+count-1]
	reg o;
	integer k, b;
	begin
		dr_begin;
		for (k = first; k < first + count; k = k + 1)
			for (b = 0; b < 16; b = b + 1) shift_bit(data[k][b], o);
		dr_end;
	end
endtask

task read_scan(input integer first, input integer count);	// one READ scan into back[first ..]
	reg o;
	integer k, b;
	begin
		dr_begin;
		for (k = first; k < first + count; k = k + 1)
			for (b = 0; b < 16; b = b + 1) begin
				shift_bit(1'b0, o);
				back[k][b] = o;
			end
		dr_end;
	end
endtask

task status_scan;				// one STATUS scan; the IR must already be STATUS
	reg o;
	integer k;
	begin
		dr_begin;
		for (k = 0; k < 320; k = k + 1) begin
			shift_bit(1'b0, o);
			st[k / 32][k % 32] = o;
		end
		dr_end;
	end
endtask

task status;
	begin
		set_ir(IR_STATUS);
		status_scan;
	end
endtask

// ---- the expected CRC32: zlib's, byte by byte (a different form from the DUT's 16-bit step) ----
function [31:0] crc8(input [31:0] c, input [7:0] b);
	integer k;
	reg [31:0] x;
	begin
		x = c ^ {24'd0, b};
		for (k = 0; k < 8; k = k + 1) x = x[0] ? ({1'b0, x[31:1]} ^ 32'hEDB88320) : {1'b0, x[31:1]};
		crc8 = x;
	end
endfunction

function [31:0] crc_words(input integer first, input integer count);
	integer k;
	reg [31:0] c;
	begin
		c = 32'hFFFFFFFF;
		for (k = first; k < first + count; k = k + 1) c = crc8(crc8(c, data[k][7:0]), data[k][15:8]);
		crc_words = ~c;
	end
endfunction

task compare(input integer first, input integer count, input integer offset);	// back[first..] vs data[first+offset..]
	integer k;
	begin
		for (k = first; k < first + count; k = k + 1)
			if (back[k] !== data[k + offset]) begin
				errors = errors + 1;
				if (errors < 6) $display("FAIL: word %0d read %h, wrote %h", k + offset, back[k], data[k + offset]);
			end
	end
endtask

task wait_check(input [31:0] want_crc, input [31:0] want_words);	// polls with STATUS scans only (no IR scan)
	begin
		t = 0;
		status;
		while (!st[1][4] && t < 50) begin status_scan; t = t + 1; end
		if (!st[1][4]) fail("check never finished (status not refreshed by scans?)", st[1], 32'h10);
		if (st[6] !== want_crc) fail("check CRC32", st[6], want_crc);
		if (st[7] !== want_words) fail("words checked", st[7], want_words);
		$display("check %0d words: CRC32 %h after %0d polls", want_words, st[6], t);
	end
endtask

localparam [24:0] BASE_A = 25'h00003A0, BASE_B = 25'h0002E80, BASE_C = 25'h0001000;	// B crosses row 11 into 12

initial begin
	// the reference CRC itself: CRC32("123456789") = CBF43926
	begin : known
		reg [31:0] c;
		reg [8*9-1:0] s;
		s = "123456789";
		c = 32'hFFFFFFFF;
		for (i = 8; i >= 0; i = i - 1) c = crc8(c, s[8*i +: 8]);
		if (~c !== 32'hCBF43926) fail("reference CRC32", ~c, 32'hCBF43926);
	end
	for (i = 0; i < 1000; i = i + 1) data[i] = $random;
	repeat (5) @(posedge clk);
	reset_n = 1;

	status;
	if (st[0] !== 32'h53444C44) fail("magic", st[0], 32'h53444C44);
	if (st[1][15:8] !== 8'd1) fail("version", st[1][15:8], 1);
	if (st[8] !== 32'h12345678 || st[9] !== 32'h9ABCDEF0) fail("user words", st[8], 32'h12345678);
	t = 0;
	while (!st[1][0] && t < 200) begin status; t = t + 1; end
	if (!st[1][0]) fail("init_done", st[1], 1);

	// block A: 700 words in scans of 1, 7, 64, 128, 300, 200 words (one IR, back-to-back scans)
	cmd64(IR_WADDR, BASE_A);
	set_ir(IR_WRITE);
	write_scan(0, 1); write_scan(1, 7); write_scan(8, 64); write_scan(72, 128); write_scan(200, 300); write_scan(500, 200);
	status;
	if (st[2] !== 700) fail("words written", st[2], 700);
	if (st[4] !== 700) fail("words received", st[4], 700);
	if (st[3] !== crc_words(0, 700)) fail("write CRC32", st[3], crc_words(0, 700));
	if (st[1][5]) fail("write overflow", st[1], 0);
	if (!st[1][1]) fail("write FIFO not empty", st[1], 2);
	$display("block A: 700 words written, CRC32 %h, FIFO high-water %0d", st[3], st[1][20:16]);

	// read it back in 4 scans
	cmd64(IR_RADDR, BASE_A);
	set_ir(IR_READ);
	read_scan(0, 3); read_scan(3, 100); read_scan(103, 297); read_scan(400, 300);
	compare(0, 700, 0);
	status;
	if (st[5] !== 700) fail("words sent", st[5], 700);
	if (st[1][6]) fail("read underrun", st[1], 0);

	// restart in the middle: the mailbox still holds word 700's place (a stale word) and must be replaced
	cmd64(IR_RADDR, BASE_A + 123);
	set_ir(IR_READ);
	read_scan(0, 50);
	compare(0, 50, 123);
	status;
	if (st[1][6]) fail("read underrun after restart", st[1], 0);

	// block B, across a row boundary
	cmd64(IR_WADDR, BASE_B);
	set_ir(IR_WRITE);
	write_scan(700, 150); write_scan(850, 150);
	status;
	if (st[2] !== 300) fail("block B words written", st[2], 300);
	if (st[3] !== crc_words(700, 300)) fail("block B write CRC32", st[3], crc_words(700, 300));
	if (st[1][2]) fail("WADDR did not close the read stream", st[1], 0);

	// READ without RADDR after a write: nothing refills the mailbox, so the board must flag an underrun
	set_ir(IR_READ);
	read_scan(0, 2);
	status;
	if (!st[1][6] || !error) fail("underrun not flagged", st[1], 32'h40);

	cmd64(IR_RADDR, BASE_B);
	set_ir(IR_READ);
	read_scan(700, 300);
	compare(700, 300, 0);
	status;
	if (st[1][6] || error) fail("RADDR did not clear the underrun", st[1], 0);

	// the SDRAM port held busy for 20 words: the 16-word FIFO keeps 16, flags the overflow, writes 16 when free
	stall = 1;
	cmd64(IR_WADDR, BASE_C);
	set_ir(IR_WRITE);
	write_scan(0, 20);
	status;
	if (st[4] !== 20) fail("words received while stalled", st[4], 20);
	if (st[2] !== 0) fail("words written while stalled", st[2], 0);
	if (st[1][20:16] !== 16) fail("FIFO high-water", st[1][20:16], 16);
	if (!st[1][5] || !error) fail("overflow not flagged", st[1], 32'h20);
	stall = 0;
	status;
	if (st[2] !== 16) fail("words written after the stall", st[2], 16);
	if (st[3] !== crc_words(0, 16)) fail("CRC32 after the stall", st[3], crc_words(0, 16));
	cmd64(IR_WADDR, BASE_C);
	status;
	if (st[1][5] || error) fail("WADDR did not clear the overflow", st[1], 0);

	// the board CRCs both blocks by itself
	cmd64(IR_CHECK, {32'd700, 7'd0, BASE_A});
	wait_check(crc_words(0, 700), 700);
	cmd64(IR_CHECK, {32'd300, 7'd0, BASE_B});
	wait_check(crc_words(700, 300), 300);
	cmd64(IR_CHECK, {32'd0, 7'd0, BASE_B});
	wait_check(32'h00000000, 0);

	if (error) fail("error output", error, 0);
	$display("1020 words in, 1052 out, 3 checks, overflow and underrun caught; %0d errors, %0d protocol errors",
	         errors, model_errors);
	if (errors == 0 && model_errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

initial begin #60_000_000; $display("FAIL: timeout"); $finish; end

endmodule
