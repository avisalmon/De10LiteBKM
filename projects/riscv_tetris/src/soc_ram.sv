// The 32 KB program + data RAM: 8192 words with byte enables, one clock read latency.
//
// IMPL = "IP": Altera altsyncram with ENABLE_RUNTIME_MOD, so the In-System Memory Content Editor loads a new
//   program over JTAG while the FPGA runs (tools/load.py). Instance name PROG. Needs Quartus (or ModelSim with
//   the altera_mf library).
// IMPL = "SIM": a plain behavioural array for Icarus; same timing.
// INIT_FILE: Quartus wants a .mif, $readmemh a .hex (tools/asm.py writes both).
// ***********************************************
`default_nettype none

module soc_ram #(
	parameter IMPL = "SIM",
	parameter INIT_FILE = "build/tetris.hex"
)(
	input		wire				clk,
	input		wire	[12:0]	addr,			// word address
	input		wire	[31:0]	wdata,
	input		wire	[3:0]		be,
	input		wire				we,
	output	wire	[31:0]	q
	);

generate
if (IMPL == "IP") begin : ip
	altsyncram ram (
		.clock0(clk), .address_a(addr), .data_a(wdata), .byteena_a(be), .wren_a(we), .q_a(q),
		.aclr0(1'b0), .aclr1(1'b0), .address_b(1'b1), .addressstall_a(1'b0), .addressstall_b(1'b0),
		.byteena_b(1'b1), .clock1(1'b1), .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
		.data_b(1'b1), .eccstatus(), .q_b(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0));
	defparam
		ram.operation_mode = "SINGLE_PORT",
		ram.width_a = 32,
		ram.widthad_a = 13,
		ram.numwords_a = 8192,
		ram.width_byteena_a = 4,
		ram.byte_size = 8,
		ram.init_file = INIT_FILE,
		ram.lpm_hint = "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=PROG",
		ram.lpm_type = "altsyncram",
		ram.intended_device_family = "MAX 10",
		ram.ram_block_type = "M9K",
		ram.outdata_reg_a = "UNREGISTERED",
		ram.outdata_aclr_a = "NONE",
		ram.address_aclr_a = "NONE",
		ram.clock_enable_input_a = "BYPASS",
		ram.clock_enable_output_a = "BYPASS",
		ram.power_up_uninitialized = "FALSE",
		ram.read_during_write_mode_port_a = "DONT_CARE";
end else begin : sim
	logic [31:0] mem [0:8191];
	logic [31:0] q_r;
	initial $readmemh(INIT_FILE, mem);
	always @(posedge clk) begin
		if (we) begin
			if (be[0]) mem[addr][7:0]   <= wdata[7:0];
			if (be[1]) mem[addr][15:8]  <= wdata[15:8];
			if (be[2]) mem[addr][23:16] <= wdata[23:16];
			if (be[3]) mem[addr][31:24] <= wdata[31:24];
		end
		q_r <= mem[addr];
	end
	assign q = q_r;
end
endgenerate

endmodule
