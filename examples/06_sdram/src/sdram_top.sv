`default_nettype none		// an undeclared name is an error, not a silent 1-bit wire (cost two builds here)
// Example 06: the 64 MB SDRAM: a full memory test of all 32M 16-bit words, again and again
//
// Each pass writes every word with a value made from its address and the pass number, then reads all of them back
// and compares. HEX5..HEX0: errors since power-up (must stay 0). LEDR9: pass running; LEDR1/0: reading/writing.
// SW0 up: write one wrong word per pass on purpose (the errors must go up by one per pass: proves the checker).
// KEY0: start over. USB (scripts/de10.py log): progress every 4M words and a line per pass with errors and time.
// Controller: lib/rtl/sdram_ctrl.sv at 50 MHz; DRAM_CLK = 50 MHz shifted 180 degrees from the PLL.
// ***********************************************

module sdram_top (
	input						MAX10_CLK1_50,
	input			[1:0]		KEY,
	input			[9:0]		SW,
	output		[9:0]		LEDR,
	output		[7:0]		HEX0,
	output		[7:0]		HEX1,
	output		[7:0]		HEX2,
	output		[7:0]		HEX3,
	output		[7:0]		HEX4,
	output		[7:0]		HEX5,
	output		[12:0]	DRAM_ADDR,
	output		[1:0]		DRAM_BA,
	output					DRAM_CAS_N,
	output					DRAM_CKE,
	output					DRAM_CLK,
	output					DRAM_CS_N,
	inout			[15:0]	DRAM_DQ,
	output					DRAM_LDQM,
	output					DRAM_RAS_N,
	output					DRAM_UDQM,
	output					DRAM_WE_N
	);

wire	[4:0]		pclk;
wire				locked;
pll_de10 #(.C0_MUL(1), .C0_DIV(1), .C1_MUL(1), .C1_DIV(1), .C1_PHASE("10000")) pll(		// c1 = c0 + 180 degrees
	.areset(1'b0), .inclk0(MAX10_CLK1_50), .clk(pclk), .locked(locked));
wire				clk = pclk[0];
assign DRAM_CLK = pclk[1];

reg	[2:0]		lk = 0;
always @(posedge clk) lk <= {lk[1:0], locked};
wire				reset_n = lk[2];

reg	[7:0]		pass = 0;
// declared before use: an identifier used before its declaration became an implicit 1-bit wire (silently)
// first a sweep: passes 0..5 try read delays 2..7 on the first 64K words; then full 64 MB passes with delay 4
reg	[2:0]		rd_delay = 2;
wire				sweeping = pass < 6;
wire	[24:0]	last = sweeping ? 25'h000FFFF : 25'h1FFFFFF;
wire				ready, rvalid, init_done;
wire	[15:0]	rdata;
reg				req = 0, we = 0;
reg	[24:0]	addr = 0;
reg	[24:0]	q_addr = 0;			// the address sent with each request: set together with req, because
										// addr moves on in the same clock (every write once landed 1 address late)
reg	[15:0]	wdata = 0;
sdram_ctrl #(.CLK_MHZ(50), .READ_DELAY(4)) ctrl(.clk(clk), .reset_n(reset_n), .rd_delay(rd_delay), .req(req), .we(we), .addr(q_addr),
	.wdata(wdata), .ready(ready), .rvalid(rvalid), .rdata(rdata), .init_done(init_done),
	.DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_CAS_N(DRAM_CAS_N), .DRAM_CKE(DRAM_CKE), .DRAM_CS_N(DRAM_CS_N),
	.DRAM_DQ(DRAM_DQ), .DRAM_LDQM(DRAM_LDQM), .DRAM_RAS_N(DRAM_RAS_N), .DRAM_UDQM(DRAM_UDQM), .DRAM_WE_N(DRAM_WE_N));

// the value of a word: from its address and the pass, so a wrong address or a stuck bit shows
function automatic [15:0] pattern(input [24:0] a, input [7:0] pass);
	pattern = a[15:0] ^ {a[24:16], a[24:18]} ^ {pass, ~pass};
endfunction

reg	[1:0]		ks = 0;
always @(posedge clk) ks <= {ks[0], ~KEY[0]};

localparam P_IDLE = 0, P_WRITE = 1, P_READ = 2, P_WAITREAD = 3, P_REPORT = 4;
reg	[2:0]		ph = P_IDLE;
reg	[31:0]	errors = 0, pass_errors = 0;
reg	[24:0]	raddr = 0;			// address of the outstanding read
reg	[31:0]	ticks = 0;			// clocks in this pass
reg				progress = 0;		// a 4M-word step was crossed
reg	[24:0]	last_addr;
always @(posedge clk) begin
	req <= 0;
	progress <= 0;
	if (ph != P_IDLE) ticks <= ticks + 1'b1;
	if (!init_done || ks == 2'b01) begin
		ph <= P_IDLE;
		if (ks == 2'b01) begin errors <= 0; pass <= 0; end
	end
	else case (ph)
		P_IDLE: begin
			addr <= 0;
			ticks <= 0;
			pass_errors <= 0;
			ph <= P_WRITE;
		end
		P_WRITE: if (ready && !req) begin
			req <= 1;
			we <= 1;
			q_addr <= addr;
			wdata <= (SW[0] && addr == 25'h123456) ? pattern(addr, pass) ^ 16'h0100 : pattern(addr, pass);
			last_addr <= addr;
			if (addr[21:0] == 0) progress <= 1;
			if (addr == last) begin ph <= P_READ; addr <= 0; end	// reads start again at 0
			else addr <= addr + 1'b1;
		end
		P_READ: if (ready && !req) begin
			req <= 1;
			we <= 0;
			raddr <= addr;
			q_addr <= addr;
			if (addr[21:0] == 0) progress <= 1;
			ph <= P_WAITREAD;
		end
		P_WAITREAD: if (rvalid) begin
			if (rdata != pattern(raddr, pass)) begin
				errors <= errors + 1'b1;
				pass_errors <= pass_errors + 1'b1;
			end
			addr <= addr + 1'b1;
			ph <= (raddr == last) ? P_REPORT : P_READ;
		end
		P_REPORT: if (report_done) begin
			rd_delay <= (pass < 5) ? rd_delay + 1'b1 : 3'd4;	// after the sweep: 4 (first good delay is 3; +1 margin)
			pass <= pass + 1'b1;
			ph <= P_IDLE;
		end
	endcase
end

// ---- report
function automatic [7:0] hx(input [3:0] n);
	hx = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction
function automatic [8*4-1:0] h16(input [15:0] v);
	h16 = {hx(v[15:12]), hx(v[11:8]), hx(v[7:4]), hx(v[3:0])};
endfunction
function automatic [8*8-1:0] h32(input [31:0] v);
	integer k;
	for (k = 0; k < 8; k = k + 1) h32[8*k +: 8] = hx(v[4*k +: 4]);
endfunction
reg				send = 0, report_done = 0, reported = 0;
reg	[8*60-1:0]	text;
reg	[6:0]		len;
wire				busy;
reg				prog_pending = 0;
reg	[24:0]	prog_addr;
reg				prog_read;
always @(posedge clk) begin
	send <= 0;
	report_done <= 0;
	if (progress) begin prog_pending <= 1; prog_addr <= addr; prog_read <= (ph != P_WRITE); end
	if (ph != P_REPORT) reported <= 0;
	if (!busy && !send) begin
		if (ph == P_REPORT && !reported) begin
			// "PASS 01 errors=00000000 time=0000xxxx ms(hex)": time in clocks / 50000 would need a divider:
			// print clocks in hex instead, the PC turns it into seconds (scripts or by hand: / 50e6)
			text <= {"PASS ", hx(pass[7:4]), hx(pass[3:0]), " delay=", hx({1'b0, rd_delay}),
			         sweeping ? " 64K words" : " 32M words", " errors=", h32(pass_errors), " clocks=", h32(ticks), {3{8'h20}}};	// 57 + 3 = 60
			len <= 7'd57;
			send <= 1;
			reported <= 1;
		end
		else if (ph == P_REPORT && reported)
			report_done <= 1;
		else if (prog_pending) begin
			text <= {prog_read ? "  read  " : "  write ", hx({3'b0, prog_addr[24]}), hx(prog_addr[23:20]),
			         hx(prog_addr[19:16]), hx(prog_addr[15:12]), hx(prog_addr[11:8]), hx(prog_addr[7:4]),
			         hx(prog_addr[3:0]), {45{8'h20}}};
			len <= 7'd15;
			send <= 1;
			prog_pending <= 0;
		end
	end
end
wire	[7:0]		tx_data;
wire				tx_valid, tx_ready;
line_printer #(.MAXLEN(60)) printer(.clk(clk), .text(text), .len(len), .send(send), .busy(busy),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
jtag_uart uart(.clk(clk), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(), .rx_valid());

// ---- display: errors in decimal
wire	[23:0]	ebcd;
bin2bcd #(.BITS(20), .DIGITS(6)) ed(.bin(errors > 999999 ? 20'd999999 : errors[19:0]), .bcd(ebcd));
wire	[7:0]		seg [0:5];
genvar i;
generate
	for (i = 0; i < 6; i = i + 1) begin : digit
		wire blank = (i > 0 && ebcd[23:4*i] == 0);
		seg7_char c(.ch(blank ? " " : 8'h30 + ebcd[4*i +: 4]), .dp(1'b0), .seg(seg[i]));
	end
endgenerate
assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg[5], seg[4], seg[3], seg[2], seg[1], seg[0]};
assign LEDR = {init_done, 6'b0, SW[0], (ph == P_READ || ph == P_WAITREAD), (ph == P_WRITE)};

endmodule

`default_nettype wire
