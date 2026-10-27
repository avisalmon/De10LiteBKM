`default_nettype none
// PC <-> SDRAM over the USB-Blaster cable: a virtual JTAG node that streams 16-bit words into the SDRAM and back
//
// The PC (scripts/sdram_load.py) shifts a file through a virtual JTAG data register: every 16 bits become one SDRAM
// word (little endian: the first byte is the low byte), written at consecutive addresses. READ streams words back the
// same way. The board keeps a CRC32 (the zlib one) of everything written, and can CRC any SDRAM range by itself
// (CHECK, ~7 MB/s), so a 64 MB load is proven in seconds without reading it back over the cable.
//
// Virtual IR (4 bits) and its data register (DR); every DR shifts LSB first:
//   1 WADDR   64 in    [24:0] word address: the next written word goes there; clears the write count, CRC and flags
//   2 WRITE   n x 16   the data, one SDRAM word per 16 bits
//   3 RADDR   64 in    [24:0] word address: reading (re)starts there
//   4 READ    n x 16   the data out (TDI ignored)
//   5 STATUS  320 out  10 words: 0 magic "SDLD", 1 flags, 2 words written, 3 write CRC32, 4 words received,
//                      5 words sent, 6 check CRC32, 7 words checked, 8 user0, 9 user1. Flags: 0 init_done,
//                      1 write FIFO empty, 2 reading, 3 check busy, 4 check done, 5 write overflow, 6 read underrun,
//                      15:8 version, 20:16 FIFO high-water. Refreshed when the IR is set and after every scan.
//   6 CHECK   64 in    [24:0] first word, [57:32] word count: CRC32 of that SDRAM range (STATUS words 6, 7)
//   other     1        bypass
// Every data scan must be a multiple of 16 bits: each scan starts on a word boundary.
// Clocks: the JTAG side runs on TCK (it only ticks while the cable shifts); words cross to clk through toggle
// mailboxes. The SDRAM side keeps up with any JTAG cable: ~10 clocks per write at 50 MHz = 10 MB/s.
// Sharing the SDRAM: the design may use sdram_ctrl itself while busy is low and the PC is not loading.
//
// Simulation: define SDRAM_LOADER_SIM to drive the JTAG side from a testbench (sim_* ports) instead of
// sld_virtual_jtag (lib/sim/tb_sdram_loader.sv).
// ***********************************************

module sdram_loader #(
	parameter INSTANCE = 0						// virtual JTAG instance index (sdram_load.py --instance)
)(
	input		wire				clk,
	input		wire				reset_n,
	// master port of lib/rtl/sdram_ctrl.sv
	output	reg				req = 0,
	output	reg				we = 0,
	output	reg	[24:0]	addr = 0,
	output	reg	[15:0]	wdata = 0,
	input		wire				ready,
	input		wire				rvalid,
	input		wire	[15:0]	rdata,
	input		wire				init_done,
	// to and from the design
	input		wire	[31:0]	user0,						// two words the design reports in STATUS (8, 9)
	input		wire	[31:0]	user1,
	output	reg	[31:0]	words_written = 0,		// since the last WADDR
	output	reg				reading = 0,				// a READ stream is open (since RADDR)
	output	reg				check_busy = 0,
	output	wire				busy,							// the SDRAM port is in use right now
	output	wire				error							// a word was lost: write overflow or read underrun
`ifdef SDRAM_LOADER_SIM
	,
	input		wire				sim_tck,
	input		wire				sim_tdi,
	input		wire	[3:0]		sim_ir_in,
	input		wire				sim_cdr,
	input		wire				sim_sdr,
	input		wire				sim_udr,
	input		wire				sim_uir,
	output	wire				sim_tdo
