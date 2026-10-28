`default_nettype none
// Example 15: the SDRAM stream fabric on the board
//
// One 100 MHz burst controller (lib/rtl/sdram_burst_ctrl.sv) feeds N read channels and takes N write-back lanes
// (lib/rtl/stream_fabric.sv); behind channel u sits compute unit u (lib/rtl/matvec_unit.sv: y = W . x for T vectors,
// int8 weights streaming from the SDRAM, int32 results back to it through lane u). The loader of example 14
// (lib/rtl/sdram_loader.sv, virtual JTAG instance 0, scripts/sdram_load.py) fills and checks the SDRAM through the
// fabric's single-word port, unchanged. The PC drives everything else through 32-bit registers
// (lib/rtl/jtag_regs.sv, instance 1; scripts/fabric_ctl.py). The DRAM_CLK phase can be moved at run time
// (lib/rtl/pll_phase_step.sv), as in the memory test of memtest/ that found it.
//
// Register map (spec.html section 5). This top owns:
//   0x000 ID        0x5F15_0001
//   0x002 STATUS    bit 0 init_done, 1 pll_locked, 2 a channel running, 3 a unit busy, 4 the loader on the bus,
//                   5 fabric fault (must never set), 6 idle, [15:8] N, [23:16] T_MAX, [31:24] log2 MAX_BURST
//   0x008 PHASE     write: [7:0] steps, [8] 1 = later, [16] 1 = reset the PLL (everything restarts); read: [15:0]
//                   steps from the compiled phase (signed), [29] no phasedone seen, [30] busy, [31] no answer
//   0x009 INFO      [15:0] the compiled DRAM_CLK phase in ps, [31:16] one step in ps
//   0x00A CYCLES    free-running clock counter (read twice: the design's clock)
//   0x00B CLK_MHZ   what the design was built for
//   0x00C LOADED    words the loader wrote since its last WADDR
// The fabric owns 0x001 CTRL, 0x003 RD_DELAY, 0x004..0x007 the counters, 0x010 + 8c the channels, 0x080 + 4u the
// lanes; unit u owns 0x100 + 16u; 0x1F0 is the units' broadcast address.
// HEX5..0: SW1 up the DRAM_CLK phase position (hex, - when negative); else SW0 up unit 0's ROWS_DONE, SW0 down
// the KB the loader wrote (decimal). LEDR0 SDRAM ready, 1 a channel running, 2 a unit busy, 3 a lane busy,
// 4 PLL locked, 5 the loader on the bus, 6 fabric fault, 7 the PC is talking, 8 phase stepper busy, 9 the loader
// lost a word. KEY0 resets the PLL (and so everything).
// ***********************************************

module fabric_top #(
	parameter N = 6,													// channels = lanes = units
	parameter T_MAX = 8,												// x-vectors per unit
	parameter DEPTH = 1024,											// channel FIFO, words
	parameter LANE_DEPTH = 64,										// lane FIFO, results
	parameter MAX_BURST = 1024,
	parameter CLK_MHZ = 100,
	parameter MUL = 2, DIV = 1,									// CLK_MHZ = 50 * MUL / DIV
	parameter C1_PHASE = "6875",										// DRAM_CLK phase in ps, as the PLL wants it: the centre of
																			// the window the memtest sweep measured (33 steps of 208 ps)
	parameter [15:0] PHASE_PS = 6875,								// the same number, for INFO
	parameter [15:0] STEP_PS = 208								// one phase step = VCO period / 8 (600 MHz VCO)
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
`ifdef FABRIC_TOP_SIM
	,
	input						sim_clk,										// the PLL is not simulated: the testbench gives clk
	input						sim_tck,										// the two virtual JTAG nodes, driven by the testbench
	input						sim_tdi_regs,								// (build with -D FABRIC_TOP_SIM -D JTAG_REGS_SIM
	input			[3:0]		sim_ir_regs,								//  -D SDRAM_LOADER_SIM)
	input						sim_cdr_regs, sim_sdr_regs, sim_udr_regs, sim_uir_regs,
	output					sim_tdo_regs,
	input						sim_tdi_ld,
	input			[3:0]		sim_ir_ld,
	input						sim_cdr_ld, sim_sdr_ld, sim_udr_ld, sim_uir_ld,
	output					sim_tdo_ld
