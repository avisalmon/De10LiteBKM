// Unit test: spi_master in mode 3 against a model device that samples MOSI on SCLK's rising edge and drives
// MISO after the falling edge (like the ADXL345). The device must receive exactly what was sent, and the master
// must receive what the device sent. (The first version changed MOSI on the rising edge: this test fails it.)
// python scripts/sim.py lib/sim/tb_spi_master.sv
// sim-sources: lib/rtl/spi_master.sv
`timescale 1ns/1ns

module tb_spi_master;

reg				clk = 0, start = 0, hold = 0;
reg	[7:0]		tx = 0;
wire	[7:0]		rx;
wire				done, busy, sclk, mosi, mosi_oe, cs_n;
reg				miso = 1;
integer			errors = 0, k;

always #10 clk = ~clk;

spi_master #(.DIV(5)) dut(.clk(clk), .start(start), .tx_byte(tx), .cs_hold(hold), .rd(1'b0), .rx_byte(rx),
	.done(done), .busy(busy), .sclk(sclk), .mosi(mosi), .mosi_oe(mosi_oe), .miso(miso), .cs_n(cs_n));

// the model device: shifts in on rising SCLK, shifts out (answer = received byte reversed) on falling SCLK
reg	[7:0]		dev_in = 0, dev_out = 0;
integer			nbits = 0;
always @(negedge cs_n) begin nbits = 0; dev_out = 8'hA5; miso = dev_out[7]; end
always @(posedge sclk) if (!cs_n) begin
	#2 dev_in = {dev_in[6:0], mosi};		// sample a little after the edge: data must still be valid (hold)
	nbits = nbits + 1;
end
always @(negedge sclk) if (!cs_n && nbits > 0) begin
	dev_out = {dev_out[6:0], 1'b0};
	miso = dev_out[7];
end

task xfer(input [7:0] b);
	begin
		@(negedge clk) begin tx = b; start = 1; end
		@(negedge clk) start = 0;
		@(posedge done); #1;
		if (dev_in !== b) begin errors = errors + 1; $display("device got %h, sent %h", dev_in, b); end
		if (rx !== 8'hA5) begin errors = errors + 1; $display("master got %h, device sent A5", rx); end
	end
endtask

initial begin
	for (k = 0; k < 8; k = k + 1) xfer(8'h80 >> k | 8'h01 << k);
	xfer(8'hF2); xfer(8'h31); xfer(8'h00); xfer(8'hFF);
	$display("%0d errors", errors);
	if (errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

endmodule
