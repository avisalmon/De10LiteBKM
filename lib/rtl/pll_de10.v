// PLL for the DE10-Lite: 50 MHz in, up to 5 clocks out, set by parameters
//
// Each output: f_out = 50 MHz * MUL / DIV, phase in picoseconds ("0", "5000" = 90 deg at 50 MHz...).
// Quartus picks the VCO and counters; if a ratio is impossible the build stops with an error that says so.
// The real frequencies are in output_files/<rev>.fit.rpt, section "PLL Summary".
// locked goes high when all outputs are stable; hold areset high to restart the PLL.
// Direct altpll instance (the same thing the IP wizard writes), so no wizard or .qip is needed.
// ***********************************************

module pll_de10 #(
	parameter C0_MUL = 1, C0_DIV = 2, C0_PHASE = "0",		// 25 MHz
	parameter C1_MUL = 1, C1_DIV = 1, C1_PHASE = "0",		// 50 MHz
	parameter C2_MUL = 2, C2_DIV = 1, C2_PHASE = "0",		// 100 MHz
	parameter C3_MUL = 1, C3_DIV = 5, C3_PHASE = "0",		// 10 MHz
	parameter C4_MUL = 1, C4_DIV = 1, C4_PHASE = "0"		// 50 MHz
)(
	input				areset,
	input				inclk0,		// MAX10_CLK1_50 (or MAX10_CLK2_50)
	output	[4:0]	clk,
	output			locked
	);

altpll altpll_component (
	.areset(areset),
	.inclk({1'b0, inclk0}),
	.clk(clk),
	.locked(locked),
	.activeclock(), .clkbad(), .clkena({6{1'b1}}), .clkloss(), .clkswitch(1'b0), .configupdate(1'b0),
	.enable0(), .enable1(), .extclk(), .extclkena({4{1'b1}}), .fbin(1'b1), .fbmimicbidir(), .fbout(),
	.fref(), .icdrclk(), .pfdena(1'b1), .phasecounterselect({4{1'b1}}), .phasedone(), .phasestep(1'b1),
	.phaseupdown(1'b1), .pllena(1'b1), .scanaclr(1'b0), .scanclk(1'b0), .scanclkena(1'b1), .scandata(1'b0),
	.scandataout(), .scandone(), .scanread(1'b0), .scanwrite(1'b0), .sclkout0(), .sclkout1(),
	.vcooverrange(), .vcounderrange()
	);

defparam
	altpll_component.bandwidth_type = "AUTO",
	altpll_component.clk0_multiply_by = C0_MUL, altpll_component.clk0_divide_by = C0_DIV,
	altpll_component.clk0_phase_shift = C0_PHASE, altpll_component.clk0_duty_cycle = 50,
	altpll_component.clk1_multiply_by = C1_MUL, altpll_component.clk1_divide_by = C1_DIV,
	altpll_component.clk1_phase_shift = C1_PHASE, altpll_component.clk1_duty_cycle = 50,
	altpll_component.clk2_multiply_by = C2_MUL, altpll_component.clk2_divide_by = C2_DIV,
	altpll_component.clk2_phase_shift = C2_PHASE, altpll_component.clk2_duty_cycle = 50,
	altpll_component.clk3_multiply_by = C3_MUL, altpll_component.clk3_divide_by = C3_DIV,
	altpll_component.clk3_phase_shift = C3_PHASE, altpll_component.clk3_duty_cycle = 50,
	altpll_component.clk4_multiply_by = C4_MUL, altpll_component.clk4_divide_by = C4_DIV,
	altpll_component.clk4_phase_shift = C4_PHASE, altpll_component.clk4_duty_cycle = 50,
	altpll_component.compensate_clock = "CLK0",
	altpll_component.inclk0_input_frequency = 20000,		// ps, 50 MHz
	altpll_component.intended_device_family = "MAX 10",
	altpll_component.lpm_type = "altpll",
	altpll_component.operation_mode = "NORMAL",
	altpll_component.pll_type = "AUTO",
	altpll_component.port_areset = "PORT_USED",
	altpll_component.port_inclk0 = "PORT_USED",
	altpll_component.port_inclk1 = "PORT_UNUSED",
	altpll_component.port_locked = "PORT_USED",
	altpll_component.port_clk0 = "PORT_USED",
	altpll_component.port_clk1 = "PORT_USED",
	altpll_component.port_clk2 = "PORT_USED",
	altpll_component.port_clk3 = "PORT_USED",
	altpll_component.port_clk4 = "PORT_USED",
	altpll_component.port_clk5 = "PORT_UNUSED",
	altpll_component.width_clock = 5;

endmodule
