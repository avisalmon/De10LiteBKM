// Recording testbench (ModelSim, with the real Altera FFT IP): lab_engine runs every case in cases.txt
// ("shape fq win lin" per line) and this writes
//   ip_vectors.hex        per case 513 words: {CA, exp, latency}, the IP's 256 inputs {re, im}, its 256 outputs
//   lab_ip_results.txt    what the engine published, its 128 + 128 bars and its 256 scope spans
// Run by sim/record_ip.py, which compiles the IP's simulation model and checks every number against the model.
`timescale 1ns/1ns

module tb_lab_ip;

logic				clk = 0, rst_hold = 1, start = 0, ip_restart = 0;
logic	[2:0]		shape = 0;
logic	[9:0]		fq = 0;
logic				win = 0, lin = 0;
wire				sc_we, bd_we, bi_we, pub, r_win, r_lin, r_ip_ok, r_ip_dead, busy;
wire	[7:0]		sc_addr;
wire	[13:0]	sc_d;
wire	[6:0]		bd_addr, bd_d, bi_addr, bi_d, r_dpk, r_dpx, r_ipk, r_ipx;
wire	[2:0]		r_shape;
wire	[9:0]		r_fq;
wire	[16:0]	r_dclk, r_iclk;
wire signed [5:0]	r_iexp;

always #20 clk = ~clk;

lab_engine #(.TWIDDLE_FILE("twiddle.hex"), .SINE_FILE("sine.hex"), .HANN_FILE("hann.hex"), .MAG_FILE("mag_rom.bin"))
	eng(.clk(clk), .rst_hold(rst_hold), .start(start), .shape(shape), .fq(fq), .win(win), .lin(lin),
	.ip_restart(ip_restart), .sc_we(sc_we), .sc_addr(sc_addr), .sc_d(sc_d), .bd_we(bd_we), .bd_addr(bd_addr),
	.bd_d(bd_d), .bi_we(bi_we), .bi_addr(bi_addr), .bi_d(bi_d), .pub(pub), .r_shape(r_shape), .r_fq(r_fq),
	.r_win(r_win), .r_lin(r_lin), .r_dclk(r_dclk), .r_iclk(r_iclk), .r_dpk(r_dpk), .r_dpx(r_dpx), .r_ipk(r_ipk),
	.r_ipx(r_ipx), .r_iexp(r_iexp), .r_ip_ok(r_ip_ok), .r_ip_dead(r_ip_dead), .busy(busy));

// what the engine writes for the screen
logic	[13:0]	sc [0:255];
logic	[6:0]		bd [0:127];
logic	[6:0]		bi [0:127];
always @(posedge clk) begin
	if (sc_we) sc[sc_addr] <= sc_d;
	if (bd_we) bd[bd_addr] <= bd_d;
	if (bi_we) bi[bi_addr] <= bi_d;
end

// what goes into the IP and what comes out
integer			cyc = 0, n_in = 0, n_out = 0, t_first = 0, t_sop = 0;
logic	[31:0]	vin [0:255];
logic	[31:0]	vout [0:255];
logic signed [5:0]	exp_sop = 0;
always @(posedge clk) begin
	cyc <= cyc + 1;
	if (eng.g_valid && !eng.dead && eng.sink_ready) begin
		if (n_in == 0) t_first = cyc;
		if (n_in < 256) vin[n_in] = {eng.g_x, 16'h0000};
		n_in = n_in + 1;
	end
	if (eng.src_valid) begin
		if (eng.src_sop) begin t_sop = cyc; n_out = 0; exp_sop = eng.src_exp; end
		if (n_out < 256) vout[n_out] = {eng.src_real, eng.src_imag};
		n_out = n_out + 1;
	end
end

integer			fc, fv, fr, i, nc = 0, errs = 0, guard, cs, cf, cw, cl, lat;
initial begin
	fc = $fopen("cases.txt", "r");
	fv = $fopen("ip_vectors.hex", "w");
	fr = $fopen("lab_ip_results.txt", "w");
	repeat (10) @(negedge clk);
	rst_hold = 0;
	while ($fscanf(fc, "%d %d %d %d\n", cs, cf, cw, cl) == 4) begin
		n_in = 0;
		@(negedge clk) begin shape = cs; fq = cf; win = cw; lin = cl; start = 1; end
		guard = 0;
		@(posedge clk);
		while (!eng.frame_go && guard < 5000) begin @(posedge clk); guard = guard + 1; end
		@(negedge clk) start = 0;
		guard = 0;
		while (!pub && guard < 40000) begin @(posedge clk); guard = guard + 1; end
		lat = t_sop - t_first;
		if (!pub || n_in != 256 || n_out != 256) begin
			$display("FAIL: case S%0dN%0dW%0dL%0d: pub=%0d, %0d samples in, %0d out", cs, cf, cw, cl, pub, n_in, n_out);
			errs = errs + 1;
		end
		else begin
			$display("CASE S%0dN%0dW%0dL%0d: our FFT %0d clocks, bin %0d (%0d px); IP %0d clocks (latency %0d), exp %0d, bin %0d (%0d px), ok %0d",
				cs, cf, cw, cl, r_dclk, r_dpk, r_dpx, r_iclk, lat, r_iexp, r_ipk, r_ipx, r_ip_ok);
			$fwrite(fv, "%08X\n", {8'hCA, {{2{exp_sop[5]}}, exp_sop}, lat[15:0]});
			for (i = 0; i < 256; i = i + 1) $fwrite(fv, "%08X\n", vin[i]);
			for (i = 0; i < 256; i = i + 1) $fwrite(fv, "%08X\n", vout[i]);
			$fwrite(fr, "CASE S%0dN%0dW%0dL%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n", cs, cf, cw, cl,
				r_dclk, r_iclk, r_dpk, r_dpx, r_ipk, r_ipx, r_iexp, r_ip_ok, r_ip_dead, lat);
			$fwrite(fr, "BD");
			for (i = 0; i < 128; i = i + 1) $fwrite(fr, " %0d", bd[i]);
			$fwrite(fr, "\nBI");
			for (i = 0; i < 128; i = i + 1) $fwrite(fr, " %0d", bi[i]);
			$fwrite(fr, "\nSC");
			for (i = 0; i < 256; i = i + 1) $fwrite(fr, " %0d:%0d", sc[i][13:7], sc[i][6:0]);
			$fwrite(fr, "\n");
			nc = nc + 1;
		end
	end
	$fclose(fv);
	$fclose(fr);
	if (errs == 0 && nc > 0) $display("PASS: recorded %0d cases", nc);
	else $display("FAIL: %0d cases recorded, %0d errors", nc, errs);
	$finish;
end

endmodule
