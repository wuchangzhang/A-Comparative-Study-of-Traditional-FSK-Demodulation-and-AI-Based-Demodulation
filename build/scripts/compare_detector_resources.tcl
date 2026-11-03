set root [file normalize [file join [file dirname [info script]] .. ..]]
set out [file join $root build detector_comparison]
file mkdir $out
set_param general.maxThreads 1
if {![string match "2026.1*" [version -short]]} {error "Vivado 2026.1 required"}
foreach mode {0 1 2 3} name {full majority trim_max ai} {
    create_project -force detector_benchmark [file join $out project_$name] -part xc7a35tcsg324-1
    set_property target_language Verilog [current_project]
    read_verilog -sv [list [file join $root src rtl fsk_correlator.sv] [file join $root src rtl ai_mlp.sv] [file join $root sim detector_comparison detector_benchmark.sv]]
    add_files -norecurse [file join $root src rtl rx_sine.mem]
    add_files -norecurse [file join $root src rtl ai_mlp.mem]
    set dir [file join $out $name]
    file mkdir $dir
    synth_design -top detector_benchmark -generic MODE=$mode -part xc7a35tcsg324-1 -mode out_of_context -flatten_hierarchy none
    create_clock -name sys_clk_100m -period 10.000 [get_ports clk]
    report_utilization -file [file join $dir synth_utilization.rpt]
    report_utilization -hierarchical -file [file join $dir synth_hierarchy.rpt]
    opt_design
    place_design
    phys_opt_design
    route_design
    report_utilization -file [file join $dir routed_utilization.rpt]
    report_utilization -hierarchical -file [file join $dir routed_hierarchy.rpt]
    report_timing_summary -file [file join $dir timing_summary.rpt]
    report_drc -file [file join $dir drc.rpt]
    write_checkpoint -force [file join $dir routed.dcp]
    close_project
    puts "BENCHMARK_DONE $name"
}
