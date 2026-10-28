// Burst SDRAM controller for the DE10-Lite's 64 MB SDRAM (IS42S16320D-7, 32M x 16: 4 banks x 8192 rows x 1024
// columns), one word per clock: the fast one (examples/15). The simple one-word-per-access controller is sdram_ctrl.sv.
//
// A command is a burst: cmd_we, cmd_addr (word address {bank[1:0], row[12:0], col[9:0]}), cmd_len words (1..1024,
// 0 means 1024). The controller opens the row (ACT), issues one READ or WRITE per clock (mode register: burst
// length 1, CAS latency 3: the controller makes the burst, not the chip), closes the row (PRE) and is ready for
// the next command. Read data comes out on rdata/rvalid with no backpressure, one word per clock, rd_delay + 1
// clocks after each READ; write data is taken from wdata when wvalid && wready (a clock without wvalid costs a
// clock). A burst that reaches column 1023 continues in the next row (or the next bank) by itself; a refresh that
// falls due inside a burst pauses it (PRE, AUTO REFRESH, ACT, go on). done pulses once per burst: with the last
// read word, or when the last write is committed (its PRE). cmd_ready goes high before a read burst's last data
// is out: count rvalid or use done to know whose data it is.
//
// Periods at 100 MHz: a read burst of L words takes L + 4 clocks, a write burst L + 5 (tWR); a 1-word access 7
// clocks; the refresh pause is about 12 clocks every 7.8 us; after a read burst a write burst waits rd_delay + 1
// clocks before its first WRITE so the chip has let go of the bus.
//
// rd_delay: the clock, counted from the READ command, on which the FPGA's input register samples DQ (2..6). It
// depends on the DRAM_CLK phase and the board: examples/15 sweeps it; a wrong value reads the neighbour word or 'x'.
// Timings come from the data sheet (tRCD 20 ns, tRP 20, tRAS 42, tRC 63, tRFC 63, tWR 2 clocks, tMRD 2) rounded up
// to clocks of CLK_MHZ, so the same RTL runs at 100, 83.3, 66.7 or 50 MHz.
// Pins: all outputs and the DQ input are plain registers so Quartus can put them in the I/O cells
// (FAST_OUTPUT_REGISTER, FAST_OUTPUT_ENABLE_REGISTER, FAST_INPUT_REGISTER, see examples/15/src/extra.qsf).
// DRAM_CLK comes from the PLL (same frequency, phase P).

module sdram_burst_ctrl #(
	parameter CLK_MHZ = 100,
	parameter REFRESH_CLOCKS = CLK_MHZ * 75 / 10,		// 7.5 us, plus the pause until the burst can stop: under the
																	// 7.8 us average of 8192 refreshes in 64 ms
	parameter INIT_US = 105										// power-up wait (data sheet 100 us)
)(
	input							clk,
	input							rst_n,				// synchronous; hold low until the PLL is locked
	input			[2:0]			rd_delay,
	// burst command
	input							cmd_valid,
	output						cmd_ready,
	input							cmd_we,
	input			[24:0]		cmd_addr,
	input			[10:0]		cmd_len,
	// write stream
	input			[15:0]		wdata,
	input							wvalid,
	output						wready,
	// read stream
	output reg		[15:0]	rdata = 0,
	output reg					rvalid = 0,
	output						done,
	output reg					init_done = 0,
	output reg					stat_busy = 0,		// a clock with a word on the bus
	output reg					stat_refresh = 0,	// a refresh issued
	// SDRAM pins
	output reg		[12:0]	DRAM_ADDR = 0,
	output reg		[1:0]		DRAM_BA = 0,
	output						DRAM_CAS_N,
	output						DRAM_CKE,
	output						DRAM_CS_N,
	inout			[15:0]		DRAM_DQ,
	output						DRAM_LDQM,
	output						DRAM_RAS_N,
	output						DRAM_UDQM,
	output						DRAM_WE_N
	);

// commands {CS_N, RAS_N, CAS_N, WE_N}
localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
                 C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
