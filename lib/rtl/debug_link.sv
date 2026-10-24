// Debug link over the JTAG UART: event log, status on request, screen capture
//
// FPGA -> PC (text lines, \r\n):
//   an event line whenever a game-pad button, KEY or SW changes, and on '?':
//     T=hhhh BTN=hh KEY=h SW=hhh WHL=hhh
//       T = frame counter, BTN bits 7..0 = Left Right Up Down Start Select B A
//   on 'F': grabs one frame, every STEP-th pixel and line (STEP 2 -> 320x240), and sends
//     FRAME 320 240 / 240 lines of 320 pixels, 3 hex digits (RGB444) each / END
//   STEP 2 catches every dot of the x2 and x4 text; the buffer then takes ~56% of the M9K RAM.
// PC -> FPGA: '?' status line, 'F' frame, 'B' beep for about a quarter second.
// ***********************************************

module debug_link #(
	parameter STEP = 2		// 2 or 4
)(
	input					clk,			// pixel clock (25 MHz)
	input					resetN,
	input		[31:0]	pxl_x,
	input		[31:0]	pxl_y,
	input		[11:0]	rgb,			// the pixel being sent to the screens
	input		[7:0]		buttons,		// {Left, Right, Up, Down, Start, Select, B, A}
	input		[1:0]		key_pressed,
	input		[9:0]		SW,
	input		[11:0]	wheel,
	input		[15:0]	frame,
	// to / from jtag_uart
	output reg	[7:0]	tx_data,
	output reg			tx_valid,
	input					tx_ready,
	input		[7:0]		rx_data,
	input					rx_valid,
	output				beep
	);

localparam W = 640 / STEP, H = 480 / STEP;
localparam STATUS_LEN = 36;
localparam HEADER_LEN = 15;		// "FRAME www hhh\r\n"
localparam END_LEN    = 5;		// "END\r\n"

function automatic [7:0] hex_char(input [3:0] n);
	hex_char = (n < 10) ? 8'h30 + n : 8'h37 + n;
endfunction

function automatic [7:0] dec_char(input integer v, input integer place);	// place 2..0
	dec_char = 8'h30 + (v / (place == 2 ? 100 : place == 1 ? 10 : 1)) % 10;
endfunction

// ---- inputs snapshot / change detect
reg	[19:0]	state_d = 0;
wire	[19:0]	state_now = {buttons, key_pressed, SW};
reg	[15:0]	s_frame;
reg	[7:0]		s_btn;
reg	[1:0]		s_key;
reg	[9:0]		s_sw;
reg	[11:0]	s_wheel;

// ---- frame buffer
reg	[11:0]	fb [0:W*H-1];
reg	[16:0]	fb_waddr;
reg	[16:0]	fb_raddr;
reg	[11:0]	fb_q;
wire			on_grid = (pxl_x % STEP == 0) && (pxl_y % STEP == 0) && (pxl_x < 640) && (pxl_y < 480);

wire			fb_we;

always @(posedge clk) begin
	if (fb_we)
		fb[fb_waddr] <= rgb;
	fb_q <= fb[fb_raddr];
end

// ---- sender
enum int unsigned { IDLE, STATUS, GRAB_WAIT, GRAB, HEADER, PIXELS, EOL, FOOTER } st = IDLE;
reg	[5:0]		idx;			// character index inside a message / pixel
reg	[9:0]		col;			// pixel column during PIXELS
reg	[8:0]		row;
reg				want_status = 0;
reg				want_frame = 0;
reg	[22:0]	beep_cnt = 0;
reg	[7:0]		ch;

assign beep = (beep_cnt != 0);
assign fb_we = ((st == GRAB) && on_grid) || ((st == GRAB_WAIT) && pxl_x == 0 && pxl_y == 0);	// (0,0) too

