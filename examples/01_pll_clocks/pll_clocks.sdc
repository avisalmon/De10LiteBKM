create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
create_clock -name clk50_2 -period 20.000 [get_ports MAX10_CLK2_50]
create_clock -name adc_clk10 -period 100.000 [get_ports ADC_CLK_10]
derive_pll_clocks
derive_clock_uncertainty
