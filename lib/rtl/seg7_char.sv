// ASCII character -> 7-segment pattern for the DE10-Lite HEX displays (active low, bit 7 = decimal point)
//
// Digits, most letters as the usual 7-segment shapes (A b C d E F G H I J L n o P q r S t U y), - _ = space.
// Letters with no fair shape (K M V W X Z) show as a dash. dp = 1 lights the decimal point.
// Bit order: 0 = a (top), 1 = b, 2 = c, 3 = d (bottom), 4 = e, 5 = f, 6 = g (middle), 7 = dp.
// ***********************************************

module seg7_char (
	input		[7:0]		ch,
	input					dp,
	output	[7:0]		seg
	);

reg	[6:0]	on;		// 1 = segment lit (gfedcba)
wire	[7:0]	c = (ch >= "a" && ch <= "z") ? ch - 8'h20 : ch;

always_comb begin
	case (c)
		"0": on = 7'b0111111;  "1": on = 7'b0000110;  "2": on = 7'b1011011;  "3": on = 7'b1001111;
		"4": on = 7'b1100110;  "5": on = 7'b1101101;  "6": on = 7'b1111101;  "7": on = 7'b0000111;
		"8": on = 7'b1111111;  "9": on = 7'b1101111;
		"A": on = 7'b1110111;  "B": on = 7'b1111100;  "C": on = 7'b0111001;  "D": on = 7'b1011110;
		"E": on = 7'b1111001;  "F": on = 7'b1110001;  "G": on = 7'b0111101;  "H": on = 7'b1110110;
		"I": on = 7'b0000110;  "J": on = 7'b0011110;  "L": on = 7'b0111000;  "N": on = 7'b1010100;
		"O": on = 7'b1011100;  "P": on = 7'b1110011;  "Q": on = 7'b1100111;  "R": on = 7'b1010000;
		"S": on = 7'b1101101;  "T": on = 7'b1111000;  "U": on = 7'b0111110;  "Y": on = 7'b1101110;
		"-": on = 7'b1000000;  "_": on = 7'b0001000;  " ": on = 7'b0000000;  "=": on = 7'b1001000;
		default: on = 7'b1000000;
	endcase
end

assign seg = ~{dp, on};

endmodule
