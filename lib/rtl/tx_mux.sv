// Two text senders sharing one jtag_uart: whole lines, never mixed
//
// Senders in lib/rtl answer tx_ready one clock later with tx_valid. So: while nobody owns the link, offer
// tx_ready to A, wait a clock, offer it to B, wait a clock...; route each byte by who was offered on the
// previous clock; the first sender that answers owns the link until it sends "\n" (8'h0A).
// ***********************************************

module tx_mux (
	input					clk,
	input		[7:0]		a_data,
	input					a_valid,
	output				a_ready,
	input		[7:0]		b_data,
	input					b_valid,
	output				b_ready,
	output	[7:0]		tx_data,
	output				tx_valid,
	input					tx_ready
	);

reg	[1:0]	owner = 0;		// 0 = nobody, 1 = A, 2 = B
reg	[1:0]	phase = 0;		// idle offers: 0 -> A, 2 -> B, 1 and 3 -> nobody
reg	[1:0]	offered = 0;	// who had tx_ready last clock

wire	offer_a = owner == 1 || (owner == 0 && phase == 0);
wire	offer_b = owner == 2 || (owner == 0 && phase == 2);

assign a_ready = tx_ready && offer_a;
assign b_ready = tx_ready && offer_b;
assign tx_valid = (offered == 1 && a_valid) || (offered == 2 && b_valid);
assign tx_data  = (offered == 2) ? b_data : a_data;

always @(posedge clk) begin
	phase <= phase + 1'b1;
	offered <= a_ready ? 2'd1 : b_ready ? 2'd2 : 2'd0;
	if (offered == 1 && a_valid) owner <= (a_data == 8'h0A) ? 2'd0 : 2'd1;
	if (offered == 2 && b_valid) owner <= (b_data == 8'h0A) ? 2'd0 : 2'd2;
end

endmodule
