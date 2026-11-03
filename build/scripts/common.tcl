set root [file normalize [file join [file dirname [info script]] .. ..]]
set build [file join $root build]
if {[info exists ::env(DDS_BUILD_DIR)]} {set build [file normalize $::env(DDS_BUILD_DIR)]}
file mkdir $build
set sources [list [file join $root src rtl control_pkg.sv]]
foreach f [glob [file join $root src rtl *.v] [file join $root src rtl *.sv]] {
    if {[file tail $f] ne "control_pkg.sv"} {lappend sources $f}
}
proc make_project {} {
    global root build sources
    create_project -force dds_control_v3 [file join $build project] -part xc7a35tcsg324-1
    add_files -norecurse $sources
    add_files -norecurse [file join $root src rtl gaussian_q8.mem]
    add_files -norecurse [file join $root src rtl fcw_100ksps.mem]
    add_files -norecurse [file join $root src rtl rx_sine.mem]
    add_files -norecurse [file join $root src rtl rx_steps.mem]
    add_files -norecurse [file join $root src rtl ai_mlp.mem]
    add_files -fileset constrs_1 [file join $root board constraints board.xdc]
    set_property top ego1_control_top [get_filesets sources_1]
    update_compile_order -fileset sources_1
}
