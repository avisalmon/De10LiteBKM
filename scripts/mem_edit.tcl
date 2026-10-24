# In-System Memory Content Editor from the command line: read or rewrite a named RAM/ROM while the design runs.
#
#   quartus_stp -t scripts/mem_edit.tcl list
#   quartus_stp -t scripts/mem_edit.tcl write <NAME> <file.mif|file.hex>
#   quartus_stp -t scripts/mem_edit.tcl read  <NAME> <out.mif>
#
# NAME is the INSTANCE_NAME given in the memory's lpm_hint ("ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=IMG").
# Uses the first USB-Blaster and the first device on it (the DE10-Lite's MAX 10).
package require ::quartus::insystem_memory_edit

set hw  [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
set cmd [lindex $argv 0]

begin_memory_edit -hardware_name $hw -device_name $dev
set found -1
foreach inst [get_editable_mem_instances -hardware_name $hw -device_name $dev] {
    # {index depth width read/write mode type name}
    lassign $inst idx depth width mode type name
    if {$cmd eq "list"} { puts "MEM: index=$idx name=$name depth=$depth width=$width mode=$mode" }
    if {$cmd ne "list" && $name eq [lindex $argv 1]} { set found $idx }
}
if {$cmd eq "write" || $cmd eq "read"} {
    if {$found < 0} { end_memory_edit; error "no editable memory named [lindex $argv 1] (run: mem_edit.tcl list)" }
    set file [lindex $argv 2]
    set type [expr {[string match -nocase *.hex $file] ? "hex" : "mif"}]
    if {$cmd eq "write"} {
        update_content_to_memory_from_file -instance_index $found -mem_file_path $file -mem_file_type $type
        puts "OK: wrote $file into $name"
    } else {
        save_content_from_memory_to_file -instance_index $found -mem_file_path $file -mem_file_type $type
        puts "OK: read $name into $file"
    }
}
end_memory_edit
