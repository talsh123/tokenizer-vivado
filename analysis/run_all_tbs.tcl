# run_all_tbs.tcl -- run every testbench in sim_1 back-to-back, in one action.
#
# Vivado xsim simulates ONE top at a time, so this loops: set each TB as the sim top, launch
# behavioral simulation, run to its $finish (all 12 TBs self-terminate), read the sim log, classify
# PASS/FAIL, close, next. Prints a summary table at the end.
#
# Usage (uart project open in Vivado), in the Tcl console:
#     source c:/Users/talsh/.Xilinx/projects/uart/analysis/run_all_tbs.tcl
#
# Note: each TB is elaborated fresh, so the whole sweep takes a while (xelab dominates). Watch the
# console for each TB's own PASSED/FAILED banner; the summary at the bottom is the quick read.

set tbs {
    tb_pre_tokenizer
    tb_trie_engine
    tb_top_tokenizer
    tb_tokenizer_axi_lite
    tb_word_boundary
    tb_axi_dma
    tb_axi_pipeline
    tb_h1_h2_m1
    tb_h1_bug_investigation
    tb_m2_overflow
    tb_perf_measurement
    tb_corpus_perf
}

catch { close_sim -force }
# Disable launch_simulation's auto-run so it only LOADS the snapshot; we then issue exactly one
# `run all` per TB. Without this, launch_simulation auto-runs to the testbench's normal $finish and
# the extra `run all` continues the finished sim forward into its watchdog $finish -- printing a
# bogus "Simulation timed out!" on tests that actually PASSED (and tripping the FAIL classifier).
set_property -name {xsim.simulate.runtime} -value {0us} -objects [get_filesets sim_1]
set proj_dir [get_property DIRECTORY [current_project]]
set logf [file join $proj_dir "[current_project].sim" sim_1 behav xsim simulate.log]
set summary {}

foreach tb $tbs {
    puts "\n================ RUN: $tb ================"
    set verdict "ERROR"
    if {![catch {
        set_property top $tb [get_filesets sim_1]
        set_property top_lib xil_defaultlib [get_filesets sim_1]
        launch_simulation
        run all
    } emsg]} {
        # classify from the freshly written simulate.log. A real hang trips the watchdog ("timed
        # out"); a real assertion prints "FAIL"/"FAILED". With the auto-run disabled above, the
        # watchdog only fires on a genuine hang, so this is reliable.
        set verdict "done (no PASS/FAIL marker)"
        if {[file exists $logf]} {
            set fh [open $logf r]; set txt [read $fh]; close $fh
            if {[regexp {(?i)fail|timed out|error:} $txt]} {
                set verdict "FAIL"
            } elseif {[regexp {(?i)pass} $txt]} {
                set verdict "PASS"
            }
        }
    } else {
        puts "  !! could not run $tb: $emsg"
    }
    lappend summary [format "  %-26s %s" $tb $verdict]
    catch { close_sim -force }
}

puts "\n================ SUMMARY ================"
foreach s $summary { puts $s }
puts "========================================"
puts "(PASS/FAIL inferred from simulate.log keywords; scroll up for each TB's full output.)"
