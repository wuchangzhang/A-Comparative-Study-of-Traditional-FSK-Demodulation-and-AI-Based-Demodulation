# Rebuild the final v7 design without overwriting delivered artifacts.
set root [file normalize [file join [file dirname [info script]] .. ..]]
if {![info exists ::env(DDS_BUILD_DIR)]} {
    set ::env(DDS_BUILD_DIR) [file join $root build rebuild_v7]
}
set output [file normalize $::env(DDS_BUILD_DIR)]
foreach protected [list [file join $root build burst_v7] [file join $root board burst_v7]] {
    if {$output eq [file normalize $protected]} {
        error "Delivered artifacts are read-only; use a separate rebuild directory"
    }
}
source [file join [file dirname [info script]] common.tcl]
set_param synth.maxThreads 1
set max_threads 1
if {[info exists ::env(DDS_MAX_THREADS)]} {set max_threads $::env(DDS_MAX_THREADS)}
set_param general.maxThreads $max_threads
make_project
set flatten_hierarchy none
if {[info exists ::env(DDS_FLATTEN_HIERARCHY)]} {set flatten_hierarchy $::env(DDS_FLATTEN_HIERARCHY)}
synth_design -top ego1_control_top -part xc7a35tcsg324-1 -flatten_hierarchy $flatten_hierarchy
report_utilization -file [file join $build synthesis_utilization.rpt]
report_timing -max_paths 30 -file [file join $build synthesis_paths.rpt]
write_checkpoint -force [file join $build synthesized.dcp]
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -tns_cleanup
report_timing_summary -file [file join $build timing_summary.rpt]
report_utilization -file [file join $build utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $build hierarchical_utilization.rpt]
report_drc -file [file join $build drc.rpt]
report_timing -to [all_outputs] -max_paths 60 -file [file join $build output_paths.rpt]
write_checkpoint -force [file join $build routed.dcp]
foreach path [get_timing_paths -to [all_outputs] -max_paths 100] {
    if {[get_property SLACK $path] eq "inf"} {error "Unconstrained output path"}
}
if {[llength [get_timing_paths -quiet -max_paths 1 -slack_lesser_than 0]]} {error "Setup timing failed"}
if {[llength [get_timing_paths -quiet -delay_type min -max_paths 1 -slack_lesser_than 0]]} {error "Hold timing failed"}
write_bitstream -force [file join $build ego1_control_v3_jammer.bit]
close_project
