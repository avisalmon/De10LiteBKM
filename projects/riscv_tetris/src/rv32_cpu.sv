// A small RV32I CPU: multi-cycle, one memory port, no pipeline. 3 clocks per ALU / branch instruction, 5 per load
// or store (the bus answers one clock after a request). About 6 MIPS at 25 MHz: plenty for a game.
//
// Bus: the CPU raises bus_req with addr / we / wdata / be and holds it until bus_ack; a read's data is on bus_rdata
// in the ack clock; a write is done by the slave in the first req clock. The slave acks one clock after req.
// No CSRs, no interrupts, no misaligned access (software never does it). ecall / ebreak / an illegal
// instruction stop the CPU (halted = 1) until reset.
// trace_*: one pulse per register write, for the lock-step test against the Python simulator (tools/rv32sim.py).
// ***********************************************
`default_nettype none

module rv32_cpu (
	input		wire				clk,
	input		wire				rst_n,
	output	logic				bus_req,
	output	logic				bus_we,
	output	logic	[31:0]	bus_addr,
	output	logic	[31:0]	bus_wdata,
	output	logic	[3:0]		bus_be,
	input		wire	[31:0]	bus_rdata,
	input		wire				bus_ack,
	output	logic				halted,
	output	logic				fault,			// halted by an illegal instruction
	output	logic				trace_valid,
	output	logic	[31:0]	trace_pc,
	output	logic	[4:0]		trace_rd,
	output	logic	[31:0]	trace_data
	);

localparam [1:0] S_FETCH = 2'd0, S_EXEC = 2'd1, S_MEM = 2'd2, S_HALT = 2'd3;

logic	[1:0]		state;
logic	[31:0]	pc, ir;
logic	[31:0]	regs [1:31];

// ---- decode (from ir, valid in S_EXEC and S_MEM)
wire	[6:0]		opcode = ir[6:0];
wire	[4:0]		rd     = ir[11:7];
wire	[2:0]		f3     = ir[14:12];
wire	[4:0]		rs1    = ir[19:15];
wire	[4:0]		rs2    = ir[24:20];
wire	[31:0]	imm_i  = {{20{ir[31]}}, ir[31:20]};
wire	[31:0]	imm_s  = {{20{ir[31]}}, ir[31:25], ir[11:7]};
wire	[31:0]	imm_b  = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
wire	[31:0]	imm_u  = {ir[31:12], 12'b0};
wire	[31:0]	imm_j  = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

wire	[31:0]	rs1v = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
wire	[31:0]	rs2v = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

localparam [6:0] OP_LUI = 7'h37, OP_AUIPC = 7'h17, OP_JAL = 7'h6F, OP_JALR = 7'h67, OP_BR = 7'h63,
                 OP_LOAD = 7'h03, OP_STORE = 7'h23, OP_IMM = 7'h13, OP_REG = 7'h33, OP_FENCE = 7'h0F, OP_SYS = 7'h73;

// ---- ALU
wire				is_reg = (opcode == OP_REG);
wire	[31:0]	alu_b  = is_reg ? rs2v : imm_i;
wire	[4:0]		shamt  = alu_b[4:0];
wire				alt    = ir[30] && (is_reg || f3 == 3'b101);		// sub / sra (srai keeps bit 30 in the immediate)
// the arithmetic shift on its own signed wire: inside a ?: with an unsigned branch, >>> would turn logical
wire signed [31:0] sra_v = $signed(rs1v) >>> shamt;
wire				lt_s   = $signed(rs1v) < $signed(alu_b);
wire				lt_u   = rs1v < alu_b;
logic	[31:0]	alu;
always_comb
	case (f3)
		3'b000: alu = (alt && is_reg) ? rs1v - alu_b : rs1v + alu_b;
		3'b001: alu = rs1v << shamt;
		3'b010: alu = {31'd0, lt_s};
		3'b011: alu = {31'd0, lt_u};
		3'b100: alu = rs1v ^ alu_b;
		3'b101: alu = alt ? sra_v : rs1v >> shamt;
		3'b110: alu = rs1v | alu_b;
		default: alu = rs1v & alu_b;
	endcase

// ---- branch condition
logic				br_take;
always_comb
	case (f3)
		3'b000: br_take = rs1v == rs2v;
		3'b001: br_take = rs1v != rs2v;
		3'b100: br_take = $signed(rs1v) < $signed(rs2v);
		3'b101: br_take = $signed(rs1v) >= $signed(rs2v);
		3'b110: br_take = rs1v < rs2v;
		3'b111: br_take = rs1v >= rs2v;
		default: br_take = 1'b0;
	endcase

// ---- memory access
wire	[31:0]	mem_addr = rs1v + ((opcode == OP_STORE) ? imm_s : imm_i);
wire	[1:0]		mem_off  = mem_addr[1:0];
logic	[3:0]		st_be;
logic	[31:0]	st_data;
always_comb
	case (f3[1:0])
		2'b00: begin st_be = 4'b0001 << mem_off; st_data = {4{rs2v[7:0]}}; end
		2'b01: begin st_be = mem_off[1] ? 4'b1100 : 4'b0011; st_data = {2{rs2v[15:0]}}; end
		default: begin st_be = 4'b1111; st_data = rs2v; end
	endcase
// load result: pick the byte / half by the address, extend by f3
wire	[31:0]	ld_shift = bus_rdata >> {mem_off, 3'b000};
logic	[31:0]	ld_data;
always_comb
	case (f3)
		3'b000: ld_data = {{24{ld_shift[7]}}, ld_shift[7:0]};
		3'b001: ld_data = {{16{ld_shift[15]}}, ld_shift[15:0]};
		3'b100: ld_data = {24'd0, ld_shift[7:0]};
		3'b101: ld_data = {16'd0, ld_shift[15:0]};
		default: ld_data = bus_rdata;
	endcase

// ---- the bus outputs by state
always_comb begin
	bus_req = 1'b0; bus_we = 1'b0; bus_addr = pc; bus_wdata = st_data; bus_be = 4'b1111;
	case (state)
		S_FETCH: begin bus_req = 1'b1; bus_addr = pc; end
		S_MEM:   begin bus_req = 1'b1; bus_addr = {mem_addr[31:2], 2'b00}; bus_we = (opcode == OP_STORE); bus_be = (opcode == OP_STORE) ? st_be : 4'b1111; end
		default: ;
	endcase
end

// ---- the state machine
wire	[31:0]	pc4 = pc + 32'd4;
logic				wb_en;
logic	[31:0]	wb_data, pc_next;
logic				illegal;

always_comb begin
	wb_en = 1'b0; wb_data = 32'd0; pc_next = pc4; illegal = 1'b0;
	case (opcode)
		OP_LUI:   begin wb_en = 1'b1; wb_data = imm_u; end
		OP_AUIPC: begin wb_en = 1'b1; wb_data = pc + imm_u; end
		OP_JAL:   begin wb_en = 1'b1; wb_data = pc4; pc_next = pc + imm_j; end
		OP_JALR:  begin wb_en = 1'b1; wb_data = pc4; pc_next = (rs1v + imm_i) & 32'hFFFFFFFE; end
		OP_BR:    pc_next = br_take ? pc + imm_b : pc4;
		OP_IMM, OP_REG: begin wb_en = 1'b1; wb_data = alu; end
		OP_LOAD, OP_STORE, OP_FENCE, OP_SYS: ;
		default:  illegal = 1'b1;
	endcase
end

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		state <= S_FETCH; pc <= 32'd0; ir <= 32'd0; halted <= 1'b0; fault <= 1'b0;
		trace_valid <= 1'b0; trace_pc <= 32'd0; trace_rd <= 5'd0; trace_data <= 32'd0;
		for (int i = 1; i < 32; i++) regs[i] <= 32'd0;		// known registers: the simulator starts from zeros too
	end else begin
		trace_valid <= 1'b0;
		case (state)
			S_FETCH:
				if (bus_ack) begin ir <= bus_rdata; state <= S_EXEC; end
			S_EXEC: begin
				if (illegal) begin halted <= 1'b1; fault <= 1'b1; state <= S_HALT; end
				else if (opcode == OP_SYS) begin halted <= 1'b1; state <= S_HALT; end
				else if (opcode == OP_LOAD || opcode == OP_STORE) begin
					state <= S_MEM;
				end else begin
					if (wb_en && rd != 5'd0) begin
						regs[rd] <= wb_data;
						trace_valid <= 1'b1; trace_pc <= pc; trace_rd <= rd; trace_data <= wb_data;
					end
					pc <= pc_next;
					state <= S_FETCH;
				end
			end
			S_MEM:
				if (bus_ack) begin
					if (opcode == OP_LOAD && rd != 5'd0) begin
						regs[rd] <= ld_data;
						trace_valid <= 1'b1; trace_pc <= pc; trace_rd <= rd; trace_data <= ld_data;
					end
					pc <= pc4;
					state <= S_FETCH;
				end
			default: ;
		endcase
	end
end

endmodule
