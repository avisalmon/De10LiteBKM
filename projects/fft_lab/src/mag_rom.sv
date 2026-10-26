// Bar-height ROM: 4096 x 7 bits, two read ports (one per FFT), one clock to read
//
// Address {lin, e[5:0], m[4:0]}: the power |X|^2 = 2^e x (1 + (m + 0.5) / 32) -> the bar height in pixels,
// 0..90: 1 px per dB (lin = 0) or the amplitude, full scale 90 px (lin = 1). Made by sim/lab_model.py make.
// The file is binary, 7 digits per line ($readmemb): 7 bits are not whole hex digits, and hex would make Quartus
// warn once per line (10230, truncated value), 4096 warnings burying the real ones.
// ***********************************************
`default_nettype none

module mag_rom #(
	parameter FILE = "assets/mag_rom.bin"
)(
	input		wire				clk,
	input		wire	[11:0]	addr_a,
	output	logic	[6:0]		q_a = 7'd0,
	input		wire	[11:0]	addr_b,
	output	logic	[6:0]		q_b = 7'd0
	);

logic	[6:0]		rom [0:4095];
initial $readmemb(FILE, rom);

always @(posedge clk) begin
	q_a <= rom[addr_a];
	q_b <= rom[addr_b];
end

endmodule

`default_nettype wire
