// Small behavioral model of the DE10-Lite SDRAM (IS42S16320) for testbenches: CAS latency 3, burst length 1.
// Decodes commands on the rising edge of dram_clk. Read data is driven only in its valid window: from tAC (5.4 ns)
// after the CAS-latency edge to tOH (2.7 ns) after the next edge, 'x' outside it, so a controller that samples at
// the wrong time reads garbage. Stores {bank, row[3:0], col}: keep test addresses inside rows 0..15.
// Checks: command before init (MRS) and a READ/WRITE to a bank that is not open are reported as errors.
`timescale 1ns/1ps

module sdram_model (
	input					dram_clk,
	input					cke, cs_n, ras_n, cas_n, we_n,
	input		[1:0]		ba,
	input		[12:0]	a,
	inout		[15:0]	dq,
	output integer		errors
	);

reg	[15:0]	mem [0:65535];
reg	[12:0]	open_row [0:3];
reg	[3:0]		is_open = 0;
reg				mode_set = 0;
reg	[15:0]	dq_drive = 16'hxxxx;
reg				drive = 0;
integer			i;
initial errors = 0;
assign dq = drive ? dq_drive : 16'hzzzz;

always @(posedge dram_clk) if (cke && !cs_n) begin
	case ({ras_n, cas_n, we_n})
		3'b000: mode_set <= 1;													// MRS
		3'b011: begin open_row[ba] <= a; is_open[ba] <= 1; end					// ACT
		3'b010: if (a[10]) is_open <= 0; else is_open[ba] <= 0;				// PRE
		3'b001: ;																	// REF
		3'b100, 3'b101: begin														// WRITE / READ
			if (!mode_set || !is_open[ba]) begin
				errors = errors + 1;
				$display("%t model: %s to bank %0d not ready", $time, we_n ? "READ" : "WRITE", ba);
			end
			if (!we_n)
				mem[{ba, open_row[ba][3:0], a[9:0]}] <= dq;
			else begin
				// CAS latency 3: data valid from 3 edges + tAC to 4 edges + tOH after this edge
				fork : rd
					reg [15:0] v;
					v = mem[{ba, open_row[ba][3:0], a[9:0]}];
					begin
						repeat (3) @(posedge dram_clk);
						#5.4 begin dq_drive = v; drive = 1; end
						@(posedge dram_clk);
						#2.7 begin dq_drive = 16'hxxxx; drive = 0; end
					end
				join_none
			end
			if (a[10]) is_open[ba] <= 0;											// auto-precharge
		end
	endcase
end

endmodule
