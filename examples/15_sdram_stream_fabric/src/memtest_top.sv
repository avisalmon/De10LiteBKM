`default_nettype none
// Example 15, step 1: the SDRAM read-window sweep and the burst controller's speed, measured on the board
//
// The burst controller (lib/rtl/sdram_burst_ctrl.sv) runs the 64 MB SDRAM at CLK_MHZ with DRAM_CLK from the PLL.
// Which DRAM_CLK phase and which rd_delay read the data back right is found here, not guessed: the PC
// (scripts/sdram_memtest.py) moves the DRAM_CLK phase in 208 ps steps at run time (lib/rtl/pll_phase_step.sv),
// runs the memory test (lib/rtl/sdram_memtest.sv) for every rd_delay and draws the map of what passed.
// Everything is driven through 32-bit registers over the USB-Blaster cable (lib/rtl/jtag_regs.sv, instance 1):
//   0x000 .. 0x01F  the memory test (its register list is in sdram_memtest.sv)
//   0x020  PHASE     write: [7:0] steps, [8] 1 = later, 0 = earlier, [16] 1 = reset the PLL (back to the compiled
//                    phase; the whole design restarts, wait for STATUS.init_done)
//                    read:  [15:0] steps from the compiled phase (signed), [29] a step showed no phasedone low
//                    (diagnostic), [30] busy, [31] the PLL did not answer
//   0x021  INFO      [15:0] the compiled DRAM_CLK phase in ps, [31:16] one step in ps (nominal)
//   0x022  CYCLES    a free-running clock counter: read it twice to measure the design's clock
//   0x023  CLK_MHZ   what the design was built for
// HEX5..0: the error count in hex (SW0 up: the phase position, HEX5 shows - when it is negative).
// LEDR0 SDRAM ready, 1 test running, 2 test finished, 3 pass, 4 PLL locked, 5 phase stepper busy, 6 stepper error,
// 7 the PC is talking. KEY0 resets the PLL (and so everything).
// ***********************************************

module memtest_top #(
	parameter CLK_MHZ = 100,
	parameter MUL = 2, DIV = 1,								// CLK_MHZ = 50 * MUL / DIV
	parameter C1_PHASE = "0",									// DRAM_CLK phase in ps, as the PLL wants it
	parameter [15:0] PHASE_PS = 0,								// the same number, for the INFO register
	parameter [15:0] STEP_PS = 208								// one phase step = VCO period / 8: the fitter picked a
																		// 600 MHz VCO for 100 MHz (fit.rpt "PLL Summary"), 48 per period
)(
	input						MAX10_CLK1_50,
	input			[1:0]		KEY,
	input			[9:0]		SW,
	output		[9:0]		LEDR,
	output		[7:0]		HEX0,
	output		[7:0]		HEX1,
	output		[7:0]		HEX2,
	output		[7:0]		HEX3,
	output		[7:0]		HEX4,
	output		[7:0]		HEX5,
	output		[12:0]	DRAM_ADDR,
	output		[1:0]		DRAM_BA,
	output					DRAM_CAS_N,
	output					DRAM_CKE,
	output					DRAM_CLK,
	output					DRAM_CS_N,
	inout			[15:0]	DRAM_DQ,
	output					DRAM_LDQM,
	output					DRAM_RAS_N,
	output					DRAM_UDQM,
	output					DRAM_WE_N
	);

// ---- clocks: c0 the design, c1 DRAM_CLK (same frequency, movable phase) ----
wire	[4:0]		pclk;
wire				locked, pll_areset;
wire	[2:0]		phasecounterselect;
wire				phaseupdown, phasestep, phasedone;
pll_de10_dps #(.C0_MUL(MUL), .C0_DIV(DIV), .C1_MUL(MUL), .C1_DIV(DIV), .C1_PHASE(C1_PHASE)) pll(
	.areset(pll_areset | ~KEY[0]), .inclk0(MAX10_CLK1_50), .clk(pclk), .locked(locked),
	.scanclk(MAX10_CLK1_50), .phasecounterselect(phasecounterselect), .phaseupdown(phaseupdown),
	.phasestep(phasestep), .phasedone(phasedone));
wire				clk = pclk[0];
assign DRAM_CLK = pclk[1];

reg	[2:0]		lk = 0;
always @(posedge clk) lk <= {lk[1:0], locked};
wire				rst_n = lk[2];

// ---- the PC's registers ----
wire	[15:0]	addr;
wire	[31:0]	wdata;
wire				we, jbusy;
reg	[31:0]	rdata;
jtag_regs #(.INSTANCE(1), .ID(32'h4D54_1501)) regs(.clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata),
	.we(we), .rdata(rdata), .busy(jbusy));

wire				sel_test = (addr[15:5] == 11'd0);
wire				sel_top  = (addr[15:5] == 11'd1);

// ---- the memory test on the burst controller ----
wire	[2:0]		rd_delay;
wire				cmd_valid, cmd_ready, cmd_we, wvalid, wready, rvalid, done, init_done, stat_busy, stat_refresh;
wire	[24:0]	cmd_addr;
wire	[10:0]	cmd_len;
wire	[15:0]	wd, rd;
wire	[31:0]	test_rdata, errors;
wire				running, finished, pass;
sdram_memtest #(.VERSION(16'h0001)) test(.clk(clk), .rst_n(rst_n),
	.reg_addr(addr[4:0]), .reg_wdata(wdata), .reg_we(we && sel_test), .reg_rdata(test_rdata),
	.rd_delay(rd_delay), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
	.cmd_len(cmd_len), .wdata(wd), .wvalid(wvalid), .wready(wready), .rdata(rd), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh),
	.running(running), .finished(finished), .pass(pass), .errors(errors));

sdram_burst_ctrl #(.CLK_MHZ(CLK_MHZ)) ctrl(.clk(clk), .rst_n(rst_n), .rd_delay(rd_delay),
	.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
	.wdata(wd), .wvalid(wvalid), .wready(wready), .rdata(rd), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh),
	.DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_CAS_N(DRAM_CAS_N), .DRAM_CKE(DRAM_CKE), .DRAM_CS_N(DRAM_CS_N),
	.DRAM_DQ(DRAM_DQ), .DRAM_LDQM(DRAM_LDQM), .DRAM_RAS_N(DRAM_RAS_N), .DRAM_UDQM(DRAM_UDQM), .DRAM_WE_N(DRAM_WE_N));

// ---- the DRAM_CLK phase ----
wire				ph_busy, ph_error, ph_no_ack;
wire	[15:0]	ph_pos;
wire				ph_write = we && sel_top && (addr[4:0] == 5'd0);
pll_phase_step #(.COUNTER(3'd3)) stepper(.clk(clk), .rst_n(rst_n),				// counter 3 = c1
	.step_req(ph_write && !wdata[16]), .step_n(wdata[7:0]), .step_up(wdata[8]),
	.reset_req(ph_write && wdata[16]), .busy(ph_busy), .error(ph_error), .no_ack(ph_no_ack), .pos(ph_pos),
	.scanclk(MAX10_CLK1_50), .phasecounterselect(phasecounterselect), .phaseupdown(phaseupdown),
	.phasestep(phasestep), .phasedone(phasedone), .pll_areset(pll_areset));

reg	[31:0]	cycles = 0;
always @(posedge clk) cycles <= cycles + 1'b1;

wire	[15:0]	step_ps = STEP_PS, phase_ps = PHASE_PS;
wire	[31:0]	clk_mhz = CLK_MHZ;
always @(*)
	if (sel_test) rdata = test_rdata;
	else if (sel_top)
		case (addr[4:0])
			5'd0:		rdata = {ph_error, ph_busy, ph_no_ack, 13'd0, ph_pos};
			5'd1:		rdata = {step_ps, phase_ps};
			5'd2:		rdata = cycles;
			5'd3:		rdata = clk_mhz;
			default:	rdata = 32'd0;
		endcase
	else rdata = 32'd0;

// ---- display: errors in hex, or the phase position ----
wire	[15:0]	pos_abs = ph_pos[15] ? -ph_pos : ph_pos;
wire	[23:0]	shown = SW[0] ? {8'd0, pos_abs} : errors[23:0];
wire	[7:0]		seg [0:5];
genvar i;
generate
	for (i = 0; i < 6; i = i + 1) begin : digit
		wire [3:0] nib = shown[4*i +: 4];
		wire [7:0] ch = (nib < 4'd10) ? 8'h30 + nib : 8'h37 + nib;		// 0-9, A-F
		wire minus = SW[0] && (i == 5) && ph_pos[15];
		seg7_char c(.ch(minus ? "-" : ch), .dp(1'b0), .seg(seg[i]));
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

reg	[19:0]	act = 0;
always @(posedge clk) act <= jbusy ? 20'hFFFFF : (act != 0 ? act - 1'b1 : 20'd0);
assign LEDR = {2'b00, act != 0, ph_error, ph_busy, locked, pass, finished, running, init_done};

endmodule

`default_nettype wire
