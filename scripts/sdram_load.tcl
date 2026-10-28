# The PC side of lib/rtl/sdram_loader.sv: runs loader commands through quartus_stp's JTAG API (the portable route;
# scripts/usb_blaster.py is the fast one).
#
#   quartus_stp -t scripts/sdram_load.tcl <job.txt> [instance]      run the commands of a file
#   quartus_stp -t scripts/sdram_load.tcl - [instance] [answers]    read commands from stdin until "quit" or EOF
#
# scripts/sdram_load.py drives the stdin form and reads the answers (run this by hand only to debug). One command
# a line; every command ends with an "OK" line (or "ERROR <why>", after which the script exits). The answers go to
# stdout, or to the <answers> file when one is named: quartus_stp holds its stdout back until it exits when that is
# a pipe, while a file written without buffering is read by the other side at once.
#   status                                  -> STATUS <80 hex digits: the 320-bit status register, MSB first>
#   waddr <word>  |  raddr <word>           the next SDRAM word address to write / to read
#   write <file> <offset> <bytes> <chunk>   file bytes -> SDRAM (after waddr), <chunk> bytes per DR scan
#   read  <file> <bytes> <chunk>            SDRAM -> end of <file> (after raddr), <chunk> bytes per DR scan
#   check <word> <words>                    the board CRCs that SDRAM range -> STATUS when it is done
#   wait <ms>
# write / read / check also print TIME <what> <bytes> <microseconds> <chunk>; long ones print PROGRESS lines.
# Bytes go out in file order; every 2 bytes are one SDRAM word, the first byte in its low half. A DR value in
# hex is written most significant digit first, and the first bit shifted is its LSB: so the hex of a chunk is the
# chunk's low-nibble-first hex (binary scan h*), reversed.
set IR_WADDR 1
set IR_WRITE 2
set IR_RADDR 3
set IR_READ 4
set IR_STATUS 5
set IR_CHECK 6

set jobfile [lindex $argv 0]
set inst 0
if {[llength $argv] > 1} { set inst [lindex $argv 1] }
set out stdout
if {[llength $argv] > 2} {
    set out [open [lindex $argv 2] w]
    fconfigure $out -buffering none
}

proc say {line} {
    global out
    puts $out $line
    flush $out
}

proc pick_device {} {
    foreach hw [get_hardware_names] {
        foreach dev [get_device_names -hardware_name $hw] {
            if {[string match "*10M50*" $dev]} { return [list $hw $dev] }
        }
    }
    error "no MAX 10 (10M50) on any JTAG cable: is the board plugged in?"
}

proc vir {v} {
    global inst
    device_virtual_ir_shift -instance_index $inst -ir_value $v -no_captured_ir_value
}

proc vdr64 {hi lo} {
    global inst
    device_virtual_dr_shift -instance_index $inst -length 64 -dr_value [format %08X%08X $hi $lo] \
        -value_in_hex -no_captured_dr_value
}

proc status_scan {} {
    global inst
    set h [device_virtual_dr_shift -instance_index $inst -length 320 -dr_value [string repeat 0 80] -value_in_hex]
    return [string range "[string repeat 0 80]$h" end-79 end]
}

proc st_word {h i} {
    scan [string range $h [expr {80 - 8 * ($i + 1)}] [expr {79 - 8 * $i}]] %x v
    return $v
}

proc do_write {file offset bytes chunk} {
    global inst IR_WRITE IR_STATUS
    set f [open $file r]
    fconfigure $f -translation binary
    seek $f $offset
    vir $IR_WRITE
    set left $bytes
    set done 0
    set step [expr {4 << 20}]
    set t0 [clock microseconds]
    while {$left > 0} {
        set n [expr {min($chunk, $left)}]
        set data [read $f $n]
        if {[string length $data] != $n} { error "$file is shorter than offset + bytes" }
        binary scan $data h* hex
        device_virtual_dr_shift -instance_index $inst -length [expr {8 * $n}] -dr_value [string reverse $hex] \
            -value_in_hex -no_captured_dr_value
        incr left -$n
        incr done $n
        if {$done % $step < $n && $left > 0} {
            say "PROGRESS write $done [expr {[clock microseconds] - $t0}]"
        }
    }
    # scans without a captured value are queued: a captured one makes sure everything went out before the clock stops
    vir $IR_STATUS
    status_scan
    say "TIME write $bytes [expr {[clock microseconds] - $t0}] $chunk"
    close $f
}

proc do_read {file bytes chunk} {
    global inst IR_READ
    set f [open $file a]
    fconfigure $f -translation binary
    vir $IR_READ
    set left $bytes
    set done 0
    set step [expr {4 << 20}]
    set zeros [string repeat 0 [expr {2 * $chunk}]]
    set t0 [clock microseconds]
    while {$left > 0} {
        set n [expr {min($chunk, $left)}]
        if {$n != $chunk} { set zeros [string repeat 0 [expr {2 * $n}]] }
        set hex [device_virtual_dr_shift -instance_index $inst -length [expr {8 * $n}] -dr_value $zeros -value_in_hex]
        set pad [expr {2 * $n - [string length $hex]}]
        if {$pad > 0} { set hex "[string repeat 0 $pad]$hex" }
        puts -nonewline $f [binary format h* [string reverse $hex]]
        incr left -$n
        incr done $n
        if {$done % $step < $n && $left > 0} {
            say "PROGRESS read $done [expr {[clock microseconds] - $t0}]"
        }
    }
    say "TIME read $bytes [expr {[clock microseconds] - $t0}] $chunk"
    close $f
}

proc do_check {word words} {
    global IR_CHECK IR_STATUS
    vir $IR_CHECK
    vdr64 $words $word
    set t0 [clock microseconds]
    vir $IR_STATUS
    while 1 {
        set h [status_scan]
        if {[st_word $h 1] & 0x10} break
        if {[clock microseconds] - $t0 > 60000000} { error "the board CRC did not finish in 60 s" }
        after 20
    }
    say "TIME check [expr {2 * $words}] [expr {[clock microseconds] - $t0}] 0"
    say "STATUS $h"
}

proc do_line {line} {
    global IR_STATUS IR_WADDR IR_RADDR
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} return
    set args [lrange $line 1 end]
    switch -- [lindex $line 0] {
        status { vir $IR_STATUS; say "STATUS [status_scan]" }
        waddr  { vir $IR_WADDR; vdr64 0 [lindex $args 0] }
        raddr  { vir $IR_RADDR; vdr64 0 [lindex $args 0] }
        write  { do_write {*}$args }
        read   { do_read {*}$args }
        check  { do_check {*}$args }
        wait   { after [lindex $args 0] }
        default { error "unknown job command: $line" }
    }
    say "OK"
}

set fail [catch {
    lassign [pick_device] hw dev
    say "DEVICE $hw | $dev"
    open_device -hardware_name $hw -device_name $dev
    device_lock -timeout 10000
} err]
if {$fail} {
    say "ERROR $err"
    exit 1
}
set fail [catch {
    if {$jobfile eq "-"} {
        fconfigure stdin -buffering line
        while {[gets stdin line] >= 0} {
            if {[string trim $line] eq "quit"} break
            do_line $line
        }
    } else {
        set jf [open $jobfile r]
        set lines [split [read $jf] "\n"]
        close $jf
        foreach line $lines { do_line $line }
    }
} err]
device_unlock
close_device
if {$fail} {
    say "ERROR $err"
    exit 1
}
say "DONE"
