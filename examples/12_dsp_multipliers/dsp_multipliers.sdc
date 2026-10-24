create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_pll_clocks
derive_clock_uncertainty

# The engines' results (acc, cycles) are read in the 50 MHz domain only after their "done" has crossed through a
# synchronizer, when they no longer change: these paths need no timing (without this: -0.24 ns from 75 MHz to 50 MHz).
set_false_path -from [get_registers {*mac:*|acc[*] *mac:*|cycles[*]}] -to [get_clocks clk50]
