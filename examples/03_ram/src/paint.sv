// Writer side of the frame buffer (50 MHz): a test picture at start-up, then painting with the game pad
//
// 160 x 120 pixels, address = y * 160 + x. At power-up (and when Start is pressed) it writes a test picture into
// every pixel. Then: the joystick moves the cursor, A paints with the wheel's colour (the 12-bit wheel value used
// directly as RGB444), B erases, Select clears to black.
// Game-pad signals come from the 25 MHz domain: each passes a 2-flop synchronizer first.
// ***********************************************

module paint (
	input						clk,			// 50 MHz
	input						ready,		// PLL locked: nothing is written before this
	input						A, B, Select, Start, Left, Right, Up, Down,	// from gamepad (50 MHz; synchronized anyway)
	input			[11:0]	wheel,		// 25 MHz domain, used only as a colour
	output reg	[14:0]	wr_addr = 0,
	output reg	[11:0]	wr_d = 0,
	output reg				we = 0,
	output reg	[7:0]		cx,			// cursor (set while !ready: Quartus ignores initial values on output ports)
	output reg	[6:0]		cy,
	output reg				filling
	);

localparam W = 160, H = 120;

reg [7:0] s1 = 0, s2 = 0;			// synchronizers: {Down, Up, Right, Left, Start, Select, B, A}
always @(posedge clk) begin
	s1 <= {Down, Up, Right, Left, Start, Select, B, A};
	s2 <= s1;
end
wire a_btn = s2[0], b_btn = s2[1], sel_btn = s2[2], start_btn = s2[3];
wire left = s2[4], right = s2[5], up = s2[6], down = s2[7];

// test picture: colour bands, a grid every 20 pixels, a white frame
reg	[7:0]		fx = 0;
reg	[6:0]		fy = 0;
reg				clearing = 0;
wire	[11:0]	pattern = (fx == 0 || fx == W - 1 || fy == 0 || fy == H - 1) ? 12'hFFF :
						  (fx % 20 == 0 || fy % 20 == 0)                         ? 12'h444 :
						  {fx[7:4], fy[6:3], 4'hF - fx[7:4]};

reg	[20:0]	slow = 0;			// cursor speed: one step per 2^21 clocks = 24 steps per second
always @(posedge clk) begin
	we <= 0;
	slow <= slow + 1'b1;
	if (!ready) begin				// wait for the PLL: block-RAM writes on an unsettled clock are lost
		fx <= 0;
		fy <= 0;
		filling <= 1;
		clearing <= 0;
		cx <= W / 2;
		cy <= H / 2;
	end
	else if (filling) begin
		we <= 1;
		wr_addr <= fy * W + fx;
		wr_d <= clearing ? 12'h000 : pattern;
		if (fx == W - 1) begin
			fx <= 0;
			if (fy == H - 1) begin
				fy <= 0;
				filling <= 0;
			end
			else
				fy <= fy + 1'b1;
		end
		else
			fx <= fx + 1'b1;
	end
	else begin
		if (start_btn || sel_btn) begin
			filling <= 1;
			clearing <= sel_btn;
		end
		if (slow == 0) begin
			if (left  && cx > 0)     cx <= cx - 1'b1;
			if (right && cx < W - 1) cx <= cx + 1'b1;
			if (up    && cy > 0)     cy <= cy - 1'b1;
			if (down  && cy < H - 1) cy <= cy + 1'b1;
		end
		if (a_btn || b_btn) begin
			we <= 1;
			wr_addr <= cy * W + cx;
			wr_d <= a_btn ? (wheel == 0 ? 12'h111 : wheel) : 12'h000;
		end
	end
end

endmodule
