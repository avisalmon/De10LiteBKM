// The system around the CPU: address decode, the 32 KB RAM, the text-screen RAM, the I/O registers.
// The memory map is tools/memmap.py; the numbers here must match it (tests/test_memmap.py checks).
//
//   0x0000_0000  RAM      32 KB
//   0x1000_0000  TEXT     80 x 60 words: [7:0] char, [11:8] fg, [15:12] bg (write only; the screen reads port B)
//   0x2000_0000  I/O      +00 BUTTONS r, +04 FRAME r, +08 RANDOM r, +0C HEX w, +10 LEDS w, +14 BUZZER w,
//                         +18 UART w / busy r, +1C SWITCHES r, +20 CYCLES r, +24 EXIT w
// ***********************************************
`default_nettype none

module rv32_soc #(
	parameter RAM_IMPL = "SIM",
	parameter PROG_FILE = "build/tetris.hex"
)(
	input		wire				clk,				// 25 MHz
	input		wire				rst_n,
	input		wire				tick,				// one clock per frame
	input		wire	[9:0]		buttons,			// 1 = held: {KEY1, KEY0, Left, Right, Up, Down, Start, Select, B, A}
	input		wire	[9:0]		switches,
	// the text screen's read port (25 MHz, one clock latency)
	input		wire	[12:0]	text_addr,
	output	wire	[15:0]	text_q,
	// outputs
	output	logic	[23:0]	hex,
	output	logic	[9:0]		leds,
	output	logic	[15:0]	buzzer_half,
	// UART to the PC
	output	logic	[7:0]		tx_data,
	output	logic				tx_valid,
	input		wire				tx_ready,
	// status
	output	logic				exit_valid,		// the program wrote EXIT
	output	logic	[31:0]	exit_code,
	output	wire				halted,
	output	wire				fault,
	// trace for the testbench
	output	wire				trace_valid,
	output	wire	[31:0]	trace_pc,
	output	wire	[4:0]		trace_rd,
	output	wire	[31:0]	trace_data,
	output	wire				bus_write,		// a write on the bus (for the trace): addr / wdata / be below
	output	wire	[31:0]	bus_addr_o,
	output	wire	[31:0]	bus_wdata_o,
	output	wire	[3:0]		bus_be_o
	);

wire				req, we;
wire	[31:0]	addr, wdata;
wire	[3:0]		be;
logic	[31:0]	rdata;
logic				ack;

rv32_cpu cpu(.clk(clk), .rst_n(rst_n), .bus_req(req), .bus_we(we), .bus_addr(addr), .bus_wdata(wdata), .bus_be(be),
	.bus_rdata(rdata), .bus_ack(ack), .halted(halted), .fault(fault),
	.trace_valid(trace_valid), .trace_pc(trace_pc), .trace_rd(trace_rd), .trace_data(trace_data));

// ---- decode
wire	sel_ram  = (addr[31:28] == 4'h0);
wire	sel_text = (addr[31:28] == 4'h1);
wire	sel_io   = (addr[31:28] == 4'h2);
wire	first    = req && !ack;				// the first clock of an access: writes happen here, reads are issued
assign bus_write   = first && we;
assign bus_addr_o  = addr;
assign bus_wdata_o = wdata;
assign bus_be_o    = be;

always_ff @(posedge clk or negedge rst_n)
	if (!rst_n) ack <= 1'b0;
	else ack <= first;

// ---- RAM
wire	[31:0]	ram_q;
soc_ram #(.IMPL(RAM_IMPL), .INIT_FILE(PROG_FILE)) ram(
	.clk(clk), .addr(addr[14:2]), .wdata(wdata), .be(be), .we(first && we && sel_ram), .q(ram_q));

// ---- text RAM: 4800 x 16, written by the CPU, read by the screen
wire	[12:0]	text_cell = addr[14:2];		// (row * 80 + col), the program computes it
ram_dp #(.WIDTH(16), .AW(13), .DEPTH(4800)) text(
	.wr_clk(clk), .wr_addr(text_cell), .wr_d(wdata[15:0]), .we(first && we && sel_text && text_cell < 13'd4800),
	.rd_clk(clk), .rd_addr(text_addr), .rd_q(text_q));

// ---- I/O registers
logic	[31:0]	frame_cnt, cycle_cnt, lfsr;
logic	[7:0]		uart_byte;
logic				uart_pending;
logic	[31:0]	io_q;

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		frame_cnt <= 32'd0; cycle_cnt <= 32'd0; lfsr <= 32'hACE1_1234;
		hex <= 24'd0; leds <= 10'd0; buzzer_half <= 16'd0;
		uart_byte <= 8'd0; uart_pending <= 1'b0; tx_valid <= 1'b0; tx_data <= 8'd0;
		exit_valid <= 1'b0; exit_code <= 32'd0; io_q <= 32'd0;
	end else begin
		cycle_cnt <= cycle_cnt + 1'b1;
		if (tick) frame_cnt <= frame_cnt + 1'b1;
		// xorshift32, one step per clock
		lfsr <= lfsr ^ (lfsr << 13) ^ ((lfsr ^ (lfsr << 13)) >> 17) ^
		        (((lfsr ^ (lfsr << 13)) ^ ((lfsr ^ (lfsr << 13)) >> 17)) << 5);
		tx_valid <= 1'b0;
		if (uart_pending && tx_ready && !tx_valid) begin
			tx_valid <= 1'b1; tx_data <= uart_byte; uart_pending <= 1'b0;
		end
		if (first && sel_io) begin
			if (we) case (addr[7:2])
				6'h03: hex <= wdata[23:0];
				6'h04: leds <= wdata[9:0];
				6'h05: buzzer_half <= wdata[15:0];
				6'h06: begin uart_byte <= wdata[7:0]; uart_pending <= 1'b1; end
				6'h09: begin exit_valid <= 1'b1; exit_code <= wdata; end
				default: ;
			endcase
			else case (addr[7:2])
				6'h00: io_q <= {22'd0, buttons};
				6'h01: io_q <= frame_cnt;
				6'h02: io_q <= lfsr;
				6'h06: io_q <= {31'd0, uart_pending};
				6'h07: io_q <= {22'd0, switches};
				6'h08: io_q <= cycle_cnt;
				default: io_q <= 32'd0;
			endcase
		end
	end
end

// ---- read mux (valid in the ack clock)
logic	sel_ram_q, sel_io_q;
always_ff @(posedge clk) begin sel_ram_q <= sel_ram; sel_io_q <= sel_io; end
always_comb
	if (sel_ram_q) rdata = ram_q;
	else if (sel_io_q) rdata = io_q;
	else rdata = 32'd0;

endmodule