function automatic [7:0] status_char(input [5:0] i, input [15:0] t, input [7:0] b, input [1:0] k, input [9:0] s, input [11:0] w);
	case (i)
		0:  status_char = "T";   1: status_char = "=";
		2:  status_char = hex_char(t[15:12]); 3: status_char = hex_char(t[11:8]);
		4:  status_char = hex_char(t[7:4]);   5: status_char = hex_char(t[3:0]);
		6:  status_char = " ";
		7:  status_char = "B";   8: status_char = "T";   9: status_char = "N";  10: status_char = "=";
		11: status_char = hex_char(b[7:4]);  12: status_char = hex_char(b[3:0]);
		13: status_char = " ";
		14: status_char = "K";  15: status_char = "E";  16: status_char = "Y";  17: status_char = "=";
		18: status_char = hex_char({2'b00, k});
		19: status_char = " ";
		20: status_char = "S";  21: status_char = "W";  22: status_char = "=";
		23: status_char = hex_char({2'b00, s[9:8]}); 24: status_char = hex_char(s[7:4]); 25: status_char = hex_char(s[3:0]);
		26: status_char = " ";
		27: status_char = "W";  28: status_char = "H";  29: status_char = "L";  30: status_char = "=";
		31: status_char = hex_char(w[11:8]); 32: status_char = hex_char(w[7:4]); 33: status_char = hex_char(w[3:0]);
		34: status_char = 8'h0D;
		default: status_char = 8'h0A;
	endcase
endfunction

function automatic [7:0] header_char(input [5:0] i);
	reg [119:0] s;
	s = {"FRAME ", dec_char(W, 2), dec_char(W, 1), dec_char(W, 0), " ",
	     dec_char(H, 2), dec_char(H, 1), dec_char(H, 0), 8'h0D, 8'h0A};
	header_char = s[(HEADER_LEN - 1 - i)*8 +: 8];
endfunction

function automatic [7:0] footer_char(input [5:0] i);
	reg [39:0] s;
	s = {"END", 8'h0D, 8'h0A};
	footer_char = s[(END_LEN - 1 - i)*8 +: 8];
endfunction

always @(posedge clk) begin
	tx_valid <= 0;
	state_d <= state_now;

	if (beep_cnt != 0)
		beep_cnt <= beep_cnt - 1'b1;

	if (rx_valid) begin
		if (rx_data == "?")                    want_status <= 1;
		if (rx_data == "F" || rx_data == "f")  want_frame <= 1;
		if (rx_data == "B" || rx_data == "b")  beep_cnt <= 23'd6_250_000;	// 0.25 s
	end
	if (state_now != state_d)
		want_status <= 1;

	case (st)
		IDLE: begin
			idx <= 0;
			if (want_frame) begin
				want_frame <= 0;
				st <= GRAB_WAIT;
			end
			else if (want_status) begin
				want_status <= 0;
				s_frame <= frame; s_btn <= buttons; s_key <= key_pressed; s_sw <= SW; s_wheel <= wheel;
				st <= STATUS;
			end
		end

		STATUS: if (tx_ready && !tx_valid) begin
			tx_data <= status_char(idx, s_frame, s_btn, s_key, s_sw, s_wheel);
			tx_valid <= 1;
			idx <= idx + 1'b1;
			if (idx == STATUS_LEN - 1)
				st <= IDLE;
		end

		GRAB_WAIT: if (pxl_x == 0 && pxl_y == 0) begin	// pixel (0,0) is written now at address 0
			fb_waddr <= 1;
			st <= GRAB;
		end
		else
			fb_waddr <= 0;

		GRAB: begin
			if (on_grid) begin
				fb_waddr <= fb_waddr + 1'b1;
				if (fb_waddr == W*H - 1) begin
					idx <= 0;
					st <= HEADER;
				end
			end
		end

		HEADER: if (tx_ready && !tx_valid) begin
			tx_data <= header_char(idx);
			tx_valid <= 1;
			idx <= idx + 1'b1;
			if (idx == HEADER_LEN - 1) begin
				fb_raddr <= 0;
				col <= 0;
				row <= 0;
				idx <= 0;
				st <= PIXELS;
			end
		end

		// 3 hex digits per pixel; fb_q is valid one clock after fb_raddr changes,
		// and a byte is sent at most every other clock, so it is always ready.
		PIXELS: if (tx_ready && !tx_valid) begin
			case (idx)
				0: tx_data <= hex_char(fb_q[11:8]);
				1: tx_data <= hex_char(fb_q[7:4]);
				default: tx_data <= hex_char(fb_q[3:0]);
			endcase
			tx_valid <= 1;
			if (idx == 2) begin
				idx <= 0;
				fb_raddr <= fb_raddr + 1'b1;
				if (col == W - 1) begin
					col <= 0;
					st <= EOL;
				end
				else
					col <= col + 1'b1;
			end
			else
				idx <= idx + 1'b1;
		end

		EOL: if (tx_ready && !tx_valid) begin
			tx_data <= (idx == 0) ? 8'h0D : 8'h0A;
			tx_valid <= 1;
			idx <= idx + 1'b1;
			if (idx == 1) begin
				idx <= 0;
				if (row == H - 1)
					st <= FOOTER;
				else begin
					row <= row + 1'b1;
					st <= PIXELS;
				end
			end
		end

		FOOTER: if (tx_ready && !tx_valid) begin
			tx_data <= footer_char(idx);
			tx_valid <= 1;
			idx <= idx + 1'b1;
			if (idx == END_LEN - 1)
				st <= IDLE;
		end

		default: st <= IDLE;
	endcase

	if (!resetN) begin
		st <= IDLE;
		want_status <= 0;
		want_frame <= 0;
	end
end

endmodule
