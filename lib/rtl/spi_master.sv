// SPI master, mode 3 (clock idles high, data changes on the falling edge, sampled on the rising edge)
//
// Byte by byte, with chip select under your control: raise `start` with tx_byte; `done` pulses with rx_byte.
// Keep cs_hold = 1 between the bytes of one transfer; cs_n goes high when a byte ends with cs_hold = 0.
// 3-wire devices (one data pin both ways): set rd = 1 for the bytes you read;
// mosi_oe then goes low (release the pin) and the byte is sampled from miso: connect the shared pin to both.
// Data changes on the falling edge only, and CS stays low half a period after the last rising edge (both were bugs
// once: the ADXL345 answered garbage; lib/sim/tb_spi_master.sv checks them).
// SCLK = clk / (2 * DIV): DIV = 25 at 50 MHz -> 1 MHz. Mode 3 suits the ADXL345 and most sensors; change the
// idle level / edges here for mode 0 devices.
// ***********************************************

module spi_master #(
	parameter DIV = 25
)(
	input					clk,
	input					start,
	input		[7:0]		tx_byte,
	input					cs_hold,		// keep cs_n low after this byte
	input					rd,			// 3-wire: this byte is read on the shared data pin
	output reg	[7:0]	rx_byte = 0,
	output reg			done = 0,
	output				busy,
	output reg			sclk = 1,
	output reg			mosi = 1,
	output reg			mosi_oe = 1,	// 0 while a 3-wire read byte is clocked in
	input					miso,
	output reg			cs_n = 1
	);

reg	[7:0]		div = 0;
reg	[3:0]		bitn = 0;
reg	[7:0]		sh = 0;
reg				active = 0;
reg				hold = 0;

assign busy = active;

always @(posedge clk) begin
	done <= 0;
	if (!active) begin
		sclk <= 1;
		if (start) begin
			active <= 1;
			cs_n <= 0;
			sh <= tx_byte;
			mosi <= tx_byte[7];
			mosi_oe <= !rd;
			hold <= cs_hold;
			bitn <= 0;
			div <= 0;
		end
	end
	else if (div == DIV - 1) begin
		div <= 0;
		if (bitn == 8) begin			// half a period after the last rising edge: end the byte
			active <= 0;							// (CS must stay low a while after that edge: CS hold time)
			rx_byte <= sh;
			done <= 1;
			mosi_oe <= 1;
			if (!hold) cs_n <= 1;
		end
		else if (sclk) begin						// falling edge: the next bit goes out (bit 7 is out since start)
			sclk <= 0;
			if (bitn != 0) mosi <= sh[7];
		end
		else begin								// rising edge: the device samples now, so only read here
			sclk <= 1;
			sh <= {sh[6:0], miso};
			bitn <= bitn + 1'b1;
		end
	end
	else
		div <= div + 1'b1;
end

endmodule
