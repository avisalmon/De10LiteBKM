// PLL for the DE10-Lite with dynamic phase shift: pll_de10 plus the ports that move one output's phase at run time
//
// Same parameters and outputs as lib/rtl/pll_de10.v (f_out = 50 MHz * MUL / DIV, phase in ps). The extra ports are
// the MAX 10 PLL's phase-reconfiguration interface, driven by lib/rtl/pll_phase_step.sv:
//   scanclk               the clock of this interface (<= 100 MHz; the 50 MHz board clock is fine)
//   phasecounterselect    which counter moves: 0 all C counters, 1 M, 2 = C0, 3 = C1, 4 = C2, 5 = C3, 6 = C4
//   phaseupdown           1 = later (lag), 0 = earlier
//   phasestep             hold high for >= 2 scanclk: one step of VCO period / 8 (208 ps: the fitter runs the VCO
//                         at 600 MHz for 100 MHz outputs; the VCO is in output_files/<rev>.fit.rpt, "PLL Summary")
//   phasedone             low for half a scanclk while the step is applied (too short to see from scanclk logic:
//                         pll_phase_step holds phasestep a fixed 8 clocks and does not wait for it)
// areset returns every output to its compiled phase (and drops locked while the PLL restarts).
// Used by examples/15_sdram_stream_fabric (the SDRAM read-window sweep). Published examples keep using pll_de10.
// ***********************************************

module pll_de10_dps #(
	parameter C0_MUL = 1, C0_DIV = 2, C0_PHASE = "0",		// 25 MHz
	parameter C1_MUL = 1, C1_DIV = 1, C1_PHASE = "0",		// 50 MHz
	parameter C2_MUL = 2, C2_DIV = 1, C2_PHASE = "0",		// 100 MHz
	parameter C3_MUL = 1, C3_DIV = 5, C3_PHASE = "0",		// 10 MHz
	parameter C4_MUL = 1, C4_DIV = 1, C4_PHASE = "0"		// 50 MHz
)(
	input				areset,
	input				inclk0,		// MAX10_CLK1_50 (or MAX10_CLK2_50)
	output	[4:0]	clk,
	output			locked,
	input				scanclk,
	input		[2:0]	phasecounterselect,
	input				phaseupdown,
	input				phasestep,
	output			phasedone
	);

altpll altpll_component (
	.areset(areset),
	.inclk({1'b0, inclk0}),
	.clk(clk),
	.locked(locked),
	.scanclk(scanclk),
	.phasecounterselect(phasecounterselect),
	.phaseupdown(phaseupdown),
	.phasestep(phasestep),
	.phasedone(phasedone),
	.activeclock(), .clkbad(), .clkena({6{1'b1}}), .clkloss(), .clkswitch(1'b0), .configupdate(1'b0),
	.enable0(), .enable1(), .extclk(), .extclkena({4{1'b1}}), .fbin(1'b1), .fbmimicbidir(), .fbout(),
	.fref(), .icdrclk(), .pfdena(1'b1), .pllena(1'b1), .scanaclr(1'b0), .scanclkena(1'b1), .scandata(1'b0),
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
	altpll_component.port_scanclk = "PORT_USED",
	altpll_component.port_phasecounterselect = "PORT_USED",
	altpll_component.port_phaseupdown = "PORT_USED",
	altpll_component.port_phasestep = "PORT_USED",
	altpll_component.port_phasedone = "PORT_USED",
	altpll_component.width_phasecounterselect = 3,
	altpll_component.port_clk0 = "PORT_USED",
	altpll_component.port_clk1 = "PORT_USED",
	altpll_component.port_clk2 = "PORT_USED",
	altpll_component.port_clk3 = "PORT_USED",
	altpll_component.port_clk4 = "PORT_USED",
	altpll_component.port_clk5 = "PORT_UNUSED",
	altpll_component.width_clock = 5;

endmodule
