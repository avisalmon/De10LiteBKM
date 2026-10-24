// ROM in M9K block memory, Altera altsyncram IP (no wizard), initialised from a .mif or .hex file
//
// q is valid one clock after address (registered address, unregistered output).
// INIT_FILE: path from the Quartus project folder (e.g. "assets/chip.mif"); make one with scripts/img2rom.py.
// LPM_HINT: "ENABLE_RUNTIME_MOD=NO" (plain ROM) or "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=IMG" (name: up to 4
// characters) -> the In-System Memory Content Editor can read and rewrite it over JTAG while the design runs.
// Simulation: ModelSim with the altera_mf library (scripts/sim.py --modelsim) reads the same .mif.
// ***********************************************

module rom_ip #(
	parameter WIDTH = 12,
	parameter DEPTH = 4096,
	parameter AW = 12,
	parameter INIT_FILE = "rom.mif",
	parameter LPM_HINT = "ENABLE_RUNTIME_MOD=NO"
)(
	input					clk,
	input		[AW-1:0]	address,
	output	[WIDTH-1:0]	q
	);

altsyncram rom (
	.clock0(clk),
	.address_a(address),
	.q_a(q),
	.aclr0(1'b0), .aclr1(1'b0), .address_b(1'b1), .addressstall_a(1'b0), .addressstall_b(1'b0),
	.byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b1), .clocken0(1'b1), .clocken1(1'b1),
	.clocken2(1'b1), .clocken3(1'b1), .data_a({WIDTH{1'b1}}), .data_b(1'b1), .eccstatus(),
	.q_b(), .rden_a(1'b1), .rden_b(1'b1), .wren_a(1'b0), .wren_b(1'b0)
	);

defparam
	rom.address_aclr_a = "NONE",
	rom.clock_enable_input_a = "BYPASS",
	rom.clock_enable_output_a = "BYPASS",
	rom.init_file = INIT_FILE,
	rom.intended_device_family = "MAX 10",
	rom.lpm_hint = LPM_HINT,
	rom.lpm_type = "altsyncram",
	rom.numwords_a = DEPTH,
	rom.operation_mode = "ROM",
	rom.outdata_aclr_a = "NONE",
	rom.outdata_reg_a = "UNREGISTERED",
	rom.ram_block_type = "M9K",
	rom.widthad_a = AW,
	rom.width_a = WIDTH,
	rom.width_byteena_a = 1;

endmodule
