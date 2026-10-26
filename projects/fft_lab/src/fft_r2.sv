// Our own FFT: 256 points, radix-2 decimation in time, in place, one butterfly unit, 16-bit fixed point
//
// Feed 256 complex samples (in_valid + in_re/in_im, natural order, any pace) -> it computes -> out_valid gives the
// 256 results in natural order (out_k = 0..255). Every stage halves its results, so the output is FFT(x) / 256 and
// nothing can overflow. Cost: one RAM (256 x 32), one twiddle ROM (128 x 32), 4 multipliers, one butterfly
// every 5 clocks: 1,024 butterflies = ~5,200 clocks (104 us at 50 MHz). Simple on purpose, to compare with the IP.
// ***********************************************

module fft_r2 #(
	parameter TWIDDLE_FILE = "assets/twiddle.hex"
)(
	input							clk,
	input							in_valid,
	input	signed [15:0]		in_re,
	input	signed [15:0]		in_im,
	output reg					out_valid = 0,
	output reg	[7:0]			out_k = 0,
	output reg signed [15:0]	out_re = 0,
	output reg signed [15:0]	out_im = 0,
	output						busy
	);

// ---- memory: data RAM (two ports) and the twiddle ROM: W(k) = cos(2 pi k/256) - j sin(2 pi k/256), Q15
reg	[31:0]	ram [0:255];
reg	[31:0]	tw [0:127];
initial $readmemh(TWIDDLE_FILE, tw);

reg	[7:0]		addr_a, addr_b;
reg	[31:0]	q_a, q_b, w_q;
reg	[31:0]	d_a, d_b;
reg				we_a = 0, we_b = 0;
reg	[6:0]		tw_addr = 0;
always @(posedge clk) begin
	if (we_a) ram[addr_a] <= d_a;
	q_a <= ram[addr_a];
end
always @(posedge clk) begin
	if (we_b) ram[addr_b] <= d_b;
	q_b <= ram[addr_b];
end
always @(posedge clk) w_q <= tw[tw_addr];

// ---- control
localparam IDLE = 0, LOAD = 1, READ = 2, WAIT = 3, MULT = 4, ADD = 5, WRITE = 6, UNLOAD = 7, UNLOAD2 = 8, UNLOAD3 = 9;
reg	[3:0]		st = IDLE;
reg	[7:0]		cnt = 0;			// samples loaded / results sent
reg	[2:0]		stage = 0;		// 0..7: span = 2^stage
reg	[6:0]		bf = 0;			// butterfly 0..127 within the stage
assign busy = (st != IDLE) && (st != LOAD || cnt != 0);

function automatic [7:0] rev8(input [7:0] v);
	rev8 = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
endfunction

// butterfly addresses: j = bf mod span, group = bf / span, top = group * 2 * span + j, bottom = top + span
wire	[7:0]		span = 8'd1 << stage;
wire	[7:0]		j = {1'b0, bf} & (span - 1'b1);
wire	[7:0]		top = (({1'b0, bf} >> stage) << (stage + 1)) | j;
wire	[7:0]		bot = top | span;
wire	[6:0]		k = j << (3'd7 - stage);			// twiddle index j * 256 / (2 * span)

// datapath
reg signed [15:0]	ar, ai, br, bi, c, s;
reg signed [31:0]	m1, m2, m3, m4;
wire signed [16:0]	tr = (m1 + m2 + 32'sd16384) >>> 15;		// t = W * b = (c - js)(br + j bi)
wire signed [16:0]	ti = (m3 - m4 + 32'sd16384) >>> 15;		//   re = c br + s bi, im = c bi - s br
wire signed [17:0]	sr = ar + tr, si = ai + ti, dr = ar - tr, di = ai - ti;
function automatic [15:0] half(input signed [17:0] v);		// (v + 1) / 2, rounded
	half = (v + 18'sd1) >>> 1;
endfunction

always @(posedge clk) begin
	we_a <= 0;
	we_b <= 0;
	out_valid <= 0;
	case (st)
		IDLE, LOAD: if (in_valid) begin					// samples go in at bit-reversed addresses
			addr_a <= rev8(cnt);
			d_a <= {in_re, in_im};
			we_a <= 1;
			cnt <= cnt + 1'b1;
			st <= (cnt == 255) ? READ : LOAD;
			stage <= 0;
			bf <= 0;
		end
		READ: begin
			addr_a <= top;
			addr_b <= bot;
			tw_addr <= k;
			st <= WAIT;
		end
		WAIT: st <= MULT;										// RAM and ROM answer one clock after the address
		MULT: begin
			{ar, ai} <= q_a;
			{br, bi} <= q_b;
			{c, s} <= w_q;
			m1 <= $signed(w_q[31:16]) * $signed(q_b[31:16]);	// c br
			m2 <= $signed(w_q[15:0])  * $signed(q_b[15:0]);	// s bi
			m3 <= $signed(w_q[31:16]) * $signed(q_b[15:0]);	// c bi
			m4 <= $signed(w_q[15:0])  * $signed(q_b[31:16]);	// s br
			st <= ADD;
		end
		ADD: begin
			d_a <= {half(sr), half(si)};
			d_b <= {half(dr), half(di)};
			we_a <= 1;
			we_b <= 1;
			st <= WRITE;
		end
		WRITE: begin
			bf <= bf + 1'b1;
			if (bf == 127) begin
				stage <= stage + 1'b1;
				if (stage == 7) begin
					st <= UNLOAD;
					cnt <= 0;
				end
				else
					st <= READ;
			end
			else
				st <= READ;
		end
		UNLOAD: begin											// read 0..255 out in natural order, through port A
			addr_a <= cnt;
			st <= UNLOAD2;
		end
		UNLOAD2: st <= UNLOAD3;							// the RAM answers one clock after the address
		UNLOAD3: begin
			out_valid <= 1;
			out_k <= cnt;
			{out_re, out_im} <= q_a;
			cnt <= cnt + 1'b1;
			st <= (cnt == 255) ? IDLE : UNLOAD;
		end
	endcase
end

endmodule
