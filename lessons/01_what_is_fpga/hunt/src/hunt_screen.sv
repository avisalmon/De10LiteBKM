// Lesson 1 board hunt: the screen (640x480)
//
//   BOARD HUNT                 title
//   STEP 05 OF 13              and a bar of 13 boxes: done green, current yellow, to do grey
//   the challenge (2 lines)    and a hint below it
//   SWITCHES                   10 boxes that follow SW9..SW0
//   WHEEL                      a bar that follows the wheel
// The border flashes green while the success beep sounds. Colours are RGB444.
// ***********************************************

module hunt_screen (
	input		[31:0]	pxl_x,
	input		[31:0]	pxl_y,
	input		[3:0]		step,
	input		[9:0]		sw,
	input		[11:0]	wheel,
	input					flash,
	output	[3:0]		Red,
	output	[3:0]		Green,
	output	[3:0]		Blue
	);

wire	[9:0]		x = pxl_x[9:0];
wire	[8:0]		y = pxl_y[8:0];
wire				done = step == 13;

// ---- the challenge text for each step (26 characters per line, centred)
reg	[8*26-1:0]	l1, l2, hint;
always @(*) begin
	case (step)
		 0: begin l1 = "   PUT ALL 10 SWITCHES    "; l2 = "    DOWN (TOWARD YOU)     "; hint = "THE SWITCHES: SW9 ... SW0 "; end
		 1: begin l1 = "    FLIP SWITCH SW0 UP    "; l2 = "   (THE RIGHTMOST ONE)    "; hint = "    WATCH THE RED LEDS    "; end
		 2: begin l1 = "     NOW ONLY SW9 UP      "; l2 = "    (THE LEFTMOST ONE)    "; hint = "    ONE LED PER SWITCH    "; end
		 3: begin l1 = "    SHOW THE NUMBER 5     "; l2 = "IN BINARY ON THE SWITCHES "; hint = "        5 = 4 + 1         "; end
		 4: begin l1 = "        PRESS KEY0        "; l2 = "     (A PUSH BUTTON)      "; hint = "ITS NAME IS PRINTED BY IT "; end
		 5: begin l1 = "        PRESS KEY1        "; l2 = " (THE OTHER PUSH BUTTON)  "; hint = "     HOLD IT A MOMENT     "; end
		 6: begin l1 = "   PUSH THE JOYSTICK UP   "; l2 = "                          "; hint = "      ON THE SHIELD       "; end
		 7: begin l1 = "  PUSH THE JOYSTICK LEFT  "; l2 = "                          "; hint = "      ON THE SHIELD       "; end
		 8: begin l1 = "      PRESS BUTTON A      "; l2 = "                          "; hint = "      ON THE SHIELD       "; end
		 9: begin l1 = "      PRESS BUTTON B      "; l2 = "                          "; hint = "    LISTEN: THE BUZZER    "; end
		10: begin l1 = "       PRESS START        "; l2 = "                          "; hint = "      ON THE SHIELD       "; end
		11: begin l1 = "   TURN THE WHEEL UNTIL   "; l2 = "     THE BAR IS FULL      "; hint = "    THE BIG METAL KNOB    "; end
		12: begin l1 = "   TURN THE WHEEL UNTIL   "; l2 = "     THE BAR IS EMPTY     "; hint = "   THE WHEEL IS A DIAL    "; end
		default: begin l1 = "      HUNT COMPLETE!      "; l2 = "   YOU KNOW YOUR BOARD    "; hint = "   SELECT = PLAY AGAIN    "; end
	endcase
end

// "STEP 05 OF 13", or "  ALL DONE!  " at the end
wire	[3:0]		n = step + 1'b1;
wire	[7:0]		tens = (n >= 10) ? "1" : "0";
wire	[7:0]		ones = 8'h30 + ((n >= 10) ? n - 4'd10 : n);
wire	[8*13-1:0]	counter = done ? "  ALL DONE!  " : {"STEP ", tens, ones, " OF 13"};

wire	t_title, t_count, t_l1, t_l2, t_hint, t_sw, t_wheel;
hunt_text #(.X(160), .Y(20),  .LEN(10), .SCALE(4)) title(.x(x), .y(y), .text("BOARD HUNT"), .on(t_title));
hunt_text #(.X(216), .Y(72),  .LEN(13), .SCALE(2)) count(.x(x), .y(y), .text(counter), .on(t_count));
hunt_text #(.X(8),   .Y(150), .LEN(26), .SCALE(3)) line1(.x(x), .y(y), .text(l1), .on(t_l1));
hunt_text #(.X(8),   .Y(186), .LEN(26), .SCALE(3)) line2(.x(x), .y(y), .text(l2), .on(t_l2));
hunt_text #(.X(112), .Y(240), .LEN(26), .SCALE(2)) hintl(.x(x), .y(y), .text(hint), .on(t_hint));
hunt_text #(.X(256), .Y(296), .LEN(8),  .SCALE(2)) swl(.x(x), .y(y), .text("SWITCHES"), .on(t_sw));
hunt_text #(.X(280), .Y(376), .LEN(5),  .SCALE(2)) whl(.x(x), .y(y), .text("WHEEL"), .on(t_wheel));

// ---- progress: 13 boxes of 36 pixels with a 4-pixel gap, from x = 60
wire	[9:0]		px = x - 60;
wire	[3:0]		box = px / 40;
wire				in_prog = (x >= 60) && (x < 580) && (y >= 104) && (y < 120) && (px % 40 < 36);

// ---- switches: 10 boxes of 32 pixels with a 4-pixel gap, from x = 140; SW9 on the left like on the board
wire	[9:0]		sx = x - 140;
wire	[3:0]		sbox = sx / 36;
wire				in_sw = (x >= 140) && (x < 500) && (y >= 320) && (y < 352) && (sx % 36 < 32);
wire				sw_on = sw[9 - sbox];

// ---- wheel bar: 512 pixels wide from x = 64, filled up to wheel / 8
wire				in_wheel = (x >= 64) && (x < 576) && (y >= 400) && (y < 424);
wire				wheel_fill = (x - 64) < wheel[11:3];

wire				border = (x < 8) || (x >= 632) || (y < 8) || (y >= 472);

reg	[11:0]	rgb;
always @(*) begin
	rgb = 12'h113;															// dark blue background
	if (border && flash)				rgb = 12'h3D5;
	if (in_prog)						rgb = (box < step) ? 12'h3C5 : (box == step) ? 12'hFD2 : 12'h334;
	if (in_sw)							rgb = sw_on ? 12'hF32 : 12'h334;
	if (in_wheel)						rgb = wheel_fill ? 12'h4CD : 12'h334;
	if (t_title)						rgb = done ? 12'h3D5 : 12'h4CD;
	if (t_count || t_sw || t_wheel)	rgb = 12'hBBC;
	if (t_l1 || t_l2)					rgb = 12'hFFF;
	if (t_hint)							rgb = 12'h89A;
end

assign {Red, Green, Blue} = rgb;

endmodule
