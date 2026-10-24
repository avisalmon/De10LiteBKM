// JTAG UART without a CPU: a byte stream to and from the PC over the USB-Blaster cable
//
// Wraps alt_jtag_atlantic, the primitive inside Altera's JTAG UART IP, with a TX FIFO.
// PC side: juart-terminal / nios2-terminal (they find the instance on the JTAG chain).
// Handshake (from the JTAG UART IP source): FPGA -> PC, the primitive raises r_ena when
// it can take a byte, we pop one and present it on r_dat with r_val the next clock.
// PC -> FPGA, a byte arrives on t_dat with t_ena; t_dav tells the primitive we have room.
//
// Simulation: define JTAG_UART_SIM to replace the primitive with a stand-in that
// accepts every TX byte (shown in tx_seen) and injects RX bytes through sim_rx_*.
// ***********************************************

module jtag_uart #(
	parameter LOG2_TX_DEPTH = 9		// 512-byte TX FIFO
)(
	input					clk,
	input					resetN,
	// FPGA -> PC
	input		[7:0]		tx_data,
	input					tx_valid,	// write tx_data when tx_ready
	output				tx_ready,
	// PC -> FPGA
	output	[7:0]		rx_data,
	output				rx_valid		// one clock per received byte
`ifdef JTAG_UART_SIM
	,
	input		[7:0]		sim_rx_data,
	input					sim_rx_valid,
	output reg [7:0]	tx_seen,
	output reg			tx_seen_valid
`endif
	);

localparam DEPTH = 1 << LOG2_TX_DEPTH;

reg	[7:0]						mem [0:DEPTH-1];
reg	[LOG2_TX_DEPTH:0]		wr_ptr = 0;
reg	[LOG2_TX_DEPTH:0]		rd_ptr = 0;
reg	[7:0]						r_dat = 0;
reg								r_val = 0;
wire								r_ena;
wire	[7:0]						t_dat;
wire								t_ena;
wire								t_pause;
wire								empty;
wire								full;

assign empty = (wr_ptr == rd_ptr);
assign full  = (wr_ptr[LOG2_TX_DEPTH] != rd_ptr[LOG2_TX_DEPTH]) &&
               (wr_ptr[LOG2_TX_DEPTH-1:0] == rd_ptr[LOG2_TX_DEPTH-1:0]);
assign tx_ready = ~full;

always @(posedge clk) begin
	if (tx_valid && !full) begin
		mem[wr_ptr[LOG2_TX_DEPTH-1:0]] <= tx_data;
		wr_ptr <= wr_ptr + 1'b1;
	end
	r_val <= r_ena && !empty;
	if (r_ena && !empty) begin
		r_dat <= mem[rd_ptr[LOG2_TX_DEPTH-1:0]];
		rd_ptr <= rd_ptr + 1'b1;
	end
	if (!resetN) begin
		wr_ptr <= 0;
		rd_ptr <= 0;
		r_val <= 0;
	end
end

assign rx_data  = t_dat;
assign rx_valid = t_ena;

`ifdef JTAG_UART_SIM

assign r_ena   = 1'b1;
assign t_dat   = sim_rx_data;
assign t_ena   = sim_rx_valid;
assign t_pause = 1'b0;

always @(posedge clk) begin
	tx_seen_valid <= r_val;
	tx_seen <= r_dat;
end

`else

alt_jtag_atlantic #(
	.INSTANCE_ID(0),
	.LOG2_RXFIFO_DEPTH(6),
	.LOG2_TXFIFO_DEPTH(6),
	.SLD_AUTO_INSTANCE_INDEX("YES")
) jtag_atlantic (
	.clk(clk),
	.rst_n(resetN),
	.r_dat(r_dat),
	.r_val(r_val),
	.r_ena(r_ena),
	.t_dat(t_dat),
	.t_dav(1'b1),			// we take every byte at once
	.t_ena(t_ena),
	.t_pause(t_pause)
	);

`endif

endmodule
