# set_property_CLOCK_DEDICATED_ROUTE - this controls how Vivado routes a clock signal through the FPGA's physical clock network.
# ANY_CMT_COLUMN - this relaxes the default routing rule.
# normally, Vivado requires clock signals to follow "dedicated clock routes" - special low-skew routing tracks that go from a clock buffer directly to the clock region where the logic lives.
# the default rule is SAME_CMT_COLUMN, meaning the clock must stay within the same Clock Management Tile (CMT) Column.
# [get_nets_design_1/clk_wiz_1/inst/clk_100] - this targets the clk_100 100 MHz clock output net from our Clocking Wizard.

# we tell Vivado it's okay to route this clock across multiple CMT columns.
# the tradeoff is slightly more clock skew, but at 100 MHz this is negligible - the clock period is 10 ns and the skew might be 0.1-0.2 ns.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets design_1_i/clk_wiz_1/inst/clk_100]