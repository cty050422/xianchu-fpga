set script_dir [file dirname [file normalize [info script]]]
open_project [file join $script_dir narrative narrative.gprj]
set_option -top_module instrument_display_top
set_option -verilog_std sysv2017
run all
run close
