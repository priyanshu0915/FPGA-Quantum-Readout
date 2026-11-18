# rfsoc_500mhz.xdc - 500 MHz (2.0 ns) DSP clock constraint
create_clock -period 3.000 -name clk [get_ports clk]

# Keep debug signals internal during out-of-context (OOC) synthesis so Vivado doesn't assign 250 IOBs
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]