`endif
	);

localparam [31:0] ID = 32'h5F15_0001;
localparam [7:0]  LOG2_BURST = 8'($clog2(MAX_BURST));

// ---- clocks: c0 the design, c1 DRAM_CLK (same frequency, movable phase) ----
wire				clk, locked, pll_areset;
wire	[2:0]		phasecounterselect;
wire				phaseupdown, phasestep, phasedone;
`ifdef FABRIC_TOP_SIM
assign clk = sim_clk;
assign DRAM_CLK = ~sim_clk;											// 180 degrees, as example 06's controller had it
assign locked = 1'b1;
assign phasedone = 1'b1;
`else
wire	[4:0]		pclk;
pll_de10_dps #(.C0_MUL(MUL), .C0_DIV(DIV), .C1_MUL(MUL), .C1_DIV(DIV), .C1_PHASE(C1_PHASE)) pll(
	.areset(pll_areset | ~KEY[0]), .inclk0(MAX10_CLK1_50), .clk(pclk), .locked(locked),
	.scanclk(MAX10_CLK1_50), .phasecounterselect(phasecounterselect), .phaseupdown(phaseupdown),
	.phasestep(phasestep), .phasedone(phasedone));
assign clk = pclk[0];
assign DRAM_CLK = pclk[1];
`endif

// The reset synchronizer. Without the attribute Quartus turns this 3-bit shift register into an altshift_taps in
// an M9K block (auto shift-register replacement): one wasted M9K, and a reset that comes out of a RAM.
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
reg	[2:0]		lk = 0;
always @(posedge clk) lk <= {lk[1:0], locked};
wire				rst_n = lk[2];

// ---- the PC's registers ----
wire	[15:0]	addr;
wire	[31:0]	wdata;
wire				we, jbusy;
wire	[31:0]	rdata;
jtag_regs #(.INSTANCE(1), .ID(ID)) regs(.clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata),
	.we(we), .rdata(rdata), .busy(jbusy)
`ifdef FABRIC_TOP_SIM
	, .sim_tck(sim_tck), .sim_tdi(sim_tdi_regs), .sim_ir_in(sim_ir_regs), .sim_cdr(sim_cdr_regs),
	.sim_sdr(sim_sdr_regs), .sim_udr(sim_udr_regs), .sim_uir(sim_uir_regs), .sim_tdo(sim_tdo_regs)
`endif
	);

// ---- the controller ----
wire	[2:0]		rd_delay;
wire				cmd_valid, cmd_ready, cmd_we, wvalid, wready, rvalid, done, init_done, stat_busy, stat_refresh;
wire	[24:0]	cmd_addr;
wire	[10:0]	cmd_len;
wire	[15:0]	wd, rd;
sdram_burst_ctrl #(.CLK_MHZ(CLK_MHZ)) ctrl(.clk(clk), .rst_n(rst_n), .rd_delay(rd_delay),
	.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
	.wdata(wd), .wvalid(wvalid), .wready(wready), .rdata(rd), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh),
	.DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_CAS_N(DRAM_CAS_N), .DRAM_CKE(DRAM_CKE), .DRAM_CS_N(DRAM_CS_N),
	.DRAM_DQ(DRAM_DQ), .DRAM_LDQM(DRAM_LDQM), .DRAM_RAS_N(DRAM_RAS_N), .DRAM_UDQM(DRAM_UDQM), .DRAM_WE_N(DRAM_WE_N));

