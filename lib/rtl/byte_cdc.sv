// Byte stream from one clock to another: a small dual-clock FIFO (Gray-coded pointers)
//
// Write side: like jtag_uart's input (wr_ready = room; the sender answers wr_ready with wr_valid + wr_data,
// one byte per wr_valid). Read side: like a sender in lib/rtl (rd_valid answers rd_ready one clock later),
// so it plugs into tx_mux or jtag_uart. Each pointer crosses as Gray code through two flops: only one bit
// changes per step, so the other side never sees a half-updated pointer.
// ***********************************************

module byte_cdc #(
	parameter AW = 4						// 16 bytes
)(
	input					wr_clk,
	input		[7:0]		wr_data,
	input					wr_valid,
	output				wr_ready,
	input					rd_clk,
	output reg	[7:0]	rd_data,
	output reg			rd_valid = 0,
	input					rd_ready
	);

reg	[7:0]		mem [0:(1<<AW)-1];
reg	[AW:0]	wbin = 0, rbin = 0;			// binary pointers (one extra bit: full vs empty)
reg	[AW:0]	wgray = 0, rgray = 0;
reg	[AW:0]	wgray_r1 = 0, wgray_r2 = 0;	// write pointer seen by the read clock
reg	[AW:0]	rgray_w1 = 0, rgray_w2 = 0;	// read pointer seen by the write clock

function automatic [AW:0] g2b(input [AW:0] g);
	integer i;
	begin
		g2b[AW] = g[AW];
		for (i = AW - 1; i >= 0; i = i - 1) g2b[i] = g2b[i + 1] ^ g[i];
	end
endfunction

// write side
wire	[AW:0]	rbin_w = g2b(rgray_w2);
wire				full = (wbin[AW] != rbin_w[AW]) && (wbin[AW-1:0] == rbin_w[AW-1:0]);
assign wr_ready = !full;
always @(posedge wr_clk) begin
	{rgray_w2, rgray_w1} <= {rgray_w1, rgray};
	if (wr_valid && !full) begin
		mem[wbin[AW-1:0]] <= wr_data;
		wbin <= wbin + 1'b1;
		wgray <= (wbin + 1'b1) ^ ((wbin + 1'b1) >> 1);
	end
end

// read side
wire	[AW:0]	wbin_r = g2b(wgray_r2);
wire				empty = (wbin_r == rbin);
always @(posedge rd_clk) begin
	{wgray_r2, wgray_r1} <= {wgray_r1, wgray};
	rd_valid <= 0;
	if (rd_ready && !rd_valid && !empty) begin
		rd_data <= mem[rbin[AW-1:0]];
		rd_valid <= 1;
		rbin <= rbin + 1'b1;
		rgray <= (rbin + 1'b1) ^ ((rbin + 1'b1) >> 1);
	end
end

endmodule
