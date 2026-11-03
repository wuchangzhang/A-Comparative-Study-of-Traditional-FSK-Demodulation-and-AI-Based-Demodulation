# Retry physical optimization from the routed burst checkpoint, without synthesis.
set root [file normalize [file join [file dirname [info script]] .. ..]]
if {![info exists ::env(DDS_BUILD_DIR)]} {
    error "Set DDS_BUILD_DIR to the rebuild directory containing routed.dcp"
}
set build [file normalize $::env(DDS_BUILD_DIR)]
foreach protected [list [file join $root build burst_v7] [file join $root board burst_v7]] {
    if {$build eq [file normalize $protected]} {
        error "Delivered artifacts are read-only; use a separate rebuild directory"
    }
}
set_param general.maxThreads 1
open_checkpoint [file join $build routed.dcp]
for {set pass 0} {$pass < 3} {incr pass} {
    if {![llength [get_timing_paths -quiet -max_paths 1 -slack_lesser_than 0]] &&
        ![llength [get_timing_paths -quiet -delay_type min -max_paths 1 -slack_lesser_than 0]]} {break}
    phys_opt_design -directive AggressiveExplore
    route_design -directive AggressiveExplore
    phys_opt_design -directive AggressiveExplore
    route_design -tns_cleanup
}
report_timing_summary -file [file join $build timing_summary.rpt]
report_timing -max_paths 30 -file [file join $build final_paths.rpt]
report_utilization -file [file join $build utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $build hierarchical_utilization.rpt]
report_drc -file [file join $build drc.rpt]
write_checkpoint -force [file join $build routed.dcp]
if {[llength [get_timing_paths -quiet -max_paths 1 -slack_lesser_than 0]]} {error "Setup timing failed"}
if {[llength [get_timing_paths -quiet -delay_type min -max_paths 1 -slack_lesser_than 0]]} {error "Hold timing failed"}
foreach path [get_timing_paths -to [all_outputs] -max_paths 100] {
    if {[get_property SLACK $path] eq "inf"} {error "Unconstrained output path"}
}
write_bitstream -force [file join $build ego1_control_v3_jammer.bit]
close_design