// ---- the loader of example 14 on the fabric's single-word port ----
wire				lg_req, lg_we, lg_ready, lg_rvalid;
wire	[24:0]	lg_addr;
wire	[15:0]	lg_wdata, lg_rdata;
wire	[31:0]	words_written;
wire				ld_reading, ld_check, ld_busy, ld_error;
reg	[31:0]	cycles = 0;
sdram_loader #(.INSTANCE(0)) loader(.clk(clk), .reset_n(rst_n), .req(lg_req), .we(lg_we), .addr(lg_addr),
	.wdata(lg_wdata), .ready(lg_ready), .rvalid(lg_rvalid), .rdata(lg_rdata), .init_done(init_done),
	.user0(ID), .user1(cycles), .words_written(words_written), .reading(ld_reading), .check_busy(ld_check),
	.busy(ld_busy), .error(ld_error)
`ifdef FABRIC_TOP_SIM
	, .sim_tck(sim_tck), .sim_tdi(sim_tdi_ld), .sim_ir_in(sim_ir_ld), .sim_cdr(sim_cdr_ld), .sim_sdr(sim_sdr_ld),
	.sim_udr(sim_udr_ld), .sim_uir(sim_uir_ld), .sim_tdo(sim_tdo_ld)
`endif
	);

// ---- the fabric ----
wire	[N*16-1:0]	ch_dout;
wire	[N-1:0]		ch_valid, ch_rd_en, wb_valid, wb_ready, wb_flush, unit_busy;
wire	[N*32-1:0]	wb_data;
wire	[31:0]		fab_rdata;
wire	[3:0]			unit_ctrl;
wire					any_running, lanes_busy, legacy_busy, idle, fault;
stream_fabric #(.N(N), .DEPTH(DEPTH), .LANE_DEPTH(LANE_DEPTH), .MAX_BURST(MAX_BURST)) fabric(
	.clk(clk), .rst_n(rst_n), .uclk(clk), .urst_n(rst_n),
	.cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
	.wdata(wd), .wvalid(wvalid), .wready(wready), .rdata(rd), .rvalid(rvalid), .done(done),
	.init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh), .rd_delay(rd_delay),
	.lg_req(lg_req), .lg_we(lg_we), .lg_addr(lg_addr), .lg_wdata(lg_wdata), .lg_ready(lg_ready),
	.lg_rvalid(lg_rvalid), .lg_rdata(lg_rdata),
	.ch_dout(ch_dout), .ch_valid(ch_valid), .ch_rd_en(ch_rd_en),
	.wb_data(wb_data), .wb_valid(wb_valid), .wb_ready(wb_ready), .wb_flush(wb_flush),
	.reg_addr(addr), .reg_wdata(wdata), .reg_we(we), .reg_rdata(fab_rdata), .unit_ctrl(unit_ctrl),
	.any_running(any_running), .lanes_busy(lanes_busy), .legacy_busy(legacy_busy), .idle(idle), .fault(fault));

// ---- the compute units ----
wire	[31:0]		unit_rdata [0:N-1];
wire	[19:0]		unit_rows [0:N-1];
genvar u;
generate
	for (u = 0; u < N; u = u + 1) begin : unit
		matvec_unit #(.T_MAX(T_MAX), .REG_BASE(16'h0100 + 16'd16 * u), .REG_BCAST(16'h01F0)) mv(
			.clk(clk), .rst_n(rst_n),
			.s_data(ch_dout[u*16 +: 16]), .s_valid(ch_valid[u]), .s_rd_en(ch_rd_en[u]),
			.wb_data(wb_data[u*32 +: 32]), .wb_valid(wb_valid[u]), .wb_ready(wb_ready[u]), .wb_flush(wb_flush[u]),
			.g_ctrl(unit_ctrl), .reg_addr(addr), .reg_wdata(wdata), .reg_we(we), .reg_rdata(unit_rdata[u]),
			.busy(unit_busy[u]), .rows_out(unit_rows[u]));
	end
endgenerate
wire	[19:0]		rows_done0 = unit_rows[0];