`endif
	);

localparam [3:0]	IR_WADDR = 4'd1, IR_WRITE = 4'd2, IR_RADDR = 4'd3, IR_READ = 4'd4, IR_STATUS = 4'd5, IR_CHECK = 4'd6;
localparam [31:0]	MAGIC = 32'h53444C44;		// "SDLD"
localparam [7:0]	VERSION = 8'd1;

// CRC32 as zlib computes it (reflected, polynomial EDB88320), 16 bits at a time: low byte first, LSB first
function automatic [31:0] crc32_16(input [31:0] c, input [15:0] d);
	integer i;
	reg [31:0] x;
	begin
		x = c;
		for (i = 0; i < 16; i = i + 1)
			x = (x[0] ^ d[i]) ? ({1'b0, x[31:1]} ^ 32'hEDB88320) : {1'b0, x[31:1]};
		crc32_16 = x;
	end
endfunction

// ---- the virtual JTAG node ----
wire				tck, tdi;
wire	[3:0]		ir;
wire				v_cdr, v_sdr, v_udr, v_uir;
reg				tdo;

`ifdef SDRAM_LOADER_SIM
assign tck = sim_tck;
assign tdi = sim_tdi;
assign ir = sim_ir_in;
assign v_cdr = sim_cdr;
assign v_sdr = sim_sdr;
assign v_udr = sim_udr;
assign v_uir = sim_uir;
assign sim_tdo = tdo;
`else
sld_virtual_jtag #(
	.sld_auto_instance_index("NO"),
	.sld_instance_index(INSTANCE),
	.sld_ir_width(4)
) vjtag (
	.tck(tck), .tdi(tdi), .tdo(tdo), .ir_in(ir), .ir_out(4'd0),
	.virtual_state_cdr(v_cdr), .virtual_state_sdr(v_sdr), .virtual_state_udr(v_udr), .virtual_state_uir(v_uir)
	);
`endif

// ---- clk side registers the TCK side reads (they hold still while it reads them) ----
reg	[15:0]	mbox = 0;					// read mailbox: the next word to send
reg				put_t = 0;					// toggles when the mailbox is filled
reg	[223:0]	snap = 0;					// status snapshot: flags, written, wcrc, ccrc, checked, user0, user1

// ---- TCK side ----
reg	[63:0]	csr = 0;						// command shift register (WADDR, RADDR, CHECK)
reg	[63:0]	cmd_arg = 0;				// the last command, held for the clk side
reg	[3:0]		cmd_op = 0;
reg				cmd_t = 0;					// toggles once per command
reg	[15:0]	wsr = 0;						// write: the word shifting in
reg	[3:0]		wbit = 0;
reg	[15:0]	wbox = 0;					// write mailbox: the last complete word
reg				wbox_t = 0;					// toggles once per word
reg	[31:0]	rx_words = 0;				// words received since WADDR
reg	[15:0]	rsr = 0;						// read: the word shifting out
reg	[3:0]		rbit = 0;
reg				take_t = 0;					// toggles when the mailbox word goes into use
reg	[1:0]		put_s = 0;					// put_t synchronized to TCK
reg	[31:0]	tx_words = 0;				// words sent since RADDR
reg				underrun = 0;				// a word to send was not ready in time (until RADDR)
reg	[319:0]	ssr = 0;						// status shift register
reg				snap_t = 0;					// toggles to ask the clk side for a fresh snapshot
reg				uir_d = 0;
reg				bypass = 0;
wire				mbox_full = put_s[1] != take_t;

always @(*) begin
	case (ir)
		IR_READ:								tdo = rsr[0];
		IR_STATUS:							tdo = ssr[0];
		IR_WRITE:							tdo = wsr[0];
		IR_WADDR, IR_RADDR, IR_CHECK:	tdo = csr[0];
		default:								tdo = bypass;
	endcase
end

