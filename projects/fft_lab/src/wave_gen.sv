// Wave generator: one frame of 256 samples of the chosen shape, optionally through a Hann window
//
// Pulse start (taken when !busy): it latches shape / fq / win and streams samples n = 0..255 out with
// valid / ready (a sample moves when valid && ready; x holds while it waits). The phase is n x fq (mod 2048),
// restarting at 0 every frame, so step fq = fq x 12.5 Hz at the notional 25.6 kHz sample rate.
// Shapes, amplitude A = 24576: 0 sine (table), 1 square, 2 triangle, 3 saw, 4 spikes (A while phase < fq),
// 5 noise (xorshift32, 3/4 x its top 16 bits). The noise generator moves on once per sample, whatever the shape.
// Window: x = (x * hann[n] + 16384) >> 15. Pipeline: phase -> tables -> shape -> window (3 stages).
// Python twin: sim/lab_model.py (Gen); unit test: sim/tb_wave_gen.sv.
// ***********************************************
`default_nettype none

module wave_gen #(
	parameter SINE_FILE = "assets/sine.hex",
	parameter HANN_FILE = "assets/hann.hex"
)(
	input		wire						clk,
	input		wire						start,
	input		wire			[2:0]		shape,
	input		wire			[9:0]		fq,
	input		wire						win,
	input		wire						ready,
	output	logic						valid = 1'b0,
	output	logic			[7:0]		n = 8'd0,
	output	logic signed [15:0]	x = 16'sd0,
	output	wire						busy
	);

localparam signed [15:0] A = 16'sd24576;

logic	[15:0]	sine [0:2047];
logic	[15:0]	hann [0:255];
initial begin
	$readmemh(SINE_FILE, sine);
	$readmemh(HANN_FILE, hann);
end

logic	[2:0]		shp = 3'd0;
logic	[9:0]		f = 10'd0;
logic				w = 1'b0;
logic				run = 1'b0;
logic	[7:0]		cnt = 8'd0;
logic	[10:0]	ph = 11'd0;
logic				vb = 1'b0, vc = 1'b0;
logic	[7:0]		nb = 8'd0, nc = 8'd0;
logic	[10:0]	phb = 11'd0;
logic	[15:0]	sine_q = 16'd0, hann_q = 16'd0, hc = 16'd0;
logic signed [15:0]	xc = 16'sd0;
logic	[31:0]	lfsr = 32'h2545F491;

wire				en = !valid || ready;			// the whole pipeline moves only when the output can move
assign busy = run || vb || vc || valid;

function automatic [31:0] xorshift(input [31:0] v);
	logic [31:0] t;
	begin
		t = v ^ (v << 13);
		t = t ^ (t >> 17);
		xorshift = t ^ (t << 5);
	end
endfunction

// ---- stage B: the shape at phase phb
wire signed [12:0]	ph13 = $signed({2'b00, phb});
wire signed [12:0]	tri_t = (phb < 11'd512) ? ph13 : (phb < 11'd1536) ? 13'sd1024 - ph13 : ph13 - 13'sd2048;
wire signed [18:0]	tri_v = tri_t * 7'sd48;
wire signed [18:0]	saw_v = (ph13 - 13'sd1024) * 6'sd24;
wire signed [17:0]	nz = $signed(lfsr[31:16]) * 18'sd3;
logic signed [15:0]	shape_v;
always_comb
	case (shp)
		3'd0:    shape_v = $signed(sine_q);
		3'd1:    shape_v = phb[10] ? -A : A;
		3'd2:    shape_v = tri_v[15:0];
		3'd3:    shape_v = saw_v[15:0];
		3'd4:    shape_v = (phb < {1'b0, f}) ? A : 16'sd0;
		3'd5:    shape_v = nz[17:2];
		default: shape_v = 16'sd0;
	endcase

// ---- stage C: the window (hann is 0..32768, unsigned)
wire signed [32:0]	wprod = xc * $signed({1'b0, hc});
wire signed [32:0]	wsum = wprod + 33'sd16384;

always @(posedge clk) begin
	if (start && !busy) begin
		shp <= shape; f <= fq; w <= win;
		run <= 1'b1; cnt <= 8'd0; ph <= 11'd0;
	end
	else if (en) begin
		// stage A: phase and sample number (the tables are read below with the same addresses)
		vb <= run; nb <= cnt; phb <= ph;
		if (run) begin
			cnt <= cnt + 1'b1;
			ph <= ph + {1'b0, f};
			if (cnt == 8'd255) run <= 1'b0;
		end
		// stage B
		vc <= vb; nc <= nb; xc <= shape_v; hc <= hann_q;
		if (vb) lfsr <= xorshift(lfsr);
		// stage C
		valid <= vc; n <= nc;
		x <= w ? wsum[30:15] : xc;
	end
end

always @(posedge clk)
	if (en) begin
		sine_q <= sine[ph];
		hann_q <= hann[cnt];
	end

endmodule

`default_nettype wire
