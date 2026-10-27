// Dual-clock FIFO in block RAM, show-ahead read, with the fill level visible on both sides
//
// The building block of the stream fabric (examples/15): one per read channel (1024 x 16, two M9K) and one per
// write-back lane (64 x 32, one M9K). Our own module instead of Altera's dcfifo so Icarus simulates it.
//
// Write side (wclk): wr_en pushes wdata when !full (a push while full is dropped and sets the sticky `overflow`).
// Read side (rclk): show-ahead, rdata is the oldest word whenever !empty; rd_en pops it and the next word is on
// rdata the clock after (a pop while empty does nothing and sets the sticky `underflow`).
//
// The pointers are binary with one extra bit (full vs empty); each crosses to the other clock as Gray code through
// two flops (one bit changes per step, so a half-updated pointer is never seen), then is turned back to binary into a
// register. So each side sees the other's pointer three of its own clocks late, and the levels are conservative
// in the direction a credit scheme needs: `wlevel` (write side) never reads lower than the true fill, `rlevel`
// (read side) never reads higher. `full` and `empty` follow the same rule: never wrong, at worst three clocks late.
//
// Show-ahead with the block RAM's registered read: the RAM is read at the address the read pointer will have after
// this clock (rptr + 1 on a pop, rptr otherwise), so its output register always holds mem[rptr]. While the FIFO is
// empty the word at rptr is re-read every clock, and `empty` falls three clocks after the write that filled it:
// by then the RAM has the new word, with no bypass logic (ramstyle no_rw_check: the two ports never need to agree
// on a same-clock access).
//
// With wclk = rclk it is an ordinary synchronous FIFO whose flags are three clocks conservative; DEPTH a power of
// two >= 4. Reset both sides together (each with its own synchronous reset, held at least three clocks of the
// slower clock); the RAM contents are not reset.
// ***********************************************

module async_fifo #(
	parameter WIDTH = 16,
	parameter DEPTH = 1024,
	parameter AW = $clog2(DEPTH)
)(
	// write side
	input						wclk,
	input						wrst_n,
	input						wr_en,
	input		[WIDTH-1:0]	wdata,
	output					full,
	output	[AW:0]		wlevel,					// words in the FIFO as the writer sees it (0..DEPTH, never low)
	output reg				overflow = 0,			// a push while full happened (sticky until wrst_n)
	// read side
	input						rclk,
	input						rrst_n,
	input						rd_en,
	output reg	[WIDTH-1:0]	rdata,				// the oldest word, valid while !empty (show-ahead)
	output					empty,
	output	[AW:0]		rlevel,					// words in the FIFO as the reader sees it (0..DEPTH, never high)
	output reg				underflow = 0			// a pop while empty happened (sticky until rrst_n)
	);

(* ramstyle = "no_rw_check" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

reg	[AW:0]	wptr = 0, rptr = 0;				// binary pointers, one extra bit
reg	[AW:0]	wgray = 0, rgray = 0;			// the same as Gray code, the version that crosses
reg	[AW:0]	wgray_r1 = 0, wgray_r2 = 0;	// write pointer on its way to the read clock
reg	[AW:0]	rgray_w1 = 0, rgray_w2 = 0;	// read pointer on its way to the write clock
reg	[AW:0]	rptr_w = 0;							// read pointer as the writer knows it (binary, registered)
reg	[AW:0]	wptr_r = 0;							// write pointer as the reader knows it (binary, registered)

function automatic [AW:0] bin2gray(input [AW:0] b);
	bin2gray = b ^ (b >> 1);
endfunction

function automatic [AW:0] gray2bin(input [AW:0] g);
	integer i;
	begin
		gray2bin[AW] = g[AW];
		for (i = AW - 1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i + 1] ^ g[i];
	end
endfunction

// ---------------------------------------------------------------- write side
wire	[AW:0]	wlevel_w = wptr - rptr_w;
assign wlevel = wlevel_w;
assign full = wlevel_w[AW];						// the difference is 0..DEPTH, so bit AW set means exactly DEPTH
wire				push = wr_en && !full;

always @(posedge wclk) begin
	{rgray_w2, rgray_w1} <= {rgray_w1, rgray};
	rptr_w <= gray2bin(rgray_w2);
	if (push) begin
		wptr <= wptr + 1'b1;
		wgray <= bin2gray(wptr + 1'b1);
	end
	if (wr_en && full) overflow <= 1'b1;
	if (!wrst_n) begin
		wptr <= 0;
		wgray <= 0;
		{rgray_w2, rgray_w1} <= 0;				// the copies too: the first clocks after reset must read empty
		rptr_w <= 0;
		overflow <= 1'b0;
	end
end

always @(posedge wclk)
	if (push) mem[wptr[AW-1:0]] <= wdata;

// ---------------------------------------------------------------- read side
assign empty = (wptr_r == rptr);
assign rlevel = wptr_r - rptr;
wire				pop = rd_en && !empty;
wire	[AW:0]	rptr_next = pop ? rptr + 1'b1 : rptr;

always @(posedge rclk) begin
	{wgray_r2, wgray_r1} <= {wgray_r1, wgray};
	wptr_r <= gray2bin(wgray_r2);
	rptr <= rptr_next;
	rgray <= bin2gray(rptr_next);
	if (rd_en && empty) underflow <= 1'b1;
	if (!rrst_n) begin
		rptr <= 0;
		rgray <= 0;
		{wgray_r2, wgray_r1} <= 0;
		wptr_r <= 0;
		underflow <= 1'b0;
	end
end

always @(posedge rclk)
	rdata <= mem[rptr_next[AW-1:0]];			// the RAM's output register tracks mem[rptr]

endmodule
