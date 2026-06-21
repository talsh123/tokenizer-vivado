# gen_reports.tcl -- one-shot Vivado report dump for the book (Stage 5 P0 #6, #7).
#
# Produces utilization + timing reports and copies the .xdc into analysis/results/.
# Run from the Vivado Tcl console with the uart project OPEN:
#     source c:/Users/talsh/.Xilinx/projects/uart/analysis/gen_reports.tcl
# (or:  vivado -mode batch -source analysis/gen_reports.tcl uart.xpr )
#
# Safe to re-run; it overwrites the report files.

set out {c:/Users/talsh/.Xilinx/projects/uart/analysis/results}
file mkdir $out

# --- make sure an implemented design is in memory ---------------------------
if {[catch {get_property TOP [current_design]}]} {
    puts "INFO: no design open -- opening impl_1 run"
    open_run impl_1
}
set dname [get_property NAME [current_design]]
puts "INFO: reporting on design '$dname'"

# --- 1. Utilization (P0 #6): LUT / FF / BRAM / DSP --------------------------
report_utilization            -file $out/utilization_impl.rpt
report_utilization -hierarchical -hierarchical_depth 3 \
                               -file $out/utilization_hier.rpt
puts "WROTE: utilization_impl.rpt, utilization_hier.rpt"

# --- 2. Timing (P0 #7): WNS / TNS / Fmax -----------------------------------
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained \
                       -file $out/timing_summary.rpt
# worst 10 setup paths, handy for the Fmax / critical-path discussion
report_timing -delay_type max -sort_by group -max_paths 10 -path_type summary \
              -file $out/timing_worst_paths.rpt
puts "WROTE: timing_summary.rpt, timing_worst_paths.rpt"

# --- 3. Copy the constraint (.xdc) files next to the reports ----------------
set xdcs [get_files -quiet -filter {FILE_TYPE == XDC}]
if {[llength $xdcs] == 0} {
    puts "WARN: no .xdc found via get_files; check uart.srcs/constrs_1/"
} else {
    foreach f $xdcs {
        set dst $out/[file tail $f]
        file copy -force $f $dst
        puts "COPIED xdc: $dst"
    }
}

# --- 4. Quick WNS echo so you see the headline immediately ------------------
if {![catch {set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]}]} {
    puts "----------------------------------------------------"
    puts "HEADLINE WNS (setup) = $wns ns   (negative = failing)"
    puts "----------------------------------------------------"
}
puts "DONE. Reports + xdc are in $out"
