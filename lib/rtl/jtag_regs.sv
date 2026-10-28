`default_nettype none
// PC-visible registers over the USB-Blaster cable: a virtual JTAG node that reads and writes a 32-bit register bus
//
// The design gets a plain bus (addr, wdata, we, rdata); the PC (scripts/jtag_regs.py, or quartus_stp) gets peek and
// poke. Virtual IR (4 bits); every DR shifts LSB first:
//   1 ADDR    16 in    the register address; a block transfer sets it once
//   2 WRITE   32 in    on update: the word is written to ADDR, then ADDR increments
//   3 READ    32 out   capture: the register at ADDR (fetched after the last command); on update ADDR increments
//   4 ID      32 out   the ID parameter: which design is on the board, which register map to expect
//   other     1        bypass
// So a block read is one ADDR scan and n READ scans; a block write one ADDR scan and n WRITE scans.
// A scan must come at least 4 clk clocks after the previous update (a cable needs a thousand times that).
//
// The bus: addr changes, then rdata is sampled 2 clocks later, so rdata may be a combinational mux of addr or a
// register loaded from addr one clock later. we is one clock wide with wdata and addr valid; writes to unknown
// addresses are the design's business to ignore.
// Clocks: the JTAG side runs on TCK (asynchronous; it ticks only while the cable shifts); commands cross to clk
// through a toggle and a 2-FF synchronizer, the read word crosses back as a register the TCK side reads while it
// holds still (the same pattern as lib/rtl/sdram_loader.sv).
// Simulation: define JTAG_REGS_SIM to drive the JTAG side from a testbench (sim_* ports) instead of sld_virtual_jtag
// (lib/sim/tb_jtag_regs.sv).
// ***********************************************

module jtag_regs #(
	parameter INSTANCE = 1,									// virtual JTAG instance index (the loader of example 14 is 0)
	parameter [31:0] ID = 32'h5F15_0001					// what IR 4 answers
)(
	input		wire				clk,
	input		wire				rst_n,
	output	reg	[15:0]	addr = 0,
	output	reg	[31:0]	wdata = 0,
	output	reg				we = 0,
	input		wire	[31:0]	rdata,
	output	wire				busy							// a command is being executed on the clk side
`ifdef JTAG_REGS_SIM
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

localparam [3:0]	IR_ADDR = 4'd1, IR_WRITE = 4'd2, IR_READ = 4'd3, IR_ID = 4'd4;
localparam [1:0]	OP_ADDR = 2'd0, OP_WRITE = 2'd1, OP_NEXT = 2'd2;

// ---- the virtual JTAG node ----
wire				tck, tdi;
wire	[3:0]		ir;
wire				v_cdr, v_sdr, v_udr, v_uir;
reg				tdo;

`ifdef JTAG_REGS_SIM
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

// ---- clk side register the TCK side reads while it holds still ----
reg	[31:0]	rbox = 0;					// the register at addr, fetched after every command

// ---- TCK side ----
reg	[31:0]	sr = 0;						// the one shift register (16 or 32 bits of it)
reg	[15:0]	cmd_addr = 0;				// the command, held for the clk side
reg	[31:0]	cmd_data = 0;
reg	[1:0]		cmd_op = 0;
reg				cmd_t = 0;					// toggles once per command
reg				bypass = 0;

always @(*)
	case (ir)
		IR_ADDR, IR_WRITE, IR_READ, IR_ID:	tdo = sr[0];
		default:										tdo = bypass;
	endcase

always @(posedge tck) begin
	if (v_cdr)
		case (ir)
			IR_READ:		sr <= rbox;
			IR_ID:		sr <= ID;
			default:		sr <= 32'd0;
		endcase
	if (v_sdr) begin
		bypass <= tdi;
		sr <= {tdi, sr[31:1]};					// a 16-bit ADDR scan ends up in sr[31:16]
	end
	if (v_udr)
		case (ir)
			IR_ADDR: begin
				cmd_op <= OP_ADDR;
				cmd_addr <= sr[31:16];
				cmd_t <= ~cmd_t;
			end
			IR_WRITE: begin
				cmd_op <= OP_WRITE;
				cmd_data <= sr;
				cmd_t <= ~cmd_t;
			end
			IR_READ: begin
				cmd_op <= OP_NEXT;
				cmd_t <= ~cmd_t;
			end
			default: ;
		endcase
end

// ---- clk side ----
reg	[2:0]		cmd_s = 0;					// [0],[1] synchronizer, [2] previous
reg	[1:0]		ph = 0;						// 0 idle; 1 increment; 2 settle; 3 fetch
reg	[1:0]		op = 0;
wire				new_cmd = cmd_s[2] ^ cmd_s[1];
assign busy = new_cmd || ph != 0;

always @(posedge clk) begin
	cmd_s <= {cmd_s[1:0], cmd_t};
	we <= 1'b0;
	if (new_cmd) begin
		op <= cmd_op;
		ph <= 2'd1;
		case (cmd_op)
			OP_ADDR:		addr <= cmd_addr;
			OP_WRITE: begin
				we <= 1'b1;
				wdata <= cmd_data;
			end
			default: ;
		endcase
	end
	else
		case (ph)
			2'd1: begin
				if (op != OP_ADDR) addr <= addr + 1'b1;
				ph <= 2'd2;
			end
			2'd2: ph <= 2'd3;
			2'd3: begin
				rbox <= rdata;
				ph <= 2'd0;
			end
			default: ;
		endcase
	if (!rst_n) begin
		ph <= 2'd0;
		we <= 1'b0;
	end
end

endmodule

`default_nettype wire
