#!/usr/bin/env tclsh

source [file join [file dirname [info script]] .. codex-retry]

proc check {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}

# Controlled timers and an offline app-server transport.
rename after real_after
set timers {}
set delays {}
set sent {}
set nextTimer 0
proc after {delay args} {
    if {$delay eq "cancel"} { dict unset ::timers [lindex $args 0]; return }
    set id timer[incr ::nextTimer]
    dict set ::timers $id [lindex $args 0]
    lappend ::delays $delay
    return $id
}
rename backend_send native_backend_send
proc backend_send {json} { lappend ::sent $json }
proc fire {} {
    check {[dict size $::timers] == 1} "expected one pending retry"
    set id [lindex [dict keys $::timers] 0]
    set action [dict get $::timers $id]
    dict unset ::timers $id
    uplevel #0 $action
}
proc started {turn {thread t1} {items {[]}}} {
    retry::server [format {{"method":"turn/started","params":{"threadId":"%s","turn":{"id":"%s","status":"inProgress","items":%s}}}} $thread $turn $items]
}
proc reply {id turn {items {[]}}} {
    retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","status":"inProgress","items":%s}}}} $id $turn $items]
}
proc completed {turn {status failed} {code serverOverloaded} {items {[]}} {thread t1}} {
    retry::server [format {{"method":"turn/completed","params":{"threadId":"%s","turn":{"id":"%s","status":"%s","items":%s,"error":{"message":"synthetic failure","codexErrorInfo":"%s"}}}}} $thread $turn $status $items $code]
}
proc elicitation {turn {thread t1}} {
    retry::server [format {{"id":"elicitation","method":"mcpServer/elicitation/request","params":{"threadId":"%s","turnId":%s,"serverName":"fixture","mode":"form","_meta":null,"message":"sample input","requestedSchema":{"type":"object","properties":{}}}}} $thread $turn]
}
set request {{"id":7,"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"original\nrequest \"quoted\" é\u0001"},{"type":"localImage","path":"sample.png"}],"effort":"high","sandboxPolicy":{"type":"readOnly"},"special":{"odd\"key":"escaped"},"optional":null,"flag":true,"count":3,"emptyObject":{},"emptyArray":[]}}}
proc begin {{acknowledge 1}} {
    retry::reset
    set ::retry::finished {}
    retry::client $::request
    if {$acknowledge} { reply 7 turn1; started turn1 }
}

# Large startup catalogs must not stall keyboard forwarding in the event loop.
set catalogItem {{"name":"fixture","id":"fixture","nested":{"description":"sample \"text\" {} []","method":"fixture/request","enabled":true,"values":[1,2,3]}}}
set catalog "{\"id\":99,\"result\":{\"items\":\[[join [lrepeat 30000 $catalogItem] ,]\]}}"
foreach active {0 1} {
    retry::reset
    if {$active} { begin 0 }
    set previous $retry::current
    set before [clock milliseconds]
    check {[retry::server $catalog] == 1} "an unrelated startup catalog was hidden"
    check {[clock milliseconds] - $before < 1000} "startup catalog processing stalled terminal input"
    if {$active} {
        check {$retry::current eq $previous && [dict size $timers] == 0} "an unrelated response changed the tracked request"
    }
}
unset catalog catalogItem

