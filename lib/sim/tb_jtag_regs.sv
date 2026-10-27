// Unit test: jtag_regs (lib/rtl/jtag_regs.sv), the JTAG side driven the way the USB-Blaster drives it (TCK 6 MHz,
// asynchronous to a 100 MHz clock, back-to-back scans with the shortest gap the TAP allows).
// Behind the node: 16 registers at 0x0000..0x000F (read one clock after the address, like sdram_memtest) and an
// address echo {addr, ~addr} everywhere else. Checks ID, single and block writes (we pulses, data, addresses),
// single and block reads (the fetched word, the increment after every READ), the echo across the address
// increment, that a READ does not write, and the bypass for an unknown IR.
// python scripts/sim.py lib/sim/tb_jtag_regs.sv -D JTAG_REGS_SIM
// sim-sources: lib/rtl/jtag_regs.sv
`timescale 1ns/1ps

module tb_jtag_regs;

localparam real HALF = 83.333;		// 6 MHz TCK
localparam [3:0] IR_ADDR = 1, IR_WRITE = 2, IR_READ = 3, IR_ID = 4;
localparam [31:0] ID = 32'hC0DE_0015;

reg				clk = 0, rst_n = 0;
always #5 clk = ~clk;

wire	[15:0]	addr;
wire	[31:0]	wdata;
wire				we, busy;
reg	[31:0]	rdata = 0;
reg				tck = 0, tdi = 0, cdr = 0, sdr = 0, udr = 0, uir = 0;
reg	[3:0]		ir_in = 0, ir_next = 0;
wire				tdo;
always @(posedge tck) if (uir) ir_in <= ir_next;

jtag_regs #(.INSTANCE(1), .ID(ID)) dut(.clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata), .we(we), .rdata(rdata),
	.busy(busy), .sim_tck(tck), .sim_tdi(tdi), .sim_ir_in(ir_in), .sim_cdr(cdr), .sim_sdr(sdr), .sim_udr(udr),
	.sim_uir(uir), .sim_tdo(tdo));

// ---- the design behind the node ----
reg	[31:0]	file [0:15];
integer			we_count = 0;
integer			k;
initial for (k = 0; k < 16; k = k + 1) file[k] = 32'h1000_0000 + k;
always @(posedge clk) begin
	if (we) begin
		we_count <= we_count + 1;
		if (addr[15:4] == 0) file[addr[3:0]] <= wdata;
	end
	rdata <= (addr[15:4] == 0) ? file[addr[3:0]] : {addr, ~addr};
end

// ---- the JTAG side, one TAP state per TCK edge ----
integer			errors = 0;
task fail(input [8*80-1:0] what, input [31:0] got, input [31:0] want);
	begin
		errors = errors + 1;
		$display("FAIL: %0s: got %h, want %h", what, got, want);
	end
endtask

task edge_;
	begin
		#(HALF) tck = 1;
		#(HALF) tck = 0;
	end
endtask

task set_ir(input [3:0] v);
	begin
		repeat (20) edge_;
		ir_next = v;
		uir = 1; edge_; uir = 0;
		repeat (14) edge_;
	end
endtask

task dr_begin;
	begin
		edge_;
		cdr = 1; edge_; cdr = 0;
		sdr = 1;
	end
endtask

task dr_end;
	begin
		sdr = 0; edge_;
		udr = 1; edge_; udr = 0;
	end
endtask

task shift_bit(input b, output o);
	begin
		tdi = b;
		#(HALF) o = tdo;
		tck = 1;
		#(HALF) tck = 0;
	end
endtask

task scan(input integer n, input [31:0] v, output [31:0] o);		// one DR scan of n bits, LSB first
	reg b;
	integer i;
	begin
		o = 0;
		dr_begin;
		for (i = 0; i < n; i = i + 1) begin
			shift_bit(v[i], b);
			o[i] = b;
		end
		dr_end;
	end
endtask

task set_addr(input [15:0] a);
	reg [31:0] o;
	begin
		set_ir(IR_ADDR);
		scan(16, {16'd0, a}, o);
	end
endtask

task write_word(input [31:0] v);				// IR must be IR_WRITE already
	reg [31:0] o;
	begin
		scan(32, v, o);
	end
endtask

task read_word(output [31:0] v);				// IR must be IR_READ already
	begin
		scan(32, 32'd0, v);
	end
endtask

reg	[31:0]	got, o;
integer			i, n;

initial begin
	repeat (5) @(posedge clk);
	rst_n = 1;
	repeat (10) edge_;

	// ID
	set_ir(IR_ID);
	scan(32, 32'd0, got);
	if (got !== ID) fail("ID", got, ID);

	// single writes: ADDR 5, WRITE, WRITE -> file[5], file[6]
	set_addr(16'h0005);
	set_ir(IR_WRITE);
	write_word(32'hDEAD_BEEF);
	write_word(32'h0123_4567);
	repeat (4) @(posedge clk);
	if (file[5] !== 32'hDEAD_BEEF) fail("file[5]", file[5], 32'hDEAD_BEEF);
	if (file[6] !== 32'h0123_4567) fail("file[6]", file[6], 32'h0123_4567);
	if (file[7] !== 32'h1000_0007) fail("file[7] untouched", file[7], 32'h1000_0007);
	if (we_count !== 2) fail("we pulses", we_count, 2);
	if (addr !== 16'h0007) fail("addr after 2 writes", addr, 16'h0007);

	// single reads: ADDR 5, READ, READ
	set_addr(16'h0005);
	set_ir(IR_READ);
	read_word(got);
	if (got !== 32'hDEAD_BEEF) fail("read file[5]", got, 32'hDEAD_BEEF);
	read_word(got);
	if (got !== 32'h0123_4567) fail("read file[6]", got, 32'h0123_4567);
	read_word(got);
	if (got !== 32'h1000_0007) fail("read file[7]", got, 32'h1000_0007);
	if (we_count !== 2) fail("READ wrote", we_count, 2);

	// the echo: the address increments after every READ, the fetch follows the increment
	set_addr(16'h1234);
	set_ir(IR_READ);
	read_word(got);
	if (got !== {16'h1234, ~16'h1234}) fail("echo 1234", got, {16'h1234, ~16'h1234});
	read_word(got);
	if (got !== {16'h1235, ~16'h1235}) fail("echo 1235", got, {16'h1235, ~16'h1235});
	// ADDR alone refetches, without increment
	set_addr(16'hFFFF);
	set_ir(IR_READ);
	read_word(got);
	if (got !== {16'hFFFF, ~16'hFFFF}) fail("echo FFFF", got, {16'hFFFF, ~16'hFFFF});
	read_word(got);
	if (got !== 32'h1000_0000) fail("wraps to 0000 = file[0]", got, 32'h1000_0000);

	// block write then block read, 16 words
	set_addr(16'h0000);
	set_ir(IR_WRITE);
	for (i = 0; i < 16; i = i + 1) write_word(32'hA5A5_0000 + i * 32'h0101);
	set_addr(16'h0000);
	set_ir(IR_READ);
	for (i = 0; i < 16; i = i + 1) begin
		read_word(got);
		if (got !== 32'hA5A5_0000 + i * 32'h0101) fail("block read", got, 32'hA5A5_0000 + i * 32'h0101);
	end
	if (we_count !== 18) fail("we pulses after block", we_count, 18);

	// bypass: an unknown IR passes tdi to tdo one TCK later
	set_ir(4'hF);
	dr_begin;
	shift_bit(1'b1, o[0]);
	shift_bit(1'b0, o[1]);
	shift_bit(1'b1, o[2]);
	shift_bit(1'b1, o[3]);
	dr_end;
	if (o[3:1] !== 3'b101) fail("bypass", o[3:1], 3'b101);
	if (we_count !== 18) fail("bypass wrote", we_count, 18);

	// a write with the shortest possible gap after a READ (back-to-back scans, as a PC does)
	set_addr(16'h0003);
	set_ir(IR_WRITE);
	write_word(32'h1111_2222);
	write_word(32'h3333_4444);
	write_word(32'h5555_6666);
	set_addr(16'h0003);
	set_ir(IR_READ);
	read_word(got); if (got !== 32'h1111_2222) fail("fast 3", got, 32'h1111_2222);
	read_word(got); if (got !== 32'h3333_4444) fail("fast 4", got, 32'h3333_4444);
	read_word(got); if (got !== 32'h5555_6666) fail("fast 5", got, 32'h5555_6666);

	if (busy) fail("busy at the end", busy, 0);
	if (errors == 0) $display("PASS: jtag_regs: ID, writes, reads, echo, block, bypass");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule
