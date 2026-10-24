# Arm Signal Tap, wait for the trigger, export the capture.
# quartus_stp -t stp_capture.tcl <file.stp> <out.vcd|out.csv> [timeout_s]
set stp     [lindex $argv 0]
set out     [lindex $argv 1]
set timeout [expr {[llength $argv] > 2 ? [lindex $argv 2] : 30}]
set fmt     [string trimleft [file extension $out] .]

open_session -name $stp
set rc [run -instance auto_signaltap_0 -signal_set "signal_set: 1" -trigger "trigger: 1" -data_log log_1 -timeout $timeout]
puts "run: $rc"
export_data_log -instance auto_signaltap_0 -signal_set "signal_set: 1" -trigger "trigger: 1" -data_log log_1 -filename $out -format $fmt
close_session
puts "exported $out"