begin
check {[retry::server {{"id":99,"result":{}}}] == 1} "empty JSON objects broke protocol forwarding"
retry::server {{"method":"error","params":{"threadId":"t1","turnId":"turn1","willRetry":true,"error":{"codexErrorInfo":"serverOverloaded"}}}}
check {[dict size $timers] == 0} "a transient error retried an active turn"
completed turn1 failed serverOverloaded {[]} other-thread
completed unrelated-turn
check {[dict size $timers] == 0} "unrelated completion scheduled a retry"
completed turn1
completed turn1
check {[dict size $timers] == 1} "duplicate completion scheduled multiple retries"
set original [::huddle::json2huddle $request]
set expected {5000 10000 20000 40000 80000 160000 320000 640000 1280000 1800000 1800000}
set turn turn1
foreach delay $expected {
    check {[lindex $delays end] == $delay} "incorrect exponential backoff"
    fire
    set retried [::huddle::json2huddle [lindex $sent end]]
    check {[huddle equal [huddle get $original params] [huddle get $retried params]]} "retry changed input, settings, or JSON types"
    set id [huddle jsondump [huddle get $retried id] "" ""]
    started $turn
    completed $turn
    check {[dict size $timers] == 0} "stale events scheduled a retry"
    append turn x
    started $turn
    completed $turn
    check {[dict size $timers] == 0} "retry preceded the start acknowledgement"
    check {[reply $id $turn] == 0} "internal response leaked to the TUI"
    check {[dict size $timers] == 1} "notification-before-response lost retry"
}
fire
set retried [::huddle::json2huddle [lindex $sent end]]
set id [huddle jsondump [huddle get $retried id] "" ""]
reply $id success
started success
completed success completed
check {$retry::delay == 5000 && [dict size $timers] == 0} "success did not reset backoff"

# A completion is authoritative without relying on turn/started delivery order.
foreach order {{reply completed} {completed reply} {completed started reply}} {
    begin 0
    foreach event $order {
        switch $event {
            reply { reply 7 turn1 }
            completed { completed turn1 }
            started { started turn1 }
        }
    }
    check {[dict size $timers] == 1} "completion/acknowledgement ordering lost a retry"
}
begin 0
completed turn1
check {[dict size $timers] == 0} "an unacknowledged turn was replayed"
reply {"7"} turn1
check {[dict size $timers] == 0} "string and numeric request IDs were conflated"
reply 7 turn1
check {[dict size $timers] == 1} "the matching numeric acknowledgement was lost"

