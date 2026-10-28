`default_nettype none
// SDRAM memory test engine on the burst controller: fill a range with a pattern, read it back, count and locate
// the errors, measure the clocks. Driven from the PC through 32 registers (lib/rtl/jtag_regs.sv): the read-window
// sweep of examples/15 (DRAM_CLK phase x rd_delay) and the throughput numbers come from here.
//
// A run is up to two passes over the words BASE .. BASE + LEN - 1 in bursts of BURST words: a write pass
// (MODE[0]) and a read pass (MODE[1]). Commands are pipelined: the next burst is offered as soon as the
// controller can take it, so the controller runs at its own full speed. The expected word of address a is
//   pattern 0  a[15:0] ^ a[24:9] ^ SEED[15:0]        (neighbours differ, rows differ: catches address faults)
//   pattern 1  SEED[15:0]                             (a constant: the quiet case)
//   pattern 2  xorshift32 stream from SEED            (pseudo-random: the noisy case; SEED 0 counts as 1)
//   pattern 3  a[0] ? ~SEED[15:0] : SEED[15:0]       (every bit toggles every word: the worst case for DQ)
// The write pass does not depend on rd_delay, so one write and several read-only passes sweep rd_delay.
//
// Registers (word index; W = written by the PC, R = read; a run starts by writing 1 to CTRL):
//   0  STATUS    R  [0] init_done  [1] running  [2] done  [3] pass  [10:8] rd_delay  [31:16] VERSION
//   1  CTRL      W  [0] start (clears the counters)  [1] abort (finish the bursts in flight, stop)
//   2  RD_DELAY  RW [2:0]  the controller's rd_delay (do not change while running)
//   3  BASE      RW [24:0] first word address
//   4  LEN       RW [25:0] words (0x200_0000 = all 64 MB)
//   5  BURST     RW [10:0] words per burst, 0 = 1024
//   6  MODE      RW [0] write pass  [1] read pass  [5:4] pattern
//   7  SEED      RW
//   8  ERRORS    R  words that read back wrong (saturates)
//   9  ERR_ADDR  R  address of the first wrong word
//  10  ERR_DATA  R  first wrong word: [31:16] expected, [15:0] got
//  11  ERR_BITS  R  [15:0] OR of got ^ expected over all wrong words (which DQ lines fail)
//  12  WR_CLOCKS R  clocks of the write pass, start to the last burst's done
//  13  RD_CLOCKS R  clocks of the read pass, start to the last word
//  14  WORDS     R  words checked in the read pass
//  15  REFRESHES R  refreshes issued during the run
//  16  BUSY_CLKS R  clocks with a word on the DQ bus during the run (bus use = BUSY_CLKS / clocks)
//  17  ERR_LAST  R  address of the last wrong word
//  18  WR_WORDS  R  words written in the write pass
// ***********************************************

module sdram_memtest #(
	parameter [15:0] VERSION = 16'h0001
)(
	input		wire				clk,
	input		wire				rst_n,
	// registers
	input		wire	[4:0]		reg_addr,
	input		wire	[31:0]	reg_wdata,
	input		wire				reg_we,
	output	reg	[31:0]	reg_rdata = 0,
	// burst controller
	output	reg	[2:0]		rd_delay = 3'd4,	// the value the board sweep found right at 100 MHz
	output	reg				cmd_valid = 0,
	input		wire				cmd_ready,
	output	reg				cmd_we = 0,
	output	reg	[24:0]	cmd_addr = 0,
	output	reg	[10:0]	cmd_len = 0,
	output	wire	[15:0]	wdata,
	output	wire				wvalid,
	input		wire				wready,
	input		wire	[15:0]	rdata,
	input		wire				rvalid,
	input		wire				done,
	input		wire				init_done,
	input		wire				stat_busy,
	input		wire				stat_refresh,
	// a glance for LEDs and HEX
	output	wire				running,
	output	wire				finished,
	output	wire				pass,
	output	reg	[31:0]	errors = 0
	);

// ---- settings ----
reg	[24:0]	base = 0;
reg	[25:0]	len = 26'd1024;
reg	[10:0]	burst = 11'd0;
reg	[5:0]		mode = 6'b000011;
reg	[31:0]	seed = 0;

// ---- run state ----
localparam [1:0]	S_IDLE = 2'd0, S_WRITE = 2'd1, S_READ = 2'd2, S_DONE = 2'd3;
reg	[1:0]		st = S_IDLE;
reg				abort = 0;
reg	[25:0]	to_issue = 0;							// words not yet offered to the controller
reg	[24:0]	issue_addr = 0;
reg	[25:0]	words_issued = 0, words_done = 0;	// words offered / words consumed or received, this pass
reg	[15:0]	bursts_issued = 0, bursts_done = 0;
wire	[10:0]	burst_words = (burst == 0) ? 11'd1024 : burst;
wire	[10:0]	next_len = (to_issue >= {15'd0, burst_words}) ? burst_words : to_issue[10:0];
wire				accepted = cmd_valid && cmd_ready;
wire				pass_we = (st == S_WRITE);
wire				pass_end = (to_issue == 0) &&
						(pass_we ? (bursts_done == bursts_issued) : (words_done == words_issued));

// ---- the expected stream: one generator, advanced per word written or received ----
reg	[24:0]	gen_a = 0;
reg	[31:0]	lfsr = 1;
wire	[31:0]	x1 = lfsr ^ (lfsr << 13);
wire	[31:0]	x2 = x1 ^ (x1 >> 17);
wire	[31:0]	lfsr_next = x2 ^ (x2 << 5);
reg	[15:0]	expected;
always @(*)
	case (mode[5:4])
		2'd0:		expected = gen_a[15:0] ^ gen_a[24:9] ^ seed[15:0];
		2'd1:		expected = seed[15:0];
		2'd2:		expected = lfsr[15:0];
		default:	expected = gen_a[0] ? ~seed[15:0] : seed[15:0];
	endcase
wire				advance = pass_we ? (wvalid && wready) : rvalid;
assign wdata = expected;
assign wvalid = pass_we;

// ---- counters ----
reg	[31:0]	wr_clocks = 0, rd_clocks = 0, words = 0, refreshes = 0, busy_clks = 0, wr_words = 0;
reg	[24:0]	err_addr = 0, err_last = 0;
reg	[31:0]	err_data = 0;
reg	[15:0]	err_bits = 0;
wire				mismatch = rvalid && (rdata != expected) && (st == S_READ);

assign running = (st == S_WRITE) || (st == S_READ);
assign finished = (st == S_DONE);
assign pass = (errors == 0);

// ---- register reads (one clock) ----
always @(posedge clk)
	case (reg_addr)
		5'd0:		reg_rdata <= {VERSION, 5'd0, rd_delay, 4'd0, pass, finished, running, init_done};
		5'd2:		reg_rdata <= {29'd0, rd_delay};
		5'd3:		reg_rdata <= {7'd0, base};
		5'd4:		reg_rdata <= {6'd0, len};
		5'd5:		reg_rdata <= {21'd0, burst};
		5'd6:		reg_rdata <= {26'd0, mode};
		5'd7:		reg_rdata <= seed;
		5'd8:		reg_rdata <= errors;
		5'd9:		reg_rdata <= {7'd0, err_addr};
		5'd10:	reg_rdata <= err_data;
		5'd11:	reg_rdata <= {16'd0, err_bits};
		5'd12:	reg_rdata <= wr_clocks;
		5'd13:	reg_rdata <= rd_clocks;
		5'd14:	reg_rdata <= words;
		5'd15:	reg_rdata <= refreshes;
		5'd16:	reg_rdata <= busy_clks;
		5'd17:	reg_rdata <= {7'd0, err_last};
		5'd18:	reg_rdata <= wr_words;
		default:	reg_rdata <= 32'd0;
	endcase

// ---- register writes and the run ----
wire start = reg_we && (reg_addr == 5'd1) && reg_wdata[0] && (st == S_IDLE || st == S_DONE) && init_done;

always @(posedge clk) begin
	if (reg_we)
		case (reg_addr)
			5'd1:		if (reg_wdata[1]) abort <= 1'b1;
			5'd2:		rd_delay <= reg_wdata[2:0];
			5'd3:		base <= reg_wdata[24:0];
			5'd4:		len <= reg_wdata[25:0];
			5'd5:		burst <= reg_wdata[10:0];
			5'd6:		mode <= reg_wdata[5:0];
			5'd7:		seed <= reg_wdata;
			default: ;
		endcase

	// the stream and its bookkeeping
	if (advance) begin
		gen_a <= gen_a + 1'b1;
		lfsr <= lfsr_next;
		words_done <= words_done + 1'b1;
	end
	if (accepted) begin
		cmd_valid <= 1'b0;
		to_issue <= to_issue - {15'd0, cmd_len};
		issue_addr <= issue_addr + {14'd0, cmd_len};
		words_issued <= words_issued + {15'd0, cmd_len};
		bursts_issued <= bursts_issued + 1'b1;
	end
	else if (running && !cmd_valid && to_issue != 0 && !abort) begin
		cmd_valid <= 1'b1;
		cmd_we <= pass_we;
		cmd_addr <= issue_addr;
		cmd_len <= next_len;
	end
	if (abort && !cmd_valid) to_issue <= 26'd0;	// stop offering; what is in flight completes
	if (done) bursts_done <= bursts_done + 1'b1;
	if (running) begin
		if (stat_refresh) refreshes <= refreshes + 1'b1;
		if (stat_busy) busy_clks <= busy_clks + 1'b1;
	end
	if (st == S_WRITE) begin
		wr_clocks <= wr_clocks + 1'b1;
		if (advance) wr_words <= wr_words + 1'b1;
	end
	if (st == S_READ) begin
		rd_clocks <= rd_clocks + 1'b1;
		if (rvalid) words <= words + 1'b1;
	end
	if (mismatch) begin
		if (errors != 32'hFFFF_FFFF) errors <= errors + 1'b1;
		if (errors == 0) begin
			err_addr <= gen_a;
			err_data <= {expected, rdata};
		end
		err_last <= gen_a;
		err_bits <= err_bits | (rdata ^ expected);
	end

	case (st)
		S_IDLE, S_DONE:
			if (start) begin
				errors <= 0; err_addr <= 0; err_last <= 0; err_data <= 0; err_bits <= 0;
				wr_clocks <= 0; rd_clocks <= 0; words <= 0; refreshes <= 0; busy_clks <= 0; wr_words <= 0;
				abort <= 1'b0;
				bursts_issued <= 0; bursts_done <= 0;
				st <= S_DONE;									// a run with no pass asked for ends at once
				if (mode[0]) st <= S_WRITE;
				else if (mode[1]) st <= S_READ;
				gen_a <= base;
				lfsr <= (seed == 0) ? 32'd1 : seed;
				issue_addr <= base;
				to_issue <= len;
				words_issued <= 0;
				words_done <= 0;
			end
		S_WRITE:
			if (pass_end) begin
				if (mode[1] && !abort) begin
					st <= S_READ;
					gen_a <= base;
					lfsr <= (seed == 0) ? 32'd1 : seed;
					issue_addr <= base;
					to_issue <= len;
					words_issued <= 0;
					words_done <= 0;
					bursts_issued <= 0;
					bursts_done <= 0;
				end
				else
					st <= S_DONE;
			end
		S_READ:
			if (pass_end) st <= S_DONE;
		default: st <= S_IDLE;
	endcase

	if (!rst_n) begin
		st <= S_IDLE;
		cmd_valid <= 1'b0;
		abort <= 1'b0;
		to_issue <= 26'd0;
	end
end

endmodule

`default_nettype wire