// mode register: burst length 1, sequential, CAS latency 3, standard operation, write burst = burst length
localparam [12:0] MODE = 13'b000_0_00_011_0_000;
// data-sheet times in clocks (rounded up); the "- 1" forms are what the counters are loaded with
localparam [15:0] T_INIT   = 16'(CLK_MHZ * INIT_US);
localparam [15:0] T_RP_CK  = 16'((20 * CLK_MHZ + 999) / 1000);		// precharge to activate
localparam [15:0] T_RCD_CK = 16'((20 * CLK_MHZ + 999) / 1000);		// activate to read/write
localparam [15:0] T_RFC_CK = 16'((63 * CLK_MHZ + 999) / 1000);		// refresh to the next command
localparam [15:0] T_RAS_CK = 16'((42 * CLK_MHZ + 999) / 1000);		// activate to precharge
localparam [15:0] T_RC_CK  = 16'((63 * CLK_MHZ + 999) / 1000);		// activate to activate, same bank
localparam [1:0] T_WR_CK  = 2'd2;											// last write data to precharge
localparam [15:0] T_MRD_CK = 16'd2;											// mode register set to the next command
// the ACT state lasts one clock by itself, so the first column command is 2 clocks after the ACT
localparam [15:0] T_ACT_WAIT = (T_RCD_CK > 16'd2) ? T_RCD_CK - 16'd2 : 16'd0;
// a row stays open at least this long, so that both tRAS and tRC (through the tRP that follows) are met
localparam [3:0] T_OPEN   = 4'((T_RC_CK - T_RP_CK > T_RAS_CK) ? T_RC_CK - T_RP_CK : T_RAS_CK);

localparam S_INIT = 0, S_INIT_REF = 1, S_INIT_MRS = 2, S_IDLE = 3, S_ACT = 4, S_ACCESS = 5, S_PRE = 6, S_RP = 7;

reg	[3:0]		cmd = C_NOP;
reg	[15:0]	dq_out = 0, dq_in = 0;
reg				dq_oe = 0;
reg	[2:0]		st = S_INIT;
reg	[15:0]	t = 0;						// wait counter: a command is issued when it reaches 0
reg	[3:0]		nref = 0;
reg	[15:0]	refi = 0;
reg				ref_due = 0;
reg				r_we = 0;
reg	[24:0]	r_addr = 0;					// address of the next word of the burst
reg	[10:0]	rem = 0;						// words still to issue
reg	[1:0]		cur_ba = 0;					// the open bank (r_addr may already point into the next one)
reg	[3:0]		ras_cnt = 0;				// clocks until the open row may be precharged
reg	[1:0]		wr_cnt = 0;					// clocks until the last write is recovered (tWR)
reg	[2:0]		rd_dq = 0;					// clocks until the chip has let go of DQ after a READ
reg	[7:0]		rd_pipe = 0, last_pipe = 0;	// one bit per READ issued, travelling to its sample clock
reg				rd_done = 0, wr_done = 0;

assign {DRAM_CS_N, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N} = cmd;
assign DRAM_CKE = 1'b1;
assign DRAM_LDQM = 1'b0;
assign DRAM_UDQM = 1'b0;
assign DRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
assign done = rd_done | wr_done;

wire last_word = (rem == 11'd1);
wire row_end   = &r_addr[9:0];
assign cmd_ready = (st == S_IDLE) && init_done && !ref_due && (t == 0);
assign wready    = (st == S_ACCESS) && r_we && !ref_due;
wire   access    = (st == S_ACCESS) && !ref_due && (!r_we || wvalid);

always @(posedge clk) begin
	cmd <= C_NOP;
	dq_oe <= 0;
	rvalid <= 0;
	rd_done <= 0;
	wr_done <= 0;
	stat_busy <= 0;
	stat_refresh <= 0;
	dq_in <= DRAM_DQ;
	rd_pipe <= {rd_pipe[6:0], 1'b0};
	last_pipe <= {last_pipe[6:0], 1'b0};
	if (rd_pipe[rd_delay]) begin
		rdata <= dq_in;
		rvalid <= 1;
		rd_done <= last_pipe[rd_delay];
	end
	if (t != 0) t <= t - 1'b1;
	if (ras_cnt != 0) ras_cnt <= ras_cnt - 1'b1;
	if (wr_cnt != 0) wr_cnt <= wr_cnt - 1'b1;
	if (rd_dq != 0) rd_dq <= rd_dq - 1'b1;
	if (init_done) begin
		if (refi != 16'hFFFF) refi <= refi + 1'b1;
		if (refi >= REFRESH_CLOCKS) ref_due <= 1;
	end

	if (!rst_n) begin
		st <= S_INIT;
		t <= T_INIT;
		init_done <= 0;
		ref_due <= 0;
		refi <= 0;
		rd_pipe <= 0;
		last_pipe <= 0;
		rem <= 0;
	end
	else case (st)
		S_INIT: if (t == 0) begin
			cmd <= C_PRE;
			DRAM_ADDR <= 13'h400;						// A10: all banks
			t <= T_RP_CK - 1'b1;
			nref <= 8;
			st <= S_INIT_REF;
		end
		S_INIT_REF: if (t == 0) begin
			if (nref != 0) begin
				cmd <= C_REF;
				nref <= nref - 1'b1;
				t <= T_RFC_CK - 1'b1;
			end
			else begin
				cmd <= C_MRS;
				DRAM_ADDR <= MODE;
				DRAM_BA <= 2'b00;
				t <= T_MRD_CK - 1'b1;
				st <= S_INIT_MRS;
			end
		end
		S_INIT_MRS: if (t == 0) begin
			init_done <= 1;
			refi <= 0;
			st <= S_IDLE;
		end
		S_IDLE: if (t == 0) begin
			if (ref_due) begin
				cmd <= C_REF;
				refi <= 0;
				ref_due <= 0;
				stat_refresh <= 1;
				t <= T_RFC_CK - 1'b1;
			end
			else if (cmd_valid) begin					// accepted: cmd_ready is true here
				r_we <= cmd_we;
				r_addr <= cmd_addr;
				rem <= (cmd_len == 0) ? 11'd1024 : cmd_len;
				cmd <= C_ACT;
				DRAM_BA <= cmd_addr[24:23];
				DRAM_ADDR <= cmd_addr[22:10];
				cur_ba <= cmd_addr[24:23];
				ras_cnt <= T_OPEN - 1'b1;
				t <= T_ACT_WAIT;
				st <= S_ACT;
			end
		end
		S_ACT: if (t == 0 && (!r_we || rd_dq == 0)) st <= S_ACCESS;
		S_ACCESS: begin
			if (ref_due) st <= S_PRE;					// pause: close the row, refresh, open it again
			else if (access) begin
				cmd <= r_we ? C_WRITE : C_READ;
				DRAM_ADDR <= {3'b000, r_addr[9:0]};	// A10 = 0: no auto-precharge
				DRAM_BA <= cur_ba;
				dq_out <= wdata;
				dq_oe <= r_we;
				if (r_we)
					wr_cnt <= T_WR_CK - 1'b1;
				else begin
					rd_pipe[0] <= 1'b1;
					last_pipe[0] <= last_word;
					rd_dq <= rd_delay + 1'b1;
				end
				stat_busy <= 1;
				rem <= rem - 1'b1;
				r_addr <= r_addr + 1'b1;
				if (last_word || row_end) st <= S_PRE;
			end
		end
		S_PRE: if (ras_cnt == 0 && wr_cnt == 0) begin
			cmd <= C_PRE;
			DRAM_BA <= cur_ba;
			DRAM_ADDR <= 13'd0;							// A10 = 0: this bank only
			t <= T_RP_CK - 1'b1;
			if (rem == 0) begin
				st <= S_IDLE;
				wr_done <= r_we;
			end
			else
				st <= S_RP;
		end
		S_RP: if (t == 0) begin							// the burst goes on: refresh first if one is due
			if (ref_due) begin
				cmd <= C_REF;
				refi <= 0;
				ref_due <= 0;
				stat_refresh <= 1;
				t <= T_RFC_CK - 1'b1;
			end
			else begin
				cmd <= C_ACT;
				DRAM_BA <= r_addr[24:23];
				DRAM_ADDR <= r_addr[22:10];
				cur_ba <= r_addr[24:23];
				ras_cnt <= T_OPEN - 1'b1;
				t <= T_ACT_WAIT;
				st <= S_ACT;
			end
		end
		default: st <= S_IDLE;
	endcase
end

endmodule
