#!/usr/bin/env tclsh

# Offline, non-TTY subprocess contracts; no installed Codex process is invoked.
set root [file normalize [file join [file dirname [info script]] ..]]
set wrapper [file join $root codex-retry]
set environment [array get env]
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set jobs {}

proc identity {child} {
    if {![string is integer -strict $child] || [catch {open /proc/$child/stat r} channel]} { return {} }
    set failed [catch {read $channel} stat]
    catch {close $channel}
    if {$failed || ![regexp {^\d+ \(.*\) (.*)$} $stat -> fields] || [lindex $fields 0] eq "Z"} { return {} }
    return [list $child [lindex $fields 19]]
}
proc alive {record} {
    expr {[llength $record] == 2 && [identity [lindex $record 0]] eq $record}
}
proc collect {jobs} {
    set failures {}
    foreach job $jobs {
        lassign $job channel mode directory expected
        set failed 0
        if {$mode eq "descendant-partial-frame"} {
            # A test-only outer bound catches a helper stuck in Tcllib's reader.
            # The writer's own four-second failsafe must not satisfy this bound.
            set ::receipt ""; set ::finished 0
            fconfigure $channel -blocking 0
            fileevent $channel readable [list apply {{channel} {
                append ::receipt [read $channel]
                if {[eof $channel]} { fileevent $channel readable ""; set ::finished 1 }
            }} $channel]
            set timer [after 3000 {set ::finished -1}]
            if {!$::finished} { vwait ::finished }
            after cancel $timer
            fileevent $channel readable ""
            set output $::receipt
            if {$::finished != 1} {
                set failed 1
                lappend failures "$mode: helper exceeded its completion bound"
                foreach path [glob -nocomplain -directory $directory *.pids] {
                    set input [open $path r]
                    foreach record [split [string trim [read $input]] \n] {
                        if {[alive $record]} { catch {exec kill -KILL [lindex $record 0]} }
                    }
                    close $input
                }
            }
            fconfigure $channel -blocking 1
        } else {
            set failed [catch {read $channel} output]
        }
        set status 0
        if {[catch {close $channel} message options]} {
            set status -1
            if {[lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS"} {
                set status [lindex [dict get $options -errorcode] 2]
            }
        }
        if {$failed || $status != $expected || \
            (($expected == 0) != ($output eq "MCP configuration reread; refresh queued for loaded threads (server-wide).\n"))} {
            lappend failures "$mode: unexpected status/receipt ($status): $output"
        }
        if {$expected != 2 && ![file exists [file join $directory effects]]} {
            lappend failures "$mode: proxy coverage was not exercised"
        }
        if {$expected != 2 && $mode ni {upgrade-eof upgrade-deadline} && \
            ![file exists [file join $directory owned.pids]]} {
            lappend failures "$mode: initialization and owned-child coverage were not exercised"
        }
        if {$mode in {ok unrelated rpc-reload bad-reload nonempty-reload string-reload-id disconnect-reload deadline-reload descendant-partial-frame} && \
            ![file exists [file join $directory reload.sent]]} {
            lappend failures "$mode: reload coverage was not exercised"
        }
        if {$expected == 2 && [file exists [file join $directory effects]]} {
            lappend failures "$mode: invalid arguments started a process"
        }
        if {$expected != 0 && [string first "refresh queued" $output] >= 0} {
            lappend failures "$mode: failure claimed a queued refresh"
        }
        if {$mode eq "descendant-partial-frame"} {
            foreach name {launcher.pids writer.pids watchdog.pids partial.sent} {
                if {![file exists [file join $directory $name]]} { lappend failures "$mode: missing $name coverage" }
            }
            set roles {}
            foreach role {helper launcher writer watchdog} {
                set path [file join $directory $role.pids]
                if {![file exists $path]} { continue }
                set input [open $path r]
                set records [split [string trim [read $input]] \n]
                close $input
                if {[llength $records] != 1 || [llength [lindex $records 0]] != 2} {
                    lappend failures "$mode: $role identity was not recorded"
                } else { lappend roles [lindex $records 0 0] }
            }
            if {[llength [lsort -unique $roles]] != 4} { lappend failures "$mode: process roles were not distinct" }
        }
        foreach path [glob -nocomplain -directory $directory *.pids] {
            set input [open $path r]
            set children [split [string trim [read $input]] \n]
            close $input
            foreach record $children {
                if {[alive $record]} {
                    catch {exec kill -KILL [lindex $record 0]}
                    lappend failures "$mode: owned child survived cleanup"
                }
            }
        }
    }
    if {[llength $failures]} { error [join $failures \n] }
}

try {
    foreach name {HOME CODEX_HOME XDG_CONFIG_HOME TMPDIR} { set env($name) $scratch }
    set env(PATH) "$scratch:$env(PATH)"
    set env(CODEX_RETRY_TOKEN) inherited-secret
    unset -nocomplain env(RELOAD_WRITER)
    file mkdir [file join $scratch codex-retry]
    set channel [open [file join $scratch codex-retry config.json] w]
    puts $channel {invalid retry configuration must not be read}
    close $channel
    set channel [open [file join $scratch codex] w]
    puts $channel {#!/usr/bin/env expect}
    puts $channel [list set wrapper $wrapper]
    puts $channel [list source [file join $root tests proxy-fixture.tcl]]
    puts $channel [list proc identity [info args identity] [info body identity]]
    puts $channel {
        foreach level [logger::levels] { ${::websocket::log}::logproc $level message {return} }
        set log [open [file join $env(RELOAD_DIR) effects] w]
        puts $log $argv
        close $log
        if {$argv ne {app-server proxy} || [info exists env(CODEX_RETRY_TOKEN)]} { exit 91 }
        set mode $env(RELOAD_CASE)
        if {$mode eq "descendant-partial-frame" && ![info exists env(RELOAD_WRITER)]} {
            # Keep the real pipe on a writer child after its launcher is killed,
            # as with native launchers which spawn rather than replace themselves.
            set env(RELOAD_WRITER) 1
            set writer [exec expect $argv0 {*}$argv <@stdin >@stdout 2>@stderr &]
            vwait forever
        }
        after 4000 {exit 93}
        if {$mode eq "upgrade-eof"} { exit 0 }
        if {$mode eq "upgrade-deadline"} { vwait forever }
        set phase initialize
        proc reply {socket id result} {
            websocket::send $socket text [format {{"id":%s,"result":%s}} $id $result]
        }
        proc request {socket type data} {
            if {$type ne "text"} { return }
            set init {{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-retry-mcp","version":"1"},"capabilities":{}}}}
            set initialized {{"method":"initialized"}}
            set reload {{"id":2,"method":"config/mcpServer/reload","params":null}}
            switch -- $::phase {
                initialize {
                    if {$data ne $init} { exit 81 }
                    set ::phase initialized
                    # Record every direct helper child, including its watchdog,
                    # and our relay while their ownership can still be observed.
                    set input [open /proc/[pid]/status r]
                    regexp -line {^PPid:\s+(\d+)} [read $input] -> owner
                    close $input
                    if {$::mode eq "descendant-partial-frame"} {
                        set launcher $owner
                        set input [open /proc/$launcher/status r]
                        regexp -line {^PPid:\s+(\d+)} [read $input] -> owner
                        close $input
                        foreach {role child} [list launcher $launcher writer [pid]] {
                            set log [open [file join $::env(RELOAD_DIR) $role.pids] w]
                            puts $log [identity $child]
                            close $log
                        }
                    }
                    set input [open /proc/$owner/task/$owner/children r]
                    set children [read $input]
                    close $input
                    set log [open [file join $::env(RELOAD_DIR) owned.pids] w]
                    foreach child [concat $children [list [pid]] [pid $::fixture::relay]] { puts $log [identity $child] }
                    close $log
                    if {$::mode eq "descendant-partial-frame"} {
                        set log [open [file join $::env(RELOAD_DIR) watchdog.pids] w]
                        foreach child $children {
                            if {$child != $launcher} { puts $log [identity $child] }
                        }
                        close $log
                    }
                    switch -- $::mode {
                        rpc-init { websocket::send $socket text {{"id":1,"error":{"code":-32601,"message":"unsupported"}}}; return }
                        malformed { websocket::send $socket text {not JSON}; return }
                        duplicate { websocket::send $socket text {{"id":1,"id":1,"result":{}}}; return }
                        escaped-duplicate { websocket::send $socket text {{"id":1,"\u0069d":1,"result":{}}}; return }
                        nested-duplicate { websocket::send $socket text {{"id":99,"result":{"x":1,"x":2}}}; return }
                        contradictory { websocket::send $socket text {{"id":1,"result":{},"error":{"code":1,"message":"x"}}}; return }
                        malformed-unrelated { websocket::send $socket text {{"method":false,"params":{}}}; return }
                        invalid-id { websocket::send $socket text {{"id":true,"result":{}}}; return }
                        fractional-id { websocket::send $socket text {{"id":1.0,"result":{}}}; return }
                        bad-error { websocket::send $socket text {{"id":99,"error":{"code":"-1","message":"x"}}}; return }
                        bad-init { reply $socket 1 {[]}; return }
                        empty-init { reply $socket 1 {{}}; return }
                        bad-version { websocket::send $socket text {{"id":1,"result":{},"jsonrpc":2}}; return }
                        missing-id { websocket::send $socket text {{"result":{}}}; return }
                        reply-params { websocket::send $socket text {{"id":1,"result":{},"params":null}}; return }
                        string-init-id { reply $socket {"1"} {{"userAgent":"wrong type"}}; return }
                        future-id { reply $socket 2 {{}}; return }
                        disconnect-init { fixture::stop; exit 0 }
                        deadline-init { return }
                        partial-frame { puts -nonewline $socket [binary format H* 817e0010]; flush $socket; return }
                        binary { websocket::send $socket binary x; return }
                        signal { exec kill -TERM $owner; return }
                        unrelated {
                            websocket::send $socket ping neutral
                            websocket::send $socket pong neutral
                            foreach message {
                                {{"id":"1","result":{"userAgent":"wrong-type"}}}
                                {{"id":99,"result":[]}}
                                {{"id":99,"error":{"code":-32601,"message":"unrelated"}}}
                                {{"method":"fixture/notice","params":{}}}
                                {{"id":"server-request","method":"fixture/request","params":[]}}
                            } { websocket::send $socket text $message }
                        }
                    }
                    reply $socket 1 {{"userAgent":"offline fixture"}}
                }
                initialized {
                    if {$data ne $initialized} { exit 82 }
                    set ::phase reload
                }
                reload {
                    if {$data ne $reload} { exit 83 }
                    close [open [file join $::env(RELOAD_DIR) reload.sent] w]
                    set ::phase finished
                    switch -- $::mode {
                        rpc-reload { websocket::send $socket text {{"id":2,"error":{"code":-32601,"message":"unsupported"}}}; return }
                        bad-reload { reply $socket 2 null; return }
                        nonempty-reload { reply $socket 2 {{"ready":true}}; return }
                        string-reload-id { reply $socket {"2"} {{}}; return }
                        disconnect-reload { fixture::stop; exit 0 }
                        deadline-reload { return }
                        descendant-partial-frame {
                            puts -nonewline $socket [binary format H* 817e0010]
                            flush $socket
                            close [open [file join $::env(RELOAD_DIR) partial.sent] w]
                            return
                        }
                        unrelated {
                            reply $socket {"2"} {{}}
                            reply $socket 1 {{"userAgent":"stale"}}
                        }
                    }
                    reply $socket 2 {{}}
                }
                default { exit 84 }
            }
        }
        fixture::start request
        vwait forever
    }
    close $channel
    file attributes [file join $scratch codex] -permissions 0755
    foreach mode {ok unrelated rpc-init rpc-reload bad-reload nonempty-reload malformed duplicate escaped-duplicate nested-duplicate
        contradictory malformed-unrelated invalid-id fractional-id bad-error bad-init empty-init future-id
        bad-version missing-id reply-params string-init-id string-reload-id
        disconnect-init disconnect-reload deadline-init deadline-reload partial-frame descendant-partial-frame upgrade-eof
        upgrade-deadline binary signal extra option terminator} {
        set directory [file join $scratch $mode]
        file mkdir $directory
        set env(RELOAD_DIR) $directory
        set env(RELOAD_CASE) $mode
        set expected [expr {$mode in {ok unrelated} ? 0 : 1}]
        set arguments reload-mcp
        switch -- $mode {
            extra { lappend arguments extra; set expected 2 }
            option { lappend arguments --help; set expected 2 }
            terminator { lappend arguments --; set expected 2 }
        }
        set command [list $wrapper {*}$arguments]
        if {$mode in {deadline-init deadline-reload partial-frame descendant-partial-frame upgrade-deadline string-init-id string-reload-id}} {
            # Controlled internal timer, without adding a public configuration knob.
            set driver "set argv0 reload-deadline\n[list source $wrapper]\nset ::mcp_reload::timeout 500\nexit \[main {reload-mcp}\]"
            set command [list expect -c $driver]
        }
        set process [open [list | {*}$command < /dev/null 2>@1] r]
        if {$mode eq "descendant-partial-frame"} {
            set log [open [file join $directory helper.pids] w]
            foreach child [pid $process] { puts $log [identity $child] }
            close $log
        }
        lappend jobs [list $process $mode $directory $expected]
        if {$mode eq "descendant-partial-frame"} {
            # Start its completion bound immediately, before waiting on siblings.
            set job [lindex $jobs end]
            set jobs [lrange $jobs 0 end-1]
            collect [list $job]
        }
        if {[llength $jobs] == 8} { set batch $jobs; set jobs {}; collect $batch }
    }
    set batch $jobs; set jobs {}; collect $batch
} finally {
    foreach job $jobs { catch {close [lindex $job 0]} }
    array unset env
    array set env $environment
    file delete -force $scratch
}
puts "PASS: headless MCP reload frames, typed replies, rejection, deadlines, arguments, receipt and owned cleanup"
