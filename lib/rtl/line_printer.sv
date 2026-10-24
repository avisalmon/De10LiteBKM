// Line printer: sends a text line (up to MAXLEN characters) to jtag_uart
//
// Put the text in `text` with the FIRST character in the top byte (a Verilog string literal works:
// {"c0=", d5, d4, ... }), set len, pulse send for one clock. "\r\n" is added. busy is high while sending;
// a send while busy is ignored. Helpers below turn numbers into characters.
// ***********************************************

module line_printer #(
	parameter MAXLEN = 48
)(
	input							clk,
	input		[8*MAXLEN-1:0]	text,
	input		[6:0]				len,
	input							send,
	output						busy,
	output reg	[7:0]			tx_data,
	output reg					tx_valid = 0,
	input							tx_ready
	);

reg	[8*MAXLEN-1:0]	buf_q;
reg	[6:0]				n = 0;
reg	[6:0]				i = 0;
reg						active = 0;

assign busy = active;

always @(posedge clk) begin
	tx_valid <= 0;
	if (!active) begin
		if (send) begin
			buf_q <= text;
			n <= len;
			i <= 0;
			active <= 1;
		end
	end
	else if (tx_ready && !tx_valid) begin
		tx_valid <= 1;
		if (i < n)
			tx_data <= buf_q[8*(MAXLEN-1-i) +: 8];
		else if (i == n)
			tx_data <= 8'h0D;
		else begin
			tx_data <= 8'h0A;
			active <= 0;
		end
		i <= i + 1'b1;
	end
end

endmodule
