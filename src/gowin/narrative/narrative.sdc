create_clock -name sys_clk_50m -period 20.000 [get_ports {sys_clk_50m}]
create_generated_clock -name audio_clk -source [get_ports {sys_clk_50m}] -divide_by 118 -multiply_by 29 [get_pins {pll/*/CLKOUT0}]
create_generated_clock -name video_pix -source [get_ports {sys_clk_50m}] -divide_by 2 -multiply_by 1 [get_pins {video_pll/PLLA_inst/CLKOUT1}]
create_generated_clock -name video_serial -source [get_ports {sys_clk_50m}] -divide_by 2 -multiply_by 5 [get_pins {video_pll/PLLA_inst/CLKOUT0}]
create_generated_clock -name chorus_capture_clk -source [get_ports {sys_clk_50m}] -multiply_by 29 -divide_by 30208 -phase 180 [get_pins {chorus_capture_clk_s1/Q}]
# Only asynchronous AUDIO<->VIDEO crossings use bundled-data handshake + 2FF control synchronizers.
# Pixel and serializer clocks remain related and are NOT cut from one another.
set_clock_groups -asynchronous -group [get_clocks {audio_clk chorus_capture_clk}] -group [get_clocks {video_pix video_serial}]
# The source bundle changes once per pixel. Its toggle passes two fast FFs;
# dvi_tx_ddr loads the stable bundle on the THIRD 125MHz edge (24ns), then shifts
# five DDR pairs. This is a real enable contract, not an asynchronous clock cut.
# Request/run synchronizers and fast-domain shift->ODDR paths remain single-cycle.
set_multicycle_path 3 -setup -from [get_clocks {video_pix}] -to [get_pins {dvi/shift_words*/D}]
set_multicycle_path 2 -hold -from [get_clocks {video_pix}] -to [get_pins {dvi/shift_words*/D}]