always @(posedge tck) begin
	put_s <= {put_s[0], put_t};
	uir_d <= v_uir;
	// ir changes on the UIR edge itself, so a new IR is seen one edge later; any UDR also refreshes the status
	if (uir_d || v_udr)
		snap_t <= ~snap_t;
	if (v_cdr) begin
		wbit <= 0;
		rbit <= 0;
		if (ir == IR_READ) begin
			rsr <= mbox;					// peek: the word is taken when its first bit goes out
			if (!mbox_full) underrun <= 1'b1;
		end
		if (ir == IR_STATUS)
			ssr <= {snap[223:96], tx_words, rx_words, snap[95:64], snap[63:32],
			        snap[31:7], underrun, snap[5:0], MAGIC};
	end
	if (v_sdr) begin
		bypass <= tdi;
		csr <= {tdi, csr[63:1]};
		ssr <= {1'b0, ssr[319:1]};
		if (ir == IR_WRITE) begin
			wsr <= {tdi, wsr[15:1]};
			wbit <= wbit + 1'b1;
			if (wbit == 4'd15) begin
				wbox <= {tdi, wsr[15:1]};
				wbox_t <= ~wbox_t;
				rx_words <= rx_words + 1'b1;
			end
		end
		if (ir == IR_READ) begin
			rbit <= rbit + 1'b1;
			if (rbit == 4'd0) begin			// the word in rsr is in use now: the clk side refills the mailbox
				take_t <= ~take_t;
				tx_words <= tx_words + 1'b1;
			end
			if (rbit == 4'd15) begin		// last bit of this word: load the next one (taken if the scan goes on)
				rsr <= mbox;
				if (!mbox_full) underrun <= 1'b1;
			end
			else
				rsr <= {1'b0, rsr[15:1]};
		end
	end
	if (v_udr) begin
		if (ir == IR_WADDR || ir == IR_RADDR || ir == IR_CHECK) begin
			cmd_op <= ir;
			cmd_arg <= csr;
			cmd_t <= ~cmd_t;
		end
		if (ir == IR_WADDR) rx_words <= 0;
		if (ir == IR_RADDR) begin
			tx_words <= 0;
			underrun <= 1'b0;
		end
	end
end

// ---- clk side ----
reg	[2:0]		wbox_s = 0, cmd_s = 0, take_s = 0, snap_s = 0;		// [0],[1] synchronizer, [2] previous
always @(posedge clk) begin
	wbox_s <= {wbox_s[1:0], wbox_t};
	cmd_s <= {cmd_s[1:0], cmd_t};
	take_s <= {take_s[1:0], take_t};
	snap_s <= {snap_s[1:0], snap_t};
end
wire				new_word = wbox_s[2] ^ wbox_s[1];
wire				new_cmd = cmd_s[2] ^ cmd_s[1];
wire				new_snap = snap_s[2] ^ snap_s[1];
wire				mbox_empty = put_t == take_s[1];

(* ramstyle = "logic" *) reg [15:0] fifo [0:15];			// write FIFO: words wait here for the SDRAM
reg	[4:0]		fw = 0, fr = 0;
wire				f_empty = fw == fr;
wire				f_full = (fw[3:0] == fr[3:0]) && (fw[4] != fr[4]);
wire	[4:0]		f_level = fw - fr;
reg	[4:0]		f_max = 0;					// the fullest the FIFO has been since WADDR
reg	[24:0]	wptr = 0;
reg	[31:0]	wcrc = 32'hFFFFFFFF;
reg				overflow = 0;
reg				cmd_pend = 0;
reg	[24:0]	rptr = 0;
reg	[15:0]	pre = 0;						// one word read ahead for the mailbox
reg				pre_valid = 0;
reg				stale = 0;					// the mailbox still holds a word from before RADDR
reg				rd_inflight = 0;
reg				rd_owner = 0;				// 0: read for the mailbox, 1: read for CHECK
reg	[24:0]	cptr = 0;
reg	[25:0]	c_left = 0;
reg	[31:0]	c_words = 0;
reg	[31:0]	ccrc = 32'hFFFFFFFF;
reg				c_done = 0;

assign busy = !f_empty || req || rd_inflight || check_busy;
assign error = overflow || underrun;

always @(posedge clk) begin
	req <= 1'b0;

	if (new_word) begin
		if (f_full)
			overflow <= 1'b1;
		else begin
			fifo[fw[3:0]] <= wbox;
			fw <= fw + 1'b1;
		end
	end
	if (f_level > f_max) f_max <= f_level;

	// one request at a time; the controller's ready also waits for read data to come back
	if (ready) begin
		if (!f_empty) begin
			req <= 1'b1;
			we <= 1'b1;
			addr <= wptr;
			wdata <= fifo[fr[3:0]];
			wcrc <= crc32_16(wcrc, fifo[fr[3:0]]);
			fr <= fr + 1'b1;
			wptr <= wptr + 1'b1;
			words_written <= words_written + 1'b1;
		end
		else if (reading && !pre_valid && !rd_inflight && !cmd_pend) begin
			req <= 1'b1;
			we <= 1'b0;
			addr <= rptr;
			rptr <= rptr + 1'b1;
			rd_inflight <= 1'b1;
			rd_owner <= 1'b0;
		end
		else if (check_busy && c_left != 0 && !rd_inflight && !cmd_pend) begin
			req <= 1'b1;
			we <= 1'b0;
			addr <= cptr;
			cptr <= cptr + 1'b1;
			c_left <= c_left - 1'b1;
			rd_inflight <= 1'b1;
			rd_owner <= 1'b1;
		end
	end
	if (rvalid && rd_inflight) begin
		rd_inflight <= 1'b0;
		if (rd_owner) begin
			ccrc <= crc32_16(ccrc, rdata);
			c_words <= c_words + 1'b1;
		end
		else begin
			pre <= rdata;
			pre_valid <= 1'b1;
		end
	end
	if (check_busy && c_left == 0 && !rd_inflight) begin
		check_busy <= 1'b0;
		c_done <= 1'b1;
	end

	// read mailbox: refill it when the TCK side took the last word (or replace a stale one after RADDR)
	if (reading && pre_valid && (mbox_empty || stale)) begin
		mbox <= pre;
		if (mbox_empty) put_t <= ~put_t;
		pre_valid <= 1'b0;
		stale <= 1'b0;
	end

	// commands wait until no SDRAM access of the old stream is in flight
	if (new_cmd) cmd_pend <= 1'b1;
	if (cmd_pend && f_empty && !req && !rd_inflight) begin
		cmd_pend <= 1'b0;
		case (cmd_op)
			IR_WADDR: begin
				wptr <= cmd_arg[24:0];
				words_written <= 0;
				wcrc <= 32'hFFFFFFFF;
				overflow <= 1'b0;
				f_max <= 0;
				reading <= 1'b0;
			end
			IR_RADDR: begin
				rptr <= cmd_arg[24:0];
				reading <= 1'b1;
				pre_valid <= 1'b0;
				stale <= 1'b1;
			end
			IR_CHECK: begin
				cptr <= cmd_arg[24:0];
				c_left <= cmd_arg[57:32];
				c_words <= 0;
				ccrc <= 32'hFFFFFFFF;
				check_busy <= 1'b1;
				c_done <= 1'b0;
			end
			default: ;
		endcase
	end

	if (new_snap)
		snap <= {user1, user0, c_words, ~ccrc, ~wcrc, words_written,
		         8'd0, 3'd0, f_max, VERSION, 1'b0, 1'b0, overflow, c_done, check_busy, reading, f_empty, init_done};

	if (!reset_n) begin
		fw <= 0;
		fr <= 0;
		reading <= 1'b0;
		check_busy <= 1'b0;
		rd_inflight <= 1'b0;
		pre_valid <= 1'b0;
		cmd_pend <= 1'b0;
	end
end

endmodule
