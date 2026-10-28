#!/usr/bin/env tclsh

# Focused offline transport regressions, also runnable against a runtime snapshot.
set root [file normalize [file join [file dirname [info script]] ..]]
set wrapper [file join $root codex-retry]
if {[llength $argv]} { set wrapper [file normalize [lindex $argv 0]] }
set cases {large eof oversized fragmented-oversized retry reset manual pending picker-first unavailable eof-term eof-hup eof-input-eof guard latency}
# Preserve case attribution when the caller can retain only the exit status.
set caseStatuses {}
foreach case $cases { dict set caseStatuses $case [expr {48 + [dict size $caseStatuses]}] }
if {[llength $argv] > 1} { set cases [lrange $argv 1 end] }
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set environment [array get env]
set jobs {}
set failureStatus 0
try {
    set env(XDG_CONFIG_HOME) $scratch
    set env(TMPDIR) $scratch
    set env(PATH) "$scratch:$env(PATH)"
    set channel [open [file join $scratch codex] w]
    puts $channel {#!/usr/bin/env expect}
    puts $channel [list source [file join $root tests proxy-fixture.tcl]]
    puts $channel {
        package require json
        # Fixtures model the native bounded receiver, independently of the wrapper.
        set ::websocket::WS(maxlength) [expr {128 << 20}]
        foreach level [logger::levels] {
            ${::websocket::log}::logproc $level message {return}
        }
        proc identity {role} {
            set channel [open [file join $::env(TRANSPORT_DIR) "$role.[pid].pid"] w]
            puts $channel [pid]
            close $channel
        }
        proc history {id} {
            return [format {{"id":%d,"result":{"history":"BEGIN-%s-éλ-END"}}} \
                $id [string repeat h 17825792]]
        }
        proc latency {direction} {
            # Escapes, Unicode, number spelling, unknown fields and envelope order
            # must survive unchanged in both directions, without a fake JSON decoder.
            set envelope {"method" : "fixture/metadata"}
            if {$direction eq "request"} { set envelope {"id" : 41, "method" : "fixture/echo"} }
            return [format { { "params" : {"text":"%s","number":5.03e2,"large":9007199254740993123456789,"unknown":[]}, %s } } \
                [string repeat {Neutral \" \\ \u0000 \u00e9 λ. } 100000] $envelope]
        }
        proc oversized {socket fragmented} {
            # A valid data-frame header alone must reject before reading a body.
            # The fragmented case tests accumulated bytes, not just frame size.
            if {$fragmented} { websocket::send $socket text \{ 0 }
            set header [expr {$fragmented ? 0x807f : 0x817f}]
            set length [expr {(128 << 20) + ($fragmented ? 0 : 1)}]
            puts -nonewline $socket [binary format SW $header $length]
            flush $socket
        }
        proc rpc {socket id method} {
            websocket::send $socket text [format {{"id":%d,"method":"%s","params":{}}} $id $method]
        }
        if {[lrange $argv 0 2] eq {app-server daemon start}} { exit 0 }
        if {[lindex $argv 0] eq "app-server"} {
            if {[lindex $argv 1] ne "proxy"} { exit 90 }
            identity bridge
            set generation [llength [glob -directory $env(TRANSPORT_DIR) bridge.*.pid]]
            if {$env(TRANSPORT_CASE) eq "unavailable" && $generation > 1} { exit 0 }
            if {$env(TRANSPORT_CASE) eq "pending" && $generation == 2} {
                after 10000
                exit 0
            }
            proc request {socket type message} {
                if {$type ne "text"} { return }
                if {$::env(TRANSPORT_CASE) eq "latency" && [string length $message] > 2000000} {
                    if {$message ne [latency request]} { exit 87 }
                    websocket::send $socket text {{"id":41,"result":{}}}
                    return
                }
                set object [json::json2dict $message]
                set method [dict get $object method]
                if {$method eq "initialized"} { return }
                set log [open [file join $::env(TRANSPORT_DIR) requests] a]
                puts $log [list $::generation $method]
                close $log
                set id [dict get $object id]
                switch -- $method {
                    thread/resume {
                        if {$::env(TRANSPORT_CASE) eq "guard"} { exit 0 }
                        if {$::env(TRANSPORT_CASE) eq "manual"} {
                            if {$::generation == 1} {
                                if {[dict get $object params approvalPolicy] ne "never" ||
                                    [dict get $object params sandbox] ne "danger-full-access"} { exit 82 }
                                websocket::send $socket text [format {{"id":%d,"result":{"thread":{"id":"transport-session"},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}}}} $id]
                                return
                            }
                            if {[dict exists $object params approvalPolicy] || [dict exists $object params sandbox]} { exit 83 }
                        }
                        websocket::send $socket text [format {{"id":%d,"result":{"thread":{"id":"transport-session"},"approvalPolicy":"on-request","sandbox":{"type":"readOnly"}}}} $id]
                    }
                    fixture/latency { websocket::send $socket text [latency notification] }
                    fixture/history {
                        set history [history $id]
                        if {$id == 21} {
                            websocket::send $socket text [string range $history 0 9437183] 0
                            websocket::send $socket text [string range $history 9437184 end]
                        } else { websocket::send $socket text $history }
                    }
                    turn/start {
                        if {$::generation != 1 || $id != 7 || $::env(TRANSPORT_CASE) ni {retry reset}} { exit 84 }
                        websocket::send $socket text {{"id":7,"result":{"turn":{"id":"lost-turn","status":"inProgress","items":[]}}}}
                        set code [expr {$::env(TRANSPORT_CASE) eq "reset" ? "usageLimitExceeded" : "serverOverloaded"}]
                        websocket::send $socket text [format {{"method":"turn/completed","params":{"threadId":"transport-session","turn":{"id":"lost-turn","status":"failed","items":[],"error":{"message":"fixture failure","codexErrorInfo":"%s"}}}}} $code]
                    }
                    account/rateLimits/read {
                        if {$::env(TRANSPORT_CASE) ne "reset" || $::generation != 1} { exit 85 }
                        exit 0
                    }
                    fixture/eof { exit 0 }
                    fixture/oversized { oversized $socket 0 }
                    fixture/fragmented-oversized { oversized $socket 1 }
                    initialize - thread/list - thread/settings/update - fixture/ping {
                        websocket::send $socket text [format {{"id":%d,"result":{}}} $id]
                    }
                    default { exit 86 }
                }
            }
            fixture::start request
            vwait forever
        }
        identity tui
        trap SIG_IGN SIGTERM
        if {$env(TRANSPORT_CASE) eq "eof-input-eof"} {
            trap {puts EOF_DRAINED; flush stdout; exit 19} SIGTERM
        }
        exec stty raw -echo <@stdin
        puts -nonewline stdout "\033\[?1003h\033\[?1006h"
        flush stdout
        fconfigure stdin -blocking 0 -encoding binary -translation binary
        set url [lindex $argv 1]
        set token $env([lindex $argv 3])
        set phase initial
        set attempts 0
        set main ""
        set picker ""
        set connectionSequence 0
        set connections {}
        proc connect {role} {
            set ticket [incr ::connectionSequence]
            dict set ::connections $role $ticket
            if {[catch {
                websocket::open $::url [list receive $role $ticket] \
                    -headers [list Authorization "Bearer $::token"] -timeout 2000
            } message]} { receive $role $ticket "" error $message }
        }
        proc pending_eof {socket} {
            # Establish the pending picker generation before retiring the primary.
            if {[llength [glob -nocomplain -directory $::env(TRANSPORT_DIR) bridge.*.pid]] == 2} {
                rpc $socket 12 fixture/eof
            } else {
                after 10 [list pending_eof $socket]
            }
        }
        set latencyInbound 0
        set latencyOutbound 0
        set latencyKeys 0
        set latencySent 0
        proc latency_next {} {
            if {$::latencyInbound && $::latencyKeys == 1 && !$::latencySent} {
                set ::latencySent 1
                websocket::send $::main text [latency request]
            }
            if {$::latencyOutbound && $::latencyKeys == 2} {
                puts INPUT_READY
                flush stdout
            }
        }
        proc receive {role ticket socket type message} {
            if {![dict exists $::connections $role] || [dict get $::connections $role] != $ticket} { return }
            if {$type eq "connect"} {
                set ::$role $socket
                rpc $socket 0 initialize
            } elseif {$type eq "text"} {
                if {$::env(TRANSPORT_CASE) eq "latency" && [string length $message] > 2000000} {
                    if {$message ne [latency notification]} { exit 88 }
                    puts LATENCY_DELIVERED
                    flush stdout
                    set ::latencyInbound 1
                    latency_next
                    return
                }
                if {[string length $message] > 16777216} {
                    set id [expr {$role eq "main" ? 11 : 21}]
                    set expected [encoding convertto utf-8 [history $id]]
                    set actual [encoding convertto utf-8 $message]
                    if {[string length $actual] != [string length $expected] || \
                        [zlib crc32 $actual] != [zlib crc32 $expected] || $actual ne $expected} { exit 81 }
                    puts "DELIVERED:$role:[string length $actual]:[zlib crc32 $actual]"
                    flush stdout
                    if {$role eq "main"} { connect picker } else {
                        rpc $socket 22 fixture/oversized
                    }
                    return
                }
                set object [json::json2dict $message]
                if {[dict exists $object method]} {
                    if {[dict get $object method] eq "turn/completed" && $::env(TRANSPORT_CASE) eq "retry"} {
                        rpc $socket 12 fixture/eof
                    }
                    return
                }
                set id [dict get $object id]
                if {$id == 0} {
                    if {$role eq "main"} {
                        websocket::send $socket text {{"id":1,"method":"thread/resume","params":{"threadId":"transport-session"}}}
                    } elseif {$::env(TRANSPORT_CASE) eq "large"} {
                        rpc $socket 21 fixture/history
                    } else { rpc $socket 21 thread/list }
                } elseif {$id == 1} {
                    if {$::phase eq "reconnecting"} {
                        puts REATTACHED
                        if {$::env(TRANSPORT_CASE) eq "picker-first"} {
                            rpc $::picker 22 fixture/eof
                        } else { puts INPUT_READY }
                        flush stdout
                    } elseif {$::env(TRANSPORT_CASE) eq "latency"} {
                        rpc $socket 40 fixture/latency
                    } elseif {$::env(TRANSPORT_CASE) eq "large"} {
                        rpc $socket 11 fixture/history
                    } elseif {$::env(TRANSPORT_CASE) in {retry reset}} {
                        websocket::send $socket text {{"id":7,"method":"turn/start","params":{"threadId":"transport-session","input":[{"type":"text","text":"neutral fixture"}]}}}
                    } elseif {$::env(TRANSPORT_CASE) eq "manual"} {
                        websocket::send $socket text {{"id":8,"method":"thread/settings/update","params":{"threadId":"transport-session","approvalPolicy":"on-request","sandboxPolicy":{"type":"readOnly"}}}}
                    } elseif {$::env(TRANSPORT_CASE) eq "pending"} {
                        set port [lindex [split [string trimright $::url /] :] end]
                        set ::pending [socket 127.0.0.1 $port]
                        puts -nonewline $::pending "GET / HTTP/1.1\r\n"
                        flush $::pending
                        connect picker
                        pending_eof $socket
                    } else {
                        set method [expr {$::env(TRANSPORT_CASE) in {oversized fragmented-oversized} ?
                            "fixture/$::env(TRANSPORT_CASE)" : "fixture/eof"}]
                        rpc $socket 12 $method
                    }
                } elseif {$id == 41} {
                    puts LATENCY_FORWARDED
                    flush stdout
                    set ::latencyOutbound 1
                    latency_next
                } elseif {$id == 8} { rpc $socket 12 fixture/eof
                } elseif {$id == 21} { connect main
                } elseif {$id == 30} {
                    puts POST_TRANSFER_OK
                    flush stdout
                    exit 7
                }
            } elseif {$type in {close disconnect error timeout}} {
                # Tcllib can emit close and disconnect for one failed attempt.
                dict unset ::connections $role
                if {$::env(TRANSPORT_CASE) eq "unavailable" && $::phase eq "reconnecting"} {
                    if {[incr ::attempts] < 3} {
                        after 20 {connect main}
                    } else {
                        puts UNAVAILABLE
                        puts INPUT_READY
                        flush stdout
                    }
                    return
                }
                if {$role eq "picker"} {
                    puts AUXILIARY_ISOLATED
                    if {$::env(TRANSPORT_CASE) in {large picker-first}} { puts INPUT_READY }
                    flush stdout
                } else {
                    puts RECONNECTING
                    flush stdout
                    if {$::phase eq "reconnecting"} { return }
                    set ::phase reconnecting
                    if {$::env(TRANSPORT_CASE) eq "picker-first"} {
                        after 20 {connect picker}
                    } else { after 20 {connect main} }
                }
            }
        }
        proc input {} {
            set key [read stdin 1]
            if {$::env(TRANSPORT_CASE) eq "latency" && $key eq "k"} {
                puts "KEY_ECHO:[incr ::latencyKeys]"
                flush stdout
                latency_next
            }
            if {$key eq "q"} {
                if {$::env(TRANSPORT_CASE) eq "unavailable"} { exit 7 }
                rpc $::main 30 fixture/ping
            }
        }
        fileevent stdin readable input
        connect main
        vwait forever
    }
    close $channel
    file attributes [file join $scratch codex] -permissions 0755
    set driver {
        log_user 0
        set timeout 7
        # Observe the real receiver's rejection before fatal cleanup reaps its peer.
        # No production size, framing or lifecycle behavior is replaced.
        set observe {
            package require websocket
            if {$env(TRANSPORT_CASE) eq "latency"} {
                # Announce callback entry before the real proxy handles the
                # message, so keys arrive during parsing in either implementation.
                set ::jsonProbes 0
                proc measure_json {command socket type message args} {
                    if {$type eq "text" && [string length $message] > 2000000} {
                        puts "JSON_BUSY:[incr ::jsonProbes]"
                        flush stdout
                    }
                    $command $socket $type $message {*}$args
                }
                foreach command {backend_event connection} {
                    rename $command measured_$command
                    interp alias {} $command {} measure_json measured_$command
                }
            }
            rename websocket::close websocket::native_close
            proc websocket::close {socket {code 1000} {reason ""}} {
                if {$code == 1009} {
                    set channel [::open [file join $::env(TRANSPORT_DIR) rejected.[pid]] w]
                    puts $channel $code
                    ::close $channel
                }
                websocket::native_close $socket $code $reason
            }
            if {[catch {exec stty -g <@stdin} terminal]} {
                set terminal [exec stty -g < /dev/tty]
            }
            set channel [open [file join $env(TRANSPORT_DIR) initial-terminal] w]
            puts $channel $terminal
            ::close $channel
            set arguments {}
            if {$env(TRANSPORT_CASE) in {guard manual}} { set arguments {resume transport-session --yolo} }
            if {$env(TRANSPORT_CASE) eq "reset"} {
                set env(XDG_CONFIG_HOME) $env(TRANSPORT_DIR)
                file mkdir [file join $env(XDG_CONFIG_HOME) codex-retry]
                set channel [open [file join $env(XDG_CONFIG_HOME) codex-retry config.json] w]
                puts $channel {{"auto_reset_limit":true}}
                close $channel
            }
            exit [main $arguments]
        }
        set launch [list expect -c "set argv0 transport-fixture\n[list source $wrapper]\n$observe"]
        if {$env(TRANSPORT_CASE) eq "eof-input-eof"} {
            set fifo [file join $env(TRANSPORT_DIR) input.fifo]
            exec mkfifo $fifo
            set launch [concat [list sh -c {input=$1; shift; exec "$@" <"$input"} sh $fifo] $launch]
        }
        spawn -noecho {*}$launch
        if {[info exists fifo]} { set input [open $fifo r+] }
        close_on_eof 0
        set owner [exp_pid]
        set slave $spawn_out(slave,name)
        set output ""
        set sent 0
        set probeTimes {}
        set probeEchoes {}
        set started [clock milliseconds]
        set failed [catch {
            expect {
                -re {(?s).+} {
                    append output $expect_out(0,string)
                    if {[string length $output] > 8192} { error "transport leaked payloads or diagnostics" }
                    if {$env(TRANSPORT_CASE) eq "latency"} {
                        foreach probe {1 2} {
                            if {![dict exists $probeTimes $probe] && [string first "JSON_BUSY:$probe" $output] >= 0} {
                                dict set probeTimes $probe [clock milliseconds]
                                send -- k
                            }
                            if {![dict exists $probeEchoes $probe] && [string first "KEY_ECHO:$probe" $output] >= 0} {
                                if {![dict exists $probeTimes $probe] || \
                                    [clock milliseconds] - [dict get $probeTimes $probe] >= 1000} {
                                    error "large JSON blocked keyboard echo for at least one second"
                                }
                                dict set probeEchoes $probe 1
                            }
                        }
                    }
                    if {!$sent && [string first INPUT_READY $output] >= 0} {
                        switch $env(TRANSPORT_CASE) {
                            eof-term { exec kill -TERM $owner }
                            eof-hup { exec kill -HUP $owner }
                            eof-input-eof { close $input; unset input }
                            default { send -- q }
                        }
                        set sent 1
                    }
                    exp_continue -continue_timer
                }
                eof {}
                timeout { error "transport left a reconnecting TUI or blocked large-message delivery" }
            }
            set elapsed [expr {[clock milliseconds] - $started}]
            set terminal [exec stty -g < $slave]
            set result [wait]
            close
            set channel [open [file join $env(TRANSPORT_DIR) initial-terminal] r]
            set before [string trim [read $channel]]
            close $channel
            set expected 7
            switch $env(TRANSPORT_CASE) {
                oversized - fragmented-oversized - guard { set expected 1 }
                eof-term { set expected 143 }
                eof-hup { set expected 129 }
                eof-input-eof { set expected 19 }
            }
            if {[lindex $result 2] != 0 || [lindex $result 3] != $expected} { error "transport exit status: $result; output: $output" }
            if {$terminal ne $before || [string first "\033\[?1006l" $output] < 0} { error "terminal was not restored" }
            if {$env(TRANSPORT_CASE) eq "guard"} {
                if {[string first "before launch --yolo permissions were confirmed" $output] < 0 ||
                    [string first REATTACHED $output] >= 0} { error "unverified launch was allowed to reconnect" }
            } elseif {![regexp {To resume this session, run:\r*\n[^\r\n]* resume transport-session} $output]} {
                error "missing confirmed-session resume advice"
            }
            if {$env(TRANSPORT_CASE) eq "latency"} {
                if {[dict size $probeTimes] != 2 || [dict size $probeEchoes] != 2} {
                    error "keyboard echo was not measured in both JSON directions"
                }
                foreach marker {LATENCY_DELIVERED LATENCY_FORWARDED POST_TRANSFER_OK} {
                    if {[string first $marker $output] < 0} { error "missing latency marker: $marker" }
                }
            } elseif {$env(TRANSPORT_CASE) eq "large"} {
                foreach marker {DELIVERED:main:17825840: DELIVERED:picker:17825840: AUXILIARY_ISOLATED POST_TRANSFER_OK} {
                    if {[string first $marker $output] < 0} { error "missing transport marker: $marker" }
                }
            } elseif {$env(TRANSPORT_CASE) ni {oversized fragmented-oversized guard}} {
                set markers {RECONNECTING REATTACHED}
                switch $env(TRANSPORT_CASE) {
                    unavailable { set markers {RECONNECTING UNAVAILABLE} }
                    eof-term - eof-hup {}
                    eof-input-eof { lappend markers EOF_DRAINED }
                    default { lappend markers POST_TRANSFER_OK }
                }
                foreach marker $markers {
                    if {[string first $marker $output] < 0} { error "missing reconnect marker: $marker" }
                }
                if {$env(TRANSPORT_CASE) eq "manual" && [regexp {resume transport-session --yolo} $output]} {
                    error "reconnection restored launch permission escalation"
                }
            } elseif {$env(TRANSPORT_CASE) ne "guard"} {
                if {$elapsed >= 3000} { error "fatal transport shutdown was not bounded" }
                if {[string first "codex-retry: shared app-server proxy rejected WebSocket protocol (1009)" $output] < 0} {
                    error "missing fixed protocol rejection"
                }
            }
            if {$env(TRANSPORT_CASE) in {large oversized fragmented-oversized} && ![llength [glob -nocomplain -directory $env(TRANSPORT_DIR) rejected.*]]} {
                error "oversized header was not rejected with 1009"
            }
            set channel [open [file join $env(TRANSPORT_DIR) requests] r]
            set requests [split [string trim [read $channel]] \n]
            close $channel
            set turns 0
            set reads 0
            foreach request $requests {
                lassign $request generation method
                if {$method eq "turn/start"} {
                    incr turns
                    if {$generation != 1 || $env(TRANSPORT_CASE) ni {retry reset}} { error "unsolicited work after reconnection" }
                } elseif {$method eq "account/rateLimits/read"} { incr reads
                } elseif {$method ni {initialize thread/resume thread/list thread/settings/update fixture/history fixture/latency
                    fixture/eof fixture/ping fixture/oversized fixture/fragmented-oversized}} {
                    error "unsolicited account or model request"
                }
            }
            if {$turns != ($env(TRANSPORT_CASE) in {retry reset}) ||
                $reads != ($env(TRANSPORT_CASE) eq "reset")} { error "pending recovery was not exercised" }
            if {$env(TRANSPORT_CASE) eq "unavailable" &&
                [llength [glob -nocomplain -directory $env(TRANSPORT_DIR) bridge.*.pid]] != 4} {
                error "unavailable fixture did not exercise three replacement backends"
            }
            foreach marker {CODEX_RETRY_TOKEN BEGIN- -END Bearer} {
                if {[string first $marker $output] >= 0} { error "transport exposed a credential or payload" }
            }
            foreach path [glob -nocomplain -directory $env(TRANSPORT_DIR) *.pid] {
                set channel [open $path r]
                set child [string trim [read $channel]]
                close $channel
                if {![catch {exec kill -0 $child}]} { error "owned transport child survived" }
            }
        } message]
        if {$failed} {
            catch {exec kill -TERM $owner}
            catch {expect -timeout 1 eof}
            catch {exec kill -KILL $owner}
            foreach path [glob -nocomplain -directory $env(TRANSPORT_DIR) *.pid] {
                set channel [open $path r]
                set child [string trim [read $channel]]
                close $channel
                catch {exec kill -KILL $child}
            }
            catch {expect -timeout 1 eof}
            catch {wait}
            puts stderr "$env(TRANSPORT_CASE): $message"
            exit $failureStatus
        }
        puts "PASS: $env(TRANSPORT_CASE) transport"
        exit 0
    }
    # Each case owns a PTY and directory; overlap four bounded shutdown waits.
    set failures {}
    for {set offset 0} {$offset < [llength $cases]} {incr offset 4} {
        foreach case [lrange $cases $offset [expr {$offset + 3}]] {
            set env(TRANSPORT_DIR) [file join $scratch case-[expr {$offset + [llength $jobs]}]]
            file mkdir $env(TRANSPORT_DIR)
            set env(TRANSPORT_CASE) $case
            lappend jobs [open [list | expect -c "[list set wrapper $wrapper]\n[list set failureStatus [dict get $caseStatuses $case]]\n$driver" 2>@1] r]
        }
        foreach job $jobs {
            set failed [catch {read $job} output]
            if {[catch {close $job} message options] || $failed} {
                lappend failures "$message: $output"
                if {!$failureStatus} {
                    set failureStatus 1
                    if {[dict exists $options -errorcode] &&
                        [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS"} {
                        set failureStatus [lindex [dict get $options -errorcode] 2]
                    }
                }
            } else { puts $output }
        }
        set jobs {}
    }
    if {[llength $failures]} { error [join $failures \n] }
} on error {message options} {
    puts stderr [dict get $options -errorinfo]
    if {!$failureStatus} { set failureStatus 1 }
} finally {
    foreach job $jobs {
        if {$job ni [chan names]} { continue }
        if {[catch {read $job} output]} {
            puts stderr $output
        } else { puts -nonewline $output }
        if {[catch {close $job} message]} { puts stderr $message }
    }
    array unset env
    array set env $environment
    file delete -force $scratch
}
if {$failureStatus} { exit $failureStatus }
