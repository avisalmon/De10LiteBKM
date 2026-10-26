// Magnitude to bar height: one FFT output (re, im) per clock in, its bar height in pixels 6 clocks later
//
// pw = re^2 + im^2; p = the top set bit of pw, m = the 5 bits under it; e = p + off (clamped 0..63);
// px = rom[{lin, e, m}] (mag_rom). off scales each FFT to the same full scale: our FFT divides by 256
// (off = 16), the IP by 2^-exp (off = -2 exp); +2 with the Hann window (it halves the amplitude). pw = 0 -> 0.
// Python twin: sim/lab_model.py mag_px; unit test: sim/tb_mag.sv.
// ***********************************************
`default_nettype none

module mag_px (
	input		wire						clk,
	input		wire						in_valid,
	input		wire			[7:0]		in_k,
	input		wire signed	[15:0]	re,
	input		wire signed	[15:0]	im,
	input		wire signed	[7:0]		off,
	input		wire						lin,
	output	logic			[11:0]	rom_addr = 12'd0,
	input		wire			[6:0]		rom_q,
	output	logic						out_valid = 1'b0,
	output	logic			[7:0]		out_k = 8'd0,
	output	logic			[6:0]		px = 7'd0
	);

function automatic [4:0] msb32(input [31:0] v);
	integer i;
	begin
		msb32 = 5'd0;
		for (i = 0; i < 32; i = i + 1)
			if (v[i]) msb32 = i[4:0];
	end
endfunction

// s1: inputs
logic						v1 = 1'b0, lin1 = 1'b0;
logic			[7:0]		k1 = 8'd0;
logic signed [15:0]	re1 = 16'sd0, im1 = 16'sd0;
logic signed [7:0]	off1 = 8'sd0;
// s2: power
logic						v2 = 1'b0, lin2 = 1'b0;
logic			[7:0]		k2 = 8'd0;
logic signed [7:0]	off2 = 8'sd0;
logic			[31:0]	pw2 = 32'd0;
wire signed [31:0]	rr = re1 * re1, ii = im1 * im1;
// s3: top bit
logic						v3 = 1'b0, lin3 = 1'b0, z3 = 1'b0;
logic			[7:0]		k3 = 8'd0;
logic signed [7:0]	off3 = 8'sd0;
logic			[31:0]	pw3 = 32'd0;
logic			[4:0]		p3 = 5'd0;
// s4: ROM address; s5: ROM data
logic						v4 = 1'b0, v5 = 1'b0, z4 = 1'b0, z5 = 1'b0;
logic			[7:0]		k4 = 8'd0, k5 = 8'd0;
wire			[31:0]	norm = pw3 << (5'd31 - p3);
wire signed [8:0]		e_raw = $signed({4'b0000, p3}) + off3;
wire			[5:0]		e = (e_raw < 0) ? 6'd0 : (e_raw > 63) ? 6'd63 : e_raw[5:0];

always @(posedge clk) begin
	v1 <= in_valid; k1 <= in_k; re1 <= re; im1 <= im; off1 <= off; lin1 <= lin;
	v2 <= v1; k2 <= k1; off2 <= off1; lin2 <= lin1;
	pw2 <= $unsigned(rr) + $unsigned(ii);
	v3 <= v2; k3 <= k2; off3 <= off2; lin3 <= lin2;
	pw3 <= pw2; p3 <= msb32(pw2); z3 <= (pw2 == 32'd0);
	v4 <= v3; k4 <= k3; z4 <= z3;
	rom_addr <= {lin3, e, norm[30:26]};
	v5 <= v4; k5 <= k4; z5 <= z4;
	out_valid <= v5; out_k <= k5;
	px <= z5 ? 7'd0 : rom_q;
end

endmodule

`default_nettype wire
