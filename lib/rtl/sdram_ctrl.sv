// SDRAM controller for the DE10-Lite's 64 MB SDRAM (IS42S16320, 32M x 16: 4 banks, 8192 rows, 1024 columns)
//
// Simple and safe, not fast: one 16-bit word per request, every access opens the row and closes it again
// (READ/WRITE with auto-precharge), refresh every 7.8 us. Runs at 50 MHz; drive DRAM_CLK with the same clock
// shifted 180 degrees (the SDRAM samples in the middle of our clock: ~10 ns of setup and hold margin).
//   Request: when ready, raise req with we/addr/wdata for one clock (it is latched). Read data: rvalid + rdata.
//   addr = {bank[1:0], row[12:0], col[9:0]} (25 bits = 32M words). ~9 clocks per access at 50 MHz.
// READ_DELAY: clocks from the READ command to sampling DQ (CAS latency 3 + the half-clock shift -> 4).
// ***********************************************

module sdram_ctrl #(
	parameter CLK_MHZ = 50,
	parameter READ_DELAY = 4
)(
	input							clk,
	input							reset_n,			// hold low until the PLL is locked
	input			[2:0]			rd_delay,		// = READ_DELAY normally; a port so a test can sweep it
	input							req,
	input							we,
	input			[24:0]		addr,
	input			[15:0]		wdata,
	output						ready,			// can take a request now
	output reg					rvalid = 0,
	output reg		[15:0]	rdata = 0,
	output reg					init_done = 0,
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
// mode register: burst length 1, sequential, CAS latency 3, programmed burst for writes
localparam [12:0] MODE = 13'b000_0_00_011_0_000;
localparam T_200US = CLK_MHZ * 210;			// power-up wait (spec 200 us)
localparam T_REFI  = CLK_MHZ * 78 / 10;		// 7.8 us between refreshes (8192 rows in 64 ms)
localparam T_RFC   = 4;							// refresh cycle 70 ns: 4 clocks at 50 MHz (with margin)
localparam T_RP    = 2;							// precharge 20 ns
localparam T_RCD   = 2;							// activate to read/write 20 ns
localparam T_RC    = 4;							// read/write with auto-precharge until the bank is free again

reg	[3:0]		cmd = C_NOP;
reg	[15:0]	dq_out = 0;
reg				dq_oe = 0;
assign {DRAM_CS_N, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N} = cmd;
assign DRAM_CKE = 1'b1;
assign DRAM_LDQM = 1'b0;
assign DRAM_UDQM = 1'b0;
assign DRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

localparam S_INIT = 0, S_INIT_PRE = 1, S_INIT_REF = 2, S_INIT_MRS = 3, S_IDLE = 4, S_REF = 5,
           S_ACT = 6, S_RW = 7, S_WAIT = 8;
reg	[3:0]		st = S_INIT;
reg	[15:0]	t = 0;					// wait counter
reg	[3:0]		nref = 0;
reg	[15:0]	refi = 0;
reg				r_we;
reg	[24:0]	r_addr;
reg	[15:0]	r_wdata;
reg	[7:0]		rd_pipe = 0;			// a 1 travels READ_DELAY clocks after a READ command

// a request is latched as soon as it arrives and served after a refresh if one is due: with only a 1-clock req,
// a refresh starting in that same clock used to swallow it (the memory test hung, found with Signal Tap)
reg				pend = 0;
assign ready = (st == S_IDLE) && init_done && !pend && !req;

always @(posedge clk) begin
	cmd <= C_NOP;
	dq_oe <= 0;
	rvalid <= 0;
	rd_pipe <= {rd_pipe[6:0], 1'b0};
	if (rd_pipe[rd_delay - 1'b1]) begin
		rdata <= DRAM_DQ;
		rvalid <= 1;
	end
	if (init_done && refi < 16'hFFFF) refi <= refi + 1'b1;
	if (req) begin
		pend <= 1;
		r_we <= we;
		r_addr <= addr;
		r_wdata <= wdata;
	end
	if (t != 0) t <= t - 1'b1;

	if (!reset_n) begin
		st <= S_INIT;
		t <= T_200US;
		init_done <= 0;
	end
	else case (st)
		S_INIT: if (t == 0) begin
			cmd <= C_PRE;
			DRAM_ADDR[10] <= 1'b1;				// precharge all banks
			t <= T_RP;
			st <= S_INIT_PRE;
		end
		S_INIT_PRE: if (t == 0) begin
			nref <= 8;
			st <= S_INIT_REF;
		end
		S_INIT_REF: if (t == 0) begin
			if (nref == 0) begin
				cmd <= C_MRS;
				DRAM_ADDR <= MODE;
				DRAM_BA <= 2'b00;
				t <= 3;
				st <= S_INIT_MRS;
			end
			else begin
				cmd <= C_REF;
				nref <= nref - 1'b1;
				t <= T_RFC;
			end
		end
		S_INIT_MRS: if (t == 0) begin
			init_done <= 1;
			refi <= 0;
			st <= S_IDLE;
		end
		S_IDLE: begin
			if (refi >= T_REFI) begin				// refresh has priority
				cmd <= C_REF;
				refi <= 0;
				t <= T_RFC;
				st <= S_REF;
			end
			else if (pend) begin
				pend <= 0;
				if (r_we) begin					// drive DQ from the ACTIVATE on: 2 clocks of settling before WRITE
					dq_out <= r_wdata;
					dq_oe <= 1;
				end
				cmd <= C_ACT;
				DRAM_BA <= r_addr[24:23];
				DRAM_ADDR <= r_addr[22:10];		// row
				t <= T_RCD - 1;
				st <= S_ACT;
			end
		end
		S_REF: if (t == 0) st <= S_IDLE;
		S_ACT: begin
			if (r_we) dq_oe <= 1;					// keep driving until the WRITE command
			if (t == 0) begin
			cmd <= r_we ? C_WRITE : C_READ;
			DRAM_ADDR <= {2'b00, 1'b1, r_addr[9:0]};	// column, A10 = 1: auto-precharge
			if (r_we) begin
				dq_out <= r_wdata;
				dq_oe <= 1;
			end
			else
				rd_pipe[0] <= 1'b1;
			t <= T_RC + (r_we ? 4'd0 : rd_delay);
			st <= S_WAIT;
			end
		end
		S_WAIT: if (t == 0) st <= S_IDLE;
		default: st <= S_IDLE;
	endcase
end

endmodule
