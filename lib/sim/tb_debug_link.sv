// Unit test of the screen read-back: VGA timing + a known colour pattern -> debug_link (STEP 2) -> jtag_uart
// stand-in. Sends '?' and 'F' like the PC, decodes the hex text that comes back, and checks every pixel.
// python scripts/sim.py lib/sim/tb_debug_link.sv -D JTAG_UART_SIM
// sim-sources: lib/rtl/vga_controller.v lib/rtl/jtag_uart.sv lib/rtl/debug_link.sv
`timescale 1ns/1ns

module tb_debug_link;

reg				clk = 0;
wire	[31:0]	px, py;
wire				de, hs, vs;
wire	[7:0]		tx_data, rx_data, seen;
wire				tx_valid, tx_ready, rx_valid, seen_valid;
reg	[7:0]		cmd = 0;
reg				cmd_valid = 0;

always #20 clk = ~clk;

function [11:0] colour(input [9:0] x, input [8:0] y);	// what the "screen" shows at (x, y)
	colour = {x[9:6], y[8:5], x[3:0] ^ y[3:0]};
endfunction

vga_controller vga(.pixel_clk(clk), .reset_n(1'b1), .h_sync(hs), .v_sync(vs), .disp_ena(de), .column(px), .row(py));
debug_link #(.STEP(2)) dut(.clk(clk), .resetN(1'b1), .pxl_x(px), .pxl_y(py),
	.rgb(de ? colour(px[9:0], py[8:0]) : 12'h000),
	.buttons(8'h21), .key_pressed(2'b01), .SW(10'h003), .wheel(12'h9C4), .frame(16'h0042),
	.tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
jtag_uart uart(.clk(clk), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
	.rx_data(rx_data), .rx_valid(rx_valid), .sim_rx_data(cmd), .sim_rx_valid(cmd_valid),
	.tx_seen(seen), .tx_seen_valid(seen_valid));

// decode what the PC would receive
integer	state = 0;		// 0 before "FRAME", 1 skipping the header line, 2 in pixels, 3 done
integer	row = 0, col = 0, nib = 0, errors = 0, pixels = 0, status_lines = 0;
reg	[11:0]	pix;
reg	[39:0]	last5 = 0;
function [3:0] hexval(input [7:0] c);
	hexval = (c >= "A") ? c - "A" + 10 : c - "0";
endfunction

always @(posedge clk) if (seen_valid) begin
	last5 = {last5[31:0], seen};
	if (state == 0 && seen == "T") status_lines = status_lines + 1;
	if (state == 0 && last5 == "FRAME") state = 1;
	else if (state == 1 && seen == 8'h0A) begin state = 2; row = 0; col = 0; nib = 0; end
	else if (state == 2) begin
		if (seen == 8'h0A) begin row = row + 1; col = 0; if (row == 240) state = 3; end
		else if (seen != 8'h0D) begin
			pix = {pix[7:0], hexval(seen)};
			nib = nib + 1;
			if (nib == 3) begin
				nib = 0;
				pixels = pixels + 1;
				if (pix !== colour(col * 2, row * 2)) begin
					errors = errors + 1;
					if (errors < 5) $display("pixel (%0d,%0d): got %h want %h", col, row, pix, colour(col * 2, row * 2));
				end
				col = col + 1;
			end
		end
	end
end

task send(input [7:0] c);
	begin
		@(posedge clk) begin cmd <= c; cmd_valid <= 1; end
		@(posedge clk) cmd_valid <= 0;
	end
endtask

initial begin
	repeat (100) @(posedge clk);
	send("?");
	repeat (3000) @(posedge clk);
	send("F");
	wait (state == 3);
	repeat (20) @(posedge clk);
	$display("status lines %0d, pixels %0d, errors %0d", status_lines, pixels, errors);
	if (errors == 0 && pixels == 320 * 240 && status_lines >= 1) $display("PASS"); else $display("FAIL");
	$finish;
end

initial begin #200_000_000; $display("FAIL: timeout"); $finish; end

endmodule