foreach acknowledgement {
    {"result":{"turn":{"id":"turn1","items":[]}},"id":7}
    {"jsonrpc":"2.0","id":7,"result":{"turn":{"id":"turn1","items":[]}}}
    {"id":7,"result":{"turn":{"id":"turn1","items":[]}},"jsonrpc":"2.0"}
} {
    begin 0
    completed turn1
    retry::server "\{$acknowledgement\}"
    check {[dict size $timers] == 1} "alternate response field order lost the acknowledgement"
}
retry::reset
retry::client {{"id":"request,\"quoted","method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"sample"}]}}}
completed quoted-turn
retry::server {{"id":"request,\u0022quoted","result":{"turn":{"id":"quoted-turn","items":[]}}}}
check {[dict size $timers] == 1} "a quoted request ID lost the acknowledgement"
fire
set cancelledId [json_dump [huddle get [dict get $retry::current request] id]]
retry::reset
set escapedId [string map [list c {\u0063}] $cancelledId]
check {[retry::server [format {{"id":%s,"result":{}}} $escapedId]] == 0} "an escaped cancelled internal response leaked to the TUI"

retry::reset
set longId [json::write string [string repeat x 300]]
retry::client [format {{"id":%s,"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"sample"}]}}} $longId]
completed long-id-turn
reply $longId long-id-turn
check {[dict size $timers] == 1} "a request ID beyond the bounded header lost its acknowledgement"

# A later ID must be interpreted by the full parser, even if the header matches.
begin 0
completed turn1
retry::server {{"id":7,"result":{"turn":{"id":"turn1","items":[]}},"id":99}}
check {![field $retry::current accepted] && [dict size $timers] == 0} "an ambiguous header acknowledged the wrong request"
reply 7 turn1
check {[dict size $timers] == 1} "an ambiguous header consumed the matching acknowledgement"

# Server requests can share an internal ID; only an actual reply consumes it.
foreach methodKey {{"method"} {"\u006dethod"}} {
    begin
    completed turn1
    fire
    set id [json_dump [huddle get [dict get $retry::current request] id]]
    set event [format {{"id":%s,"result":{},%s:"hook/started","params":{"threadId":"t1","turnId":null}}} $id $methodKey]
    check {[retry::server $event] == 1} "a later method field hid a server request"
    check {[reply $id turn2] == 0} "a server request consumed the internal reply marker"
    completed turn2
    check {[dict size $timers] == 0} "a later method field hid hook progress"
}

# Cancellation preserves internal reply visibility across fallback layouts.
foreach layout {
    {"result":{},"id":%s}
    {"id":%s,"result":{},"jsonrpc":"2.0"}
    {"id":99,"result":{},"id":%s}
} {
    begin
    completed turn1
    fire
    set id [json_dump [huddle get [dict get $retry::current request] id]]
    retry::reset
    check {[retry::server [format "\{$layout\}" $id]] == 0} "a cancelled internal reply leaked through a fallback layout"
}
begin
completed turn1
fire
set id [json_dump [huddle get [dict get $retry::current request] id]]
retry::reset
check {[retry::server [format {{"id":%s,"result":{},"id":99}} $id]] == 1} "a duplicate header ID hid an unrelated reply"
check {[reply $id turn2] == 0} "a duplicate header ID consumed the internal reply marker"
check {[catch {retry::server {{"id":,"result":{}}}}]} "a malformed response header bypassed JSON parsing"

begin
retry::server {{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"turn1","status":"completed","items":[],"error":null}}}}
check {$retry::current eq "" && [dict size $timers] == 0} "a successful turn with a null error did not reset"

foreach status {completed interrupted} {
    begin
    completed turn1 $status
    check {[dict size $timers] == 0} "a terminal non-failure was retried"
}
foreach code {unauthorized rateLimitExceeded usageLimitExceeded other} {
    begin
    completed turn1 failed $code
    check {[dict size $timers] == 0} "an unrelated failure was retried"
}
foreach mutation {
    {"method":"turn/interrupt","params":{"threadId":"t1","turnId":"turn1"}}
    {"method":"turn/steer","params":{"threadId":"t1","expectedTurnId":"turn1","input":[{"type":"text","text":"manual"}]}}
    {"method":"thread/resume","params":{"threadId":"t2"}}
    {"method":"thread/read","params":{"threadId":"t2"}}
    {"method":"review/start","params":{"threadId":"t1"}}
    {"method":"thread/queue/start","params":{"threadId":"t1"}}
} {
    begin
    completed turn1
    retry::client "\{$mutation\}"
    check {[dict size $timers] == 0 && $retry::delay == 5000} "manual action left a stale retry"
}
begin
completed turn1
retry::client $request
check {[dict size $timers] == 0} "new input did not cancel the retry"
begin
completed turn1
started replacement-turn
check {[dict size $timers] == 0} "a replacement turn did not cancel the retry"
foreach status {completed failed interrupted} {
    begin
    completed turn1
    completed replacement-turn $status
    check {$retry::current eq "" && [dict size $timers] == 0} "an early replacement completion left a retry armed"
    started replacement-turn
    check {[dict size $timers] == 0} "a late replacement start restored a cancelled retry"
}
begin
completed historical-turn
completed turn1
completed historical-turn
started historical-turn
completed replacement-turn completed serverOverloaded {[]} other-thread
started replacement-turn other-thread
check {[dict size $timers] == 1} "stale or foreign-thread replacement events cancelled the current retry"
retry::reset
retry::client $request
started notification-turn
completed notification-turn
reply 7 acknowledged-turn
check {$retry::current eq "" && [dict size $timers] == 0} "mismatched acknowledgement adopted another turn's failure"

begin
completed turn1
fire
set id [huddle jsondump [huddle get [::huddle::json2huddle [lindex $sent end]] id] "" ""]
reply $id turn2
started turn2
completed turn2
fire
set id [huddle jsondump [huddle get [::huddle::json2huddle [lindex $sent end]] id] "" ""]
started turn1
completed turn1
reply $id turn3
completed turn3
check {[dict size $timers] == 1} "an older completed turn displaced a later retry"

begin
retry::client $request
reply 7 turn2
started turn2
completed turn2
check {[dict size $timers] == 0} "replacement input during an active turn was replayed"

begin
retry::server {{"method":"item/started","params":{"threadId":"t1","turnId":"turn1","item":{"type":"commandExecution","id":"item1"}}}}
completed turn1
check {[dict size $timers] == 0} "a turn with tool progress was replayed"
begin
completed turn1 failed serverOverloaded {[{"type":"agentMessage","id":"item1","text":"partial"}]}
check {[dict size $timers] == 0} "partial model output was replayed"
begin
retry::server {{"method":"hook/started","params":{"threadId":"t1","turnId":"turn1","run":{}}}}
completed turn1
check {[dict size $timers] == 0} "a turn with hook progress was replayed"

foreach event {
    {"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"turn1","delta":"partial"}}
    {"method":"item/reasoning/textDelta","params":{"threadId":"t1","turnId":"turn1","delta":"partial"}}
    {"method":"hook/started","params":{"threadId":"t1","turnId":"turn1","run":{}}}
    {"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"t1","turnId":"turn1"}}
    {"method":"rawResponseItem/completed","params":{"threadId":"t1","turnId":"turn1","item":{}}}
} {
    foreach timing {before-start before-ack after-completion} {
        begin 0
        if {$timing eq "before-ack"} { completed turn1 }
        if {$timing eq "after-completion"} { reply 7 turn1; completed turn1 }
        retry::server "\{$event\}"
        if {$timing eq "before-start"} { reply 7 turn1; started turn1; completed turn1 }
        if {$timing eq "before-ack"} { reply 7 turn1 }
        check {[dict size $timers] == 0} "early or late model/tool/hook progress allowed replay"
    }
}
# Standalone MCP requests remain visible and block only the relevant thread/turn.
foreach {turn thread eligible} {{"turn1"} t1 0 null t1 0 {"other-turn"} t1 1 {"turn1"} t2 1 null t2 1} {
    foreach timing {before-start before-ack after-completion} {
        begin 0
        if {$timing eq "before-ack"} { completed turn1 }
        if {$timing eq "after-completion"} { reply 7 turn1; completed turn1 }
        check {[elicitation $turn $thread] == 1} "MCP elicitation was hidden from the TUI"
        if {$timing eq "before-start"} { reply 7 turn1; started turn1; completed turn1 }
        if {$timing eq "before-ack"} { reply 7 turn1 }
        check {[dict size $timers] == $eligible} "MCP elicitation did not respect replay progress or thread/turn scope"
    }
}
foreach snapshot {reply started} {
    begin 0
    if {$snapshot eq "reply"} {
        reply 7 turn1 {[{"type":"agentMessage","text":"partial"}]}
    } else {
        started turn1 t1 {[{"type":"commandExecution","id":"tool1"}]}
        reply 7 turn1
    }
    completed turn1
    check {[dict size $timers] == 0} "progress in a start snapshot was replayed"
}
begin 0
retry::server {{"method":"hook/completed","params":{"threadId":"t1","turnId":"old-turn","run":{}}}}
reply 7 turn1
started turn1
retry::server {{"method":"item/started","params":{"threadId":"t1","turnId":"turn1","item":{"type":"userMessage"}}}}
completed turn1 failed serverOverloaded {[{"type":"userMessage"}]}
check {[dict size $timers] == 1} "another turn's hook or a user item blocked retry"
retry::server {{"method":"hook/started","params":{"threadId":"t1","turnId":null,"run":{}}}}
check {[dict size $timers] == 0} "an unscoped hook left ambiguous replay enabled"
foreach acknowledge {0 1} {
    begin $acknowledge
    completed turn1
    completed turn1 failed serverOverloaded {[{"type":"agentMessage","text":"late snapshot"}]}
    if {!$acknowledge} { reply 7 turn1 }
    check {[dict size $timers] == 0} "a duplicate completion hid observable progress"
}

begin
completed turn1
retry::server {{"method":"thread/closed","params":{"threadId":"t1"}}}
check {[dict size $timers] == 0} "thread closure left a pending retry"

begin
set occupied "$retry::prefix-[expr {$retry::sequence + 1}]"
retry::client [format {{"id":"%s","method":"thread/read","params":{"threadId":"t1"}}} $occupied]
completed turn1
fire
set retried [::huddle::json2huddle [lindex $sent end]]
set id [huddle jsondump [huddle get $retried id] "" ""]
check {$id ne "\"$occupied\""} "retry reused a TUI request ID"
check {[retry::server [format {{"id":%s,"method":"fixture/request","params":{}}} $id]] == 1} "a server request was hidden as a retry response"
check {[reply $id turn2] == 0} "a server request consumed the internal response marker"
check {[retry::server [format {{"id":"%s","result":{}}} $occupied]] == 1} "a TUI response was hidden"

begin
completed turn1
connection fixture disconnect ""
check {$retry::current eq "" && [dict size $timers] == 0} "disconnection left a pending retry"

begin
completed turn1
fire
set retried [::huddle::json2huddle [lindex $sent end]]
set id [huddle jsondump [huddle get $retried id] "" ""]
retry::server [format {{"id":%s,"error":{"code":-32000,"message":"rejected"}}} $id]
check {$retry::current eq "" && [dict size $timers] == 0} "an ambiguous RPC failure was retried"

set options [list -c {model="fixture with spaces"} --enable feature --disable=other {-ceffort="high"}]
check {[backend_options [concat {resume --last} $options {-- --remote=prompt -c prompt}]] eq $options} "config extraction crossed the argument boundary or changed values"
foreach arguments {{--remote ws://invalid} {--remote-auth-token-env=OTHER} {-c} {--enable} {-c |} {--enable >file}} {
    check {[catch {backend_options $arguments}]} "invalid wrapper options were accepted"
}

package require websocket

# A send can remove both channels before buffered backend reads finish.
rename websocket::send websocket::native_send
proc websocket::send {socket type message} {
    lappend ::forwarded $message
    if {$::sendMode ne "failed"} { connection $socket $::sendMode "" }
    return [expr {$::sendMode eq "close" ? 1 : -1}]
}
foreach sendMode {failed close disconnect} {
    begin
    completed turn1
    set backend [file tempfile scratch]
    puts $backend {{"id":91,"result":{}}}
    puts $backend {{"id":92,"result":{}}}
    seek $backend 0
    set client fixture
    set forwarded {}
    set failed [catch {backend_read} message]
    set stopped [expr {![info exists backend] && ![info exists client]}]
    cleanup
    file delete $scratch
    check {!$failed} "forwarding after disconnect accessed a removed channel: $message"
    check {$stopped && [llength $forwarded] == 1 && [dict size $timers] == 0} "failed forwarding left a connection or retry active"
}
rename websocket::send {}
rename websocket::native_send websocket::send

# File-backed requests exercise handshake parsing without opening a listener.
rename websocket::takeover websocket::native_takeover
proc websocket::takeover {socket handler server} { set ::upgraded 1 }
proc handshake_fixture {headers} {
    set channel [file tempfile scratch]
    set ::upgraded 0
    set failed [catch {
        fconfigure $channel -encoding ascii -translation crlf
        puts $channel "GET / HTTP/1.1\n[join $headers \n]\n"
        flush $channel
        seek $channel 0
        set ::handshakes($channel) [dict create lines {} size 0 timer ""]
        handshake $channel
    } message]
    drop_handshake $channel
    file delete $scratch
    if {$failed} { error $message }
    return $::upgraded
}
set hadToken [info exists env(CODEX_RETRY_TOKEN)]
if {$hadToken} { set savedToken $env(CODEX_RETRY_TOKEN) }
set env(CODEX_RETRY_TOKEN) fixture-token
set headers [list {Host: localhost} {Connection: keep-alive} {cOnNeCtIoN: Upgrade} \
    {Upgrade: websocket} {Sec-WebSocket-Version: 13} \
    {Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==} {Authorization: Bearer fixture-token}]

# A write-only channel deterministically fails a pre-authentication read.
begin
completed turn1
set sentBefore [llength $sent]
set channel [file tempfile scratch]
close $channel
set channel [open $scratch w]
set ::handshakes($channel) [dict create lines {} size 0 \
    timer [after 10000 [list drop_handshake $channel]]]
set failed [catch {handshake $channel} message]
set closed [catch {fconfigure $channel}]
set pending [info exists ::handshakes($channel)]
drop_handshake $channel
file delete $scratch
check {!$failed} "pre-authentication read failure escaped socket cleanup: $message"
check {$closed && !$pending} "failed pre-authentication channel remained open"
check {[handshake_fixture $headers]} "a failed read prevented a subsequent valid handshake"
fire
check {[llength $sent] == $sentBefore + 1} "a failed handshake stopped an unrelated pending retry"
retry::reset
foreach extra {
    {authorization: Bearer fixture-token}
    {Authorization: Bearer invalid}
    {Origin: https://example.invalid}
    {Origin:}
    {Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==}
    {Sec-WebSocket-Version: 13}
} {
    check {![handshake_fixture [concat $headers [list $extra]]]} "ambiguous or browser handshake was accepted"
}
check {![handshake_fixture [lreplace $headers end end {Authorization: Bearer invalid}]]} "invalid credential was accepted"
check {![handshake_fixture [lrange $headers 0 end-1]]} "missing credential was accepted"
if {$hadToken} { set env(CODEX_RETRY_TOKEN) $savedToken } else { unset env(CODEX_RETRY_TOKEN) }
rename websocket::takeover {}
rename websocket::native_takeover websocket::takeover

# A fake backend echoes one frame and ignores graceful termination.
rename after {}
rename real_after after
set backend [open [list | expect -c {
    trap SIG_IGN SIGTERM
    fconfigure stdin -encoding utf-8 -translation lf
    fconfigure stdout -encoding utf-8 -translation lf
    puts READY
    flush stdout
    if {[gets stdin line] >= 0} { puts $line; flush stdout }
    vwait forever
}] r+]
fconfigure $backend -blocking 0 -buffering line -encoding utf-8 -translation lf
set ready 0
set frameReady 0
set frame ""
fileevent $backend readable {
    if {[gets $::backend line] >= 0} {
        if {!$::ready && $line eq "READY"} {
            set ::ready 1
        } else {
            set ::frame $line
            set ::frameReady 1
        }
    } elseif {[eof $::backend]} {
        fileevent $::backend readable ""
        set ::ready -1
        set ::frameReady -1
    }
}
set child [lindex [pid $backend] 0]
set startup ""
set deadline ""
set failed [catch {
    set startup [after 3000 {set ::ready -1}]
    if {!$ready} { vwait ready }
    after cancel $startup
    if {$ready == 1} {
        native_backend_send "\n$request\n"
        set deadline [after 3000 {set ::frameReady -1}]
        if {!$frameReady} { vwait frameReady }
    }
} message]
after cancel $startup
after cancel $deadline
set before [clock milliseconds]
cleanup
if {$failed} { error $message }
check {$ready == 1} "fake backend startup timed out"
check {$frameReady == 1} "fake backend frame timed out"
check {[huddle equal [::huddle::json2huddle $frame] [::huddle::json2huddle $request]]} "stdio framing changed JSON data or types"
check {[clock milliseconds] - $before < 3000} "backend cleanup was not bounded"
check {[catch {exec kill -0 $child}]} "backend survived cleanup"
cleanup

# Exercise the real main/PTY lifecycle with synchronous forwarding teardown.
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set channel [open [file join $scratch codex] w]
puts $channel {#!/usr/bin/env tclsh}
puts $channel {
    fconfigure stdout -buffering full -encoding utf-8 -translation lf
    if {[lindex $argv 0] eq "app-server"} {
        puts {{"id":91,"result":{}}
{"id":92,"result":{}}}
        flush stdout
        vwait forever
    }
    set terminalMode [exec stty -g <@stdin]
    exec stty raw -echo <@stdin
    fconfigure stdin -encoding utf-8 -translation lf
    puts INPUT_READY
    flush stdout
    foreach expected {q я} {
        if {[read stdin 1] ne $expected} { exit 4 }
        puts "CHAR_FORWARDED:$expected"
        flush stdout
    }
    exec stty $terminalMode <@stdin
    puts LINE_INPUT_READY
    flush stdout
    if {[gets stdin line] < 0 || $line ne "exit"} { exit 2 }
    if {[exec stty size <@stdin] ne "24 80"} { exit 3 }
    # Closing the terminal is not process exit. A premature PTY close sends HUP.
    close stdin
    close stdout
    close stderr
    after 100
    exit 7
}
close $channel
file attributes [file join $scratch codex] -permissions 0755
set wrapper [file normalize [file join [file dirname [info script]] .. codex-retry]]
set fixture "set argv0 disconnect-fixture\n[list source $wrapper]\n"
append fixture {
    package require websocket
    # Initial resizing must replace the TUI's deliberately different dimensions.
    set stty_init {rows 1 columns 1}
    set forwarded 0
    rename websocket::send websocket::native_send
    proc websocket::send {socket type message} {
        incr ::forwarded
        if {[chan pending input $::backend] == 0} { error "missing buffered backend data" }
        connection $socket disconnect ""
        puts stderr FORWARDING_DISCONNECTED
        flush stderr
        return -1
    }
    rename spawn native_spawn
    proc spawn {args} {
        set result [uplevel 1 [list native_spawn {*}$args]]
        set ::client fixture
        fileevent $::backend readable backend_read
        return $result
    }
    rename wait native_wait
    proc wait {args} {
        set result [uplevel 1 [list native_wait {*}$args]]
        # Model stderr becoming unavailable after the TUI exits.
        if {$::closedStderr} { close stderr }
        return $result
    }
    set terminalMode [exec stty -g <@stdin]
    set status [main {}]
    if {$forwarded != 1 || [info exists backend] || [info exists client] || \
        [info exists proxyError]} { error "forwarding teardown failed" }
    if {[exec stty -g <@stdin] ne $terminalMode} { error "terminal mode was not restored" }
    exit $status
}
set driver {
    set wrapperSpawn $spawn_id
    fconfigure $wrapperSpawn -encoding utf-8
    set wrapper [exp_pid]
    set failed [catch {
        set disconnected 0
        set inputReady 0
        expect {
            -exact FORWARDING_DISCONNECTED {
                set disconnected 1
                if {!$inputReady} { exp_continue -continue_timer }
            }
            -exact INPUT_READY {
                set inputReady 1
                if {!$disconnected} { exp_continue -continue_timer }
            }
            eof { error "wrapper exited before forwarding teardown" }
            timeout { error "forwarding teardown or raw input readiness timed out" }
        }
        foreach character {q я} {
            send -- $character
            expect -timeout 2 {
                -exact "CHAR_FORWARDED:$character" {}
                timeout { error "terminal input was buffered until newline" }
                eof { error "TUI exited before forwarding input" }
            }
        }
        expect -timeout 2 {
            -exact LINE_INPUT_READY {}
            timeout { error "line input readiness timed out" }
            eof { error "TUI exited before restoring terminal mode" }
        }
        send -- "exit\r"
        expect {
            eof {}
            timeout { error "TUI exit timed out" }
        }
        set result [wait -i $wrapperSpawn]
        if {[lindex $result 2] != 0 || [lindex $result 3] != 7} {
            error "fake TUI resizing or EOF/exit-status forwarding failed: $result"
        }
    } message]
    if {$failed} {
        catch {exec kill -TERM $wrapper}
        catch {expect -timeout 2 eof}
        catch {exec kill -KILL $wrapper}
        puts stderr $message
        exit 1
    }
    exit 0
}
set savedPath $env(PATH)
set env(PATH) "$scratch:$env(PATH)"
foreach closedStderr {0 1} {
    set configuredFixture "[list set closedStderr $closedStderr]\n$fixture"
    set configuredDriver "set timeout 10\nset stty_init {rows 24 columns 80}\n"
    append configuredDriver "[list spawn -noecho expect -c $configuredFixture]\n$driver"
    set failed [catch {exec expect -c $configuredDriver 2>@1} message]
    if {$failed} { break }
}
set env(PATH) $savedPath
file delete -force $scratch
check {!$failed} "fake TUI forwarding teardown failed: $message"

puts "PASS: structured retry ordering, original input, backoff, cancellation, progress guards, IDs, arguments, authentication, and cleanup"
