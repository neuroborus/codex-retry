# Model `app-server proxy`: raw stdio bytes tunnel to a WebSocket control socket.
# A separate relay keeps producing bytes while Tcllib reads a blocking frame.
namespace eval fixture {
    variable script [file normalize [info script]]
    variable headers; variable bytes
    variable listener ""
    variable peer ""
    variable relay ""
    variable relayDone 0
    variable stopping 0
}

proc fixture::copy {from to} {
    if {[catch {
        set data [read $from 16384]
        puts -nonewline $to $data
        flush $to
        if {[eof $from]} {
            fileevent stdin readable ""
            fileevent $::tunnel readable ""
            fixture::finish_relay
        }
    }]} { exit 1 }
}

proc fixture::finish_relay {} {
    foreach channel [list stderr $::tunnel] {
        fileevent $channel writable ""
        if {[chan pending output $channel]} {
            fileevent $channel writable fixture::finish_relay
            return
        }
    }
    exit 0
}

# stdout is a lifecycle pipe owned by the fixture. stderr is redirected to
# its original stdout, so only raw tunnel bytes go to the wrapper.
if {[info exists argv] && [lindex $argv 0] eq "--relay" &&
    [file normalize [info script]] eq [file normalize $argv0]} {
    after 30000 {exit 1}
    set tunnel [socket 127.0.0.1 [lindex $argv 1]]
    foreach channel [list stdin stderr $tunnel] {
        fconfigure $channel -blocking 0 -buffering none -encoding binary -translation binary
    }
    fileevent stdin readable [list fixture::copy stdin $tunnel]
    fileevent $tunnel readable [list fixture::copy $tunnel stderr]
    vwait forever
}

package require websocket
foreach level [logger::levels] {
    ${::websocket::log}::logproc $level message \
        [list puts stderr "proxy fixture: WebSocket $level diagnostic"]
}

proc fixture::upgrade {handler socket} {
    variable headers; variable bytes
    if {[catch {
        while {[gets $socket line] >= 0} {
            incr bytes($socket) [expr {[string length $line] + 2}]
            if {$bytes($socket) > 16384} { error "oversized fixture handshake" }
            if {$line eq ""} {
                if {[lindex $headers($socket) 0] ne "GET / HTTP/1.1"} { error "invalid fixture request" }
                set fields {}
                foreach line [lrange $headers($socket) 1 end] {
                    if {![regexp {^([^:[:space:]]+):[ \t]*(.*)$} $line -> key value]} { error "invalid fixture header" }
                    dict set fields [string tolower $key] [string trim $value]
                }
                set validated [websocket::validate $fields]
                set accept [websocket::sec-websocket-accept [dict get $validated key]]
                puts $socket "HTTP/1.1 101 Switching Protocols\nUpgrade: websocket\nConnection: Upgrade\nSec-WebSocket-Accept: $accept\n"
                flush $socket
                unset headers($socket) bytes($socket)
                fconfigure $socket -encoding binary -translation binary
                websocket::takeover $socket $handler 1
                return
            }
            lappend headers($socket) $line
        }
        if {[eof $socket] || $bytes($socket) + [chan pending input $socket] > 16384} { error "incomplete fixture handshake" }
    }] == 1} { exit 1 }
}

proc fixture::accept {handler socket args} {
    variable headers; variable bytes; variable listener; variable peer
    if {$listener ne ""} { close $listener; set listener "" }
    set peer $socket
    set headers($socket) {}
    set bytes($socket) 0
    fconfigure $socket -blocking 0 -buffering none -encoding ascii -translation crlf
    fileevent $socket readable [list fixture::upgrade $handler $socket]
}

proc fixture::start {handler} {
    variable script; variable listener; variable relay
    # Fake backends run under Expect so its exit/signal hooks are already loaded.
    package present Expect
    exit -onexit [list fixture::onexit [exit -onexit]]
    set ignoreInterrupt [expr {[trap SIGINT] eq "SIG_IGN"}]
    foreach {signal status} {SIGTERM 143 SIGHUP 129 SIGINT 130} {
        if {$signal eq "SIGINT" && $ignoreInterrupt} { continue }
        trap [list fixture::signal [trap $signal] $status] $signal
    }
    set listener [socket -server [list fixture::accept $handler] -myaddr 127.0.0.1 0]
    set port [lindex [fconfigure $listener -sockname] 2]
    # `2>@stdout` merges into the pipeline's lifecycle pipe, not our stdout.
    set output [open /dev/stdout w]
    try {
        set command [list | tclsh $script --relay $port <@stdin 2>@$output]
        if {$ignoreInterrupt} {
            set command [linsert $command 1 sh -c {trap '' INT; exec "$@"} fixture-relay]
        }
        set relay [open $command r]
    } finally { close $output }
    fconfigure $relay -blocking 0
    fileevent $relay readable fixture::relay_done
}

proc fixture::relay_done {} {
    variable relay; variable relayDone; variable stopping
    if {[read $relay 1] ne ""} { exit 1 }
    if {[eof $relay]} {
        fileevent $relay readable ""
        set relayDone 1
        if {!$stopping} {
            fconfigure $relay -blocking 1
            set failed [catch {close $relay}]
            set relay ""
            exit $failed
        }
    }
}

proc fixture::stop {} {
    variable listener; variable peer; variable relay; variable relayDone; variable stopping
    if {$stopping} { return }
    set stopping 1
    catch {close $listener}
    catch {websocket::configure $peer -keepalive 0}
    # Closing after the handler's final send lets the relay flush before exit.
    catch {close $peer}
    if {$relay eq ""} { return }
    set deadline [after 200 {set ::fixture::relayDone -1}]
    if {!$relayDone} { vwait ::fixture::relayDone }
    after cancel $deadline
    if {$relayDone != 1} { catch {exec kill -KILL {*}[pid $relay]} }
    fconfigure $relay -blocking 1
    catch {close $relay}
    set relay ""
}

proc fixture::onexit {previous} {
    stop
    if {$previous ne ""} { uplevel #0 $previous }
}

proc fixture::signal {previous status} {
    stop
    if {$previous eq "SIG_DFL"} { exit $status }
    if {$previous ne "SIG_IGN"} { uplevel #0 $previous }
}