// ---- the DRAM_CLK phase ----
wire				ph_busy, ph_error, ph_no_ack;
wire	[15:0]	ph_pos;
wire				sel_top  = (addr[15:4] == 12'd0) && addr[3];						// 0x008..0x00F
wire				ph_write = we && sel_top && (addr[2:0] == 3'd0);
`ifdef FABRIC_TOP_SIM
assign ph_busy = 1'b0; assign ph_error = 1'b0; assign ph_no_ack = 1'b0; assign ph_pos = 16'd0;
assign pll_areset = 1'b0; assign phasecounterselect = 3'd0; assign phaseupdown = 1'b0; assign phasestep = 1'b0;
`else
pll_phase_step #(.COUNTER(3'd3)) stepper(.clk(clk), .rst_n(rst_n),				// counter 3 = c1
	.step_req(ph_write && !wdata[16]), .step_n(wdata[7:0]), .step_up(wdata[8]),
	.reset_req(ph_write && wdata[16]), .busy(ph_busy), .error(ph_error), .no_ack(ph_no_ack), .pos(ph_pos),
	.scanclk(MAX10_CLK1_50), .phasecounterselect(phasecounterselect), .phaseupdown(phaseupdown),
	.phasestep(phasestep), .phasedone(phasedone), .pll_areset(pll_areset));
`endif

// ---- the top's registers; rdata is the OR of every block's (each is 0 when not addressed) ----
always @(posedge clk) cycles <= cycles + 1'b1;
wire	[15:0]	step_ps = STEP_PS, phase_ps = PHASE_PS;
wire	[31:0]	clk_mhz = CLK_MHZ;
wire	[31:0]	status = {LOG2_BURST, 8'(T_MAX), 8'(N), 1'b0, idle, fault, legacy_busy, |unit_busy, any_running,
								 locked, init_done};
reg	[31:0]	top_rdata = 0;
always @(posedge clk)
	if (addr[15:4] != 12'd0) top_rdata <= 32'd0;
	else case (addr[3:0])
		4'd0:		top_rdata <= ID;
		4'd2:		top_rdata <= status;
		4'd8:		top_rdata <= {ph_error, ph_busy, ph_no_ack, 13'd0, ph_pos};
		4'd9:		top_rdata <= {step_ps, phase_ps};
		4'd10:	top_rdata <= cycles;
		4'd11:	top_rdata <= clk_mhz;
		4'd12:	top_rdata <= words_written;
		default:	top_rdata <= 32'd0;
	endcase

reg	[31:0]	units_rdata;
integer		k;
always @(*) begin
	units_rdata = 32'd0;
	for (k = 0; k < N; k = k + 1) units_rdata = units_rdata | unit_rdata[k];
end
assign rdata = top_rdata | fab_rdata | units_rdata;

// ---- display ----
wire	[15:0]	pos_abs = ph_pos[15] ? -ph_pos : ph_pos;
wire	[19:0]	num = SW[0] ? rows_done0[19:0] : words_written[28:9];				// rows, or KB (512 words)
wire	[23:0]	bcd;
bin2bcd #(.BITS(20), .DIGITS(6)) dec(.bin(num > 20'd999999 ? 20'd999999 : num), .bcd(bcd));
wire	[23:0]	shown = SW[1] ? {8'd0, pos_abs} : bcd;
wire	[7:0]		seg [0:5];
genvar i;
generate
	for (i = 0; i < 6; i = i + 1) begin : digit
		wire [3:0] nib = shown[4*i +: 4];
		wire [7:0] hexch = (nib < 4'd10) ? 8'h30 + nib : 8'h37 + nib;		// 0-9, A-F
		wire blank = !SW[1] && (i > 0) && (shown[23:4*i] == 0);
		wire minus = SW[1] && (i == 5) && ph_pos[15];
		seg7_char c(.ch(minus ? "-" : (blank ? " " : hexch)), .dp(1'b0), .seg(seg[i]));
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};

reg	[19:0]	act = 0;
always @(posedge clk) act <= (jbusy || ld_busy) ? 20'hFFFFF : (act != 0 ? act - 1'b1 : 20'd0);
assign LEDR = {ld_error, ph_busy, act != 0, fault, legacy_busy, locked, lanes_busy, |unit_busy, any_running,
					init_done};

endmodule

`default_nettype wire
