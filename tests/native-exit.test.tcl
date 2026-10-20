#!/usr/bin/env tclsh

# The native launcher supplies a private directory and PTY observations over
# stdin. This fixture owns the fake backend and all presentation assertions.
package require json
package require json::write
package require huddle::json
package require websocket
json::write indented 0
set ::websocket::WS(maxlength) 1048576
# Tcllib logs socket EOF to stdout by default, which is our JSON control pipe.
# Keep diagnostics separate and omit transport payloads from Runner output.
foreach level [logger::levels] {
    ${::websocket::log}::logproc $level message \
        [list puts stderr "native fixture: WebSocket $level diagnostic"]
}

proc check {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}
proc js {value} { json::write string $value }
proc control {action args} {
    puts [json::write object action [js $action] {*}$args]
    flush stdout
}
proc bgerror {message} {
    control fail message [js $message]
    exit 1
}
proc plain {bytes} {
    regsub -all {\x1b\[[0-?]*[ -/]*[@-~]} $bytes {} bytes
    regsub -all {\r+\n} $bytes \n bytes
    return [string map [list \r \n] $bytes]
}

# Observe ASCII picker names in the launcher's 36-by-180 terminal. Ratatui
# updates individual cells; stripping cursor controls from redraws loses text.
namespace eval screen {
    variable blank [string repeat " " 180]
    variable lines [lrepeat 36 $blank]
    variable x 0
    variable y 0
    variable saved {0 0}
    variable pending ""
    variable synchronized 0
}
proc screen::erase {row first last} {
    variable lines
    lset lines $row [string replace [lindex $lines $row] $first $last \
        [string repeat " " [expr {$last - $first + 1}]]]
}
proc screen::scroll {count} {
    variable lines; variable blank
    set count [expr {min(36, $count)}]
    set lines [concat [lrange $lines $count end] [lrepeat $count $blank]]
}
proc screen::csi {parameters command} {
    variable lines; variable blank; variable x; variable y; variable saved; variable synchronized
    if {$parameters eq "?2026" && $command in {h l}} {
        set synchronized [expr {$command eq "h"}]
        return
    }
    if {$parameters eq "?1049" && $command in {h l}} {
        set lines [lrepeat 36 $blank]
        set x 0; set y 0
        return
    }
    if {![regexp {^[0-9;]*$} $parameters]} { return }
    set values [split $parameters \;]
    set first [lindex $values 0]
    set n [expr {$first eq "" || $first == 0 ? 1 : $first}]
    switch -- $command {
        H - f {
            set y [expr {min(35, $n - 1)}]
            set second [lindex $values 1]
            set x [expr {$second eq "" || $second == 0 ? 0 : min(179, $second - 1)}]
        }
        A { set y [expr {max(0, $y - $n)}] }
        B { set y [expr {min(35, $y + $n)}] }
        C { set x [expr {min(179, $x + $n)}] }
        D { set x [expr {max(0, $x - $n)}] }
        E { set y [expr {min(35, $y + $n)}]; set x 0 }
        F { set y [expr {max(0, $y - $n)}]; set x 0 }
        G { set x [expr {min(179, $n - 1)}] }
        d { set y [expr {min(35, $n - 1)}] }
        s { set saved [list $x $y] }
        u { lassign $saved x y }
        J {
            if {$first eq "3"} { return }
            if {$first eq "2"} {
                set lines [lrepeat 36 $blank]
            } elseif {$first eq "1"} {
                for {set row 0} {$row < $y} {incr row} { lset lines $row $blank }
                erase $y 0 [expr {min(179, $x)}]
            } else {
                erase $y [expr {min(179, $x)}] 179
                for {set row [expr {$y + 1}]} {$row < 36} {incr row} { lset lines $row $blank }
            }
        }
        K {
            if {$first eq "2"} { lset lines $y $blank } elseif {$first eq "1"} {
                erase $y 0 [expr {min(179, $x)}]
            } else { erase $y [expr {min(179, $x)}] 179 }
        }
        X { erase $y [expr {min(179, $x)}] [expr {min(179, $x + $n - 1)}] }
        S { scroll $n }
        T { set lines [lrange [concat [lrepeat [expr {min(36, $n)}] $blank] $lines] 0 35] }
        L {
            set n [expr {min(36 - $y, $n)}]
            set lines [lrange [concat [lrange $lines 0 [expr {$y - 1}]] \
                [lrepeat $n $blank] [lrange $lines $y end]] 0 35]
        }
        M {
            set n [expr {min(36 - $y, $n)}]
            set lines [concat [lrange $lines 0 [expr {$y - 1}]] \
                [lrange $lines [expr {$y + $n}] end] [lrepeat $n $blank]]
        }
    }
}
proc screen::feed {bytes} {
    variable pending; variable lines; variable x; variable y
    append pending $bytes
    while {$pending ne ""} {
        set char [string index $pending 0]
        set length 1
        if {$char eq "\033"} {
            if {[string length $pending] < 2} { return }
            set next [string index $pending 1]
            if {$next eq "\["} {
                if {![regexp {^\x1b\[([0-?]*)[ -/]*([@-~])} $pending sequence parameters command]} { return }
                set length [string length $sequence]
                csi $parameters $command
            } elseif {$next eq "\]"} {
                if {![regexp {^\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)} $pending sequence]} { return }
                set length [string length $sequence]
            } else {
                if {$next eq "7"} { csi {} s }
                if {$next eq "8"} { csi {} u }
                set length 2
            }
        } elseif {$char eq "\r"} { set x 0
        } elseif {$char eq "\n"} {
            incr y
            if {$y == 36} { scroll 1; set y 35 }
        } elseif {$char eq "\b"} { set x [expr {max(0, $x - 1)}]
        } elseif {$char eq "\t"} { set x [expr {min(179, ($x / 8 + 1) * 8)}]
        } else {
            scan $char %c code
            # Fixture names are ASCII; each UTF-8 lead byte occupies one cell,
            # while continuation bytes do not advance the cursor again.
            if {($code >= 32 && $code < 127) || $code >= 192} {
                if {$x == 180} { set x 0; incr y }
                if {$y == 36} { scroll 1; set y 35 }
                if {$code >= 192} { set char "?" }
                lset lines $y [string replace [lindex $lines $y] $x $x $char]
                incr x
            }
        }
        set pending [string range $pending $length end]
    }
}
proc screen::text {} {
    variable lines; variable synchronized
    if {$synchronized} { return "" }
    regsub -all {[ \t\n]} [join $lines \n] {} text
    return $text
}

# The wrapped run uses the same rejecting backend through a Tcllib bridge in
# place of `codex app-server proxy`. The actual native TUI still owns both PTY streams.
if {$argv eq {--backend}} {
    source [file join [file dirname [info script]] proxy-fixture.tcl]
    proc bridge_input {socket type message} {
        if {$type eq "connect"} { set ::incoming $socket }
        if {$type eq "text"} { websocket::send $::bridge text $message }
        if {$type in {close disconnect}} { exit 0 }
    }
    proc bridge {socket type message} {
        switch -- $type {
            connect { set ::bridge $socket; fixture::start bridge_input }
            text { websocket::send $::incoming text $message }
            close - disconnect { exit 0 }
            error - timeout { exit 1 }
        }
    }
    websocket::open $env(NATIVE_EXIT_ENDPOINT) bridge \
        -headers [list Authorization "Bearer $env(NATIVE_EXIT_TOKEN)"] -timeout 2000
    vwait forever
}

set scratch [file normalize [lindex $argv 0]]
set wrapped [expr {[lindex $argv 1] eq "wrapped"}]
check {[llength $argv] in {1 2} && [file isdirectory $scratch]} "private fixture directory required"
if {$wrapped} { set env(PATH) "[file join $scratch bin]:$env(PATH)" }
set threadId 01900000-0000-7000-8000-000000000001
set turnId 01900000-0000-7000-8000-000000000002
set random [open /dev/urandom rb]
set token [binary encode hex [read $random 16]]
close $random
set liveText {FIXTURE_LIVE_BEGIN
Disconnected from this task. Any running work continues.
To reconnect, run:
codex --remote ws://127.0.0.1:1/ --remote-auth-token-env CODEX_RETRY_TOKEN resume LIVE_LOOKALIKE
Use agents to stop this example task.
FIXTURE_LIVE_END}
set item [json::write object type [js agentMessage] id [js fixture-message] \
    text [js $liveText] phase null memoryCitation null delivery null questions null]
set turn [string map [list @ID@ [js $turnId] @ITEM@ $item] {
    {"id":@ID@,"rootTurnId":null,"items":[@ITEM@],"itemsView":"full",
     "status":"completed","error":null,"startedAt":1,"completedAt":1,"durationMs":0}
}]
set thread [string map [list @ID@ [js $threadId] @ROOT@ [js $scratch] \
    @PATH@ [js [file join $scratch fake-rollout.jsonl]] @TURN@ $turn] {
    {"id":@ID@,"sessionId":@ID@,"environments":null,"extra":null,
     "forkedFromId":null,"parentThreadId":null,"preview":"Neutral fixture",
     "ephemeral":false,"section":null,"sectionEnteredAt":null,"projectId":null,
     "historyMode":"legacy","modelProvider":"openai","model":"fixture",
     "reasoningEffort":null,"createdAt":1,"updatedAt":1,"recencyAt":null,
     "status":{"type":"idle"},"path":@PATH@,"cwd":@ROOT@,"cliVersion":"0.163.0",
     "originator":"fixture","source":"cli","canAcceptDirectInput":true,
     "threadSource":null,"agentNickname":null,"agentRole":null,"gitInfo":null,
     "name":null,"daybreakEnabled":null,"turns":[@TURN@]}
}]
set pickedId 01900000-0000-7000-8000-000000000003
set pickedTurnId 01900000-0000-7000-8000-000000000005
set pickedThread [string map [list $threadId $pickedId $turnId $pickedTurnId \
    fixture-message picked-message \
    [js [file join $scratch fake-rollout.jsonl]] [js [file join $scratch picked-rollout.jsonl]] \
    {Neutral fixture} {Picker target} \
    {"name":null} {"name":"Picker target"} \
    {"createdAt":1,"updatedAt":1} {"createdAt":2,"updatedAt":2} \
    FIXTURE_LIVE_END {FIXTURE_LIVE_END\nFIXTURE_PICKED_END}] $thread]
set decoyId 01900000-0000-7000-8000-000000000004
set decoyTurnId 01900000-0000-7000-8000-000000000006
set decoyThread [string map [list $threadId $decoyId $turnId $decoyTurnId \
    fixture-message decoy-message \
    [js [file join $scratch fake-rollout.jsonl]] [js [file join $scratch decoy-rollout.jsonl]] \
    {Neutral fixture} {Decoy fixture} {"name":null} {"name":"Decoy fixture"} \
    {"createdAt":1,"updatedAt":1} {"createdAt":3,"updatedAt":3}] $thread]

# List replies describe stored sessions without replaying history or claiming
# unloaded sessions are live. Rollout paths and history IDs stay per-session.
proc list_thread {thread} {
    set object [::huddle::json2huddle $thread]
    huddle set object turns [huddle list]
    if {[huddle get_stripped $object id] ni [list $::threadId $::selectedId]} {
        huddle set object status [huddle create type [huddle string notLoaded]]
        huddle set object canAcceptDirectInput [huddle null]
    }
    return [huddle jsondump $object "" ""]
}

# These are the entire backend, not forwards to an App Server. Unknown methods
# fail before execution, including inference, hooks, commands and login APIs.
proc result_for {method message object} {
    global scratch threadId pickedId pickedThread decoyId decoyThread
    set thread $::thread
    set turn $::turn
    set turnId $::turnId
    set item $::item
    if {$method in {thread/resume thread/read thread/turns/list thread/items/list
        thread/goal/get thread/queue/list thread/backgroundTerminals/list thread/unsubscribe
        account/usage/read}} {
        set requested [dict get $message params threadId]
        check {$requested in [list $threadId $pickedId $decoyId]} "unrelated session requested"
        if {$method eq "thread/resume"} {
            check {$requested ne $decoyId} "unrelated session requested"
        }
        if {$requested eq $pickedId} { set thread $pickedThread }
        if {$requested eq $decoyId} { set thread $decoyThread }
        set history [::huddle::json2huddle $thread]
        set turnId [huddle get_stripped $history turns 0 id]
        set turn [huddle jsondump [huddle get $history turns 0] "" ""]
        set item [huddle jsondump [huddle get $history turns 0 items 0] "" ""]
    }
    switch -- $method {
        initialize {
            return [json::write object userAgent [js native-exit-fixture] \
                codexHome [js $scratch] platformFamily [js unix] platformOs [js linux]]
        }
        thread/resume {
            return [string map [list @THREAD@ $thread @ROOT@ [js $scratch]] {
                {"thread":@THREAD@,"model":"fixture","modelProvider":"openai",
                 "serviceTier":null,"disabledPluginIds":[],"cwd":@ROOT@,
                 "runtimeWorkspaceRoots":[],"instructionSources":[],"approvalPolicy":"on-request",
                 "approvalsReviewer":"user","sandbox":{"type":"readOnly","networkAccess":false},
                 "activePermissionProfile":null,"reasoningEffort":null,"collaborationMode":null,
                 "multiAgentMode":"explicitRequestOnly","initialTurnsPage":null,
                 "turnsBackwardsCursor":null,"itemsBackwardsCursor":null}
            }]
        }
        config/read {
            return {{"config":{"model":"fixture","model_provider":"openai","approval_policy":"on-request","sandbox_mode":"read-only"},"origins":{},"layers":[]}}
        }
        configRequirements/read { return {{"requirements":null,"supportsIndependentSpeedModes":true}} }
        account/read { return {{"account":null,"requiresOpenaiAuth":false,"workspaceRouting":null}} }
        account/rateLimits/read {
            return {{"rateLimits":{},"rateLimitsByLimitId":null,"ordinaryUsageAllowed":null,"rateLimitResetCredits":null,"accountId":null,"rateLimitUpsell":null}}
        }
        account/workspaceMessages/read { return {{"featureEnabled":false,"messages":[]}} }
        account/bedrock/checkGovCloudRequirements { return {{"isGovCloud":false,"shouldWarn":false}} }
        account/usage/read {
            return {{"summary":{"lifetimeTokens":null,"peakDailyTokens":null,"longestRunningTurnSec":null,"currentStreakDays":null,"longestStreakDays":null},"dailyUsageBuckets":null,"threadUsage":null}}
        }
        plugin/list { return {{"marketplaces":[],"marketplaceLoadErrors":[],"featuredPluginIds":[]}} }
        model/list {
            return {{"data":[{"id":"fixture","model":"fixture","displayName":"fixture","description":"Neutral fixture","hidden":false,"isDefault":true,"supportedReasoningEfforts":[],"defaultReasoningEffort":"medium","inputModalities":["text"],"supportsPersonality":false,"additionalSpeedTiers":[],"serviceTiers":[]}],"nextCursor":null}}
        }
        thread/loaded/list {
            # The initial synthetic session is already loaded by this server.
            set loaded [json::write array [js $threadId]]
            if {$::selectedId eq $pickedId} { set loaded [json::write array [js $threadId] [js $pickedId]] }
            return [json::write object data $loaded nextCursor null]
        }
        thread/list {
            # Searching must move selection away from the newer default row.
            set data [json::write array [list_thread $decoyThread] [list_thread $pickedThread] [list_thread $thread]]
            if {[huddle exists $object params searchTerm] && \
                [huddle type $object params searchTerm] eq "string" && \
                [dict get $message params searchTerm] ne ""} {
                set data {[]}
                if {[string first [string tolower [dict get $message params searchTerm]] \
                    "picker target"] >= 0} { set data [json::write array [list_thread $pickedThread]] }
            }
            return [json::write object data $data nextCursor null backwardsCursor null]
        }
        thread/read { return [json::write object thread $thread] }
        thread/goal/get { return {{"goal":null}} }
        thread/queue/list - thread/backgroundTerminals/list { return {{"data":[],"nextCursor":null}} }
        thread/turns/list {
            return [json::write object data [json::write array $turn] nextCursor null backwardsCursor null]
        }
        thread/items/list {
            set entry [json::write object turnId [js $turnId] item $item startedAtMs null completedAtMs null]
            return [json::write object data [json::write array $entry] nextCursor null backwardsCursor null]
        }
        skills/list - mcpServerStatus/list - experimentalFeature/list - app/list -
        permissions/list - permissionProfile/list - collaborationMode/list - hooks/list {
            return {{"data":[],"nextCursor":null,"backwardsCursor":null}}
        }
        thread/unsubscribe { return {{"status":"unsubscribed"}} }
        default { error "native characterization blocked unsupported request" }
    }
}

set methods {}
set resumed 0
set disconnected 0
set exited 0
set peer ""
set peers {}
set connections 0
set pickerLists 0
set pickerSearches 0
array set pending {}
proc token_usage {} {
    set usage {{"totalTokens":17,"inputTokens":11,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":6,"reasoningOutputTokens":0}}
    set turnId [expr {$::selectedId eq $::pickedId ? $::pickedTurnId : $::turnId}]
    set params [json::write object threadId [js $::selectedId] turnId [js $turnId] \
        tokenUsage [json::write object total $usage last $usage modelContextWindow 1000]]
    websocket::send $::peer text [json::write object \
        method [js thread/tokenUsage/updated] params $params]
}
proc connection {socket type text} {
    if {[catch {
        switch -- $type {
            text {
                check {[string length $text] <= 1048576} "unbounded native request"
                set message [json::json2dict $text]
                set method [dict get $message method]
                lappend ::methods $method
                check {[llength $::methods] <= 128} "unbounded native metadata requests"
                if {$method eq "initialized"} {
                    check {[dict get $::peers $socket] eq "initialize"} "native metadata handshake was incomplete"
                    dict set ::peers $socket initialized
                    control checkpoint name [js initialized]
                    return
                }
                if {$method eq "initialize"} {
                    check {[dict get $::peers $socket] eq "connected"} "native metadata handshake was incomplete"
                    dict set ::peers $socket initialize
                } else {
                    check {[dict get $::peers $socket] in {initialize initialized}} "native metadata handshake was incomplete"
                }
                set object [::huddle::json2huddle $text]
                set result [result_for $method $message $object]
                set id [huddle get $object id]
                check {[huddle type $id] in {number string}} "invalid native request ID"
                websocket::send $socket text [json::write object \
                    id [huddle jsondump $id "" ""] result $result]
                if {$method eq "thread/resume"} {
                    check {$::peer eq "" || $socket eq $::peer} "native session lifecycle was incomplete"
                    set ::peer $socket
                    set ::selectedId [dict get $message params threadId]
                    incr ::resumed
                    token_usage
                    control checkpoint name [js resumed]
                    if {$::selectedId eq $::pickedId} {
                        check {$::pickerStage eq "selecting"} "native session lifecycle was incomplete"
                        set ::pickerStage picked
                        set ::snapshotAttempts 0
                        set ::snapshotRequested 0
                    }
                }
                if {$method eq "thread/list" && $socket ne $::peer} {
                    incr ::pickerLists
                    switch $::pickerStage {
                        cancel { set ::pickerStage cancel_ready }
                        reopen { set ::pickerStage search_ready }
                    }
                }
            }
            disconnect {
                dict unset ::peers $socket
                if {$socket eq $::peer} { set ::disconnected 1 }
                if {$socket ne $::peer && $::pickerStage eq "cancelling"} {
                    set ::pickerStage reopen
                    after 100 open_picker
                }
                finish
            }
            error - timeout { error "native fixture WebSocket failed" }
        }
    } message] == 1} { bgerror $message }
}

# Tcllib validates the upgrade and owns every WebSocket frame. Only this small,
# bounded HTTP header reader is needed before handing it the accepted socket.
proc accept {socket address port} {
    if {[catch {
        set ::pending($socket) [dict create headers {} bytes 0]
        fconfigure $socket -blocking 0 -buffering line -encoding ascii -translation crlf
        fileevent $socket readable [list handshake $socket]
    } message]} { catch {close $socket}; bgerror $message }
}
proc handshake {socket} {
    if {[catch {
        while {[gets $socket line] >= 0} {
            dict incr ::pending($socket) bytes [expr {[string length $line] + 2}]
            dict lappend ::pending($socket) headers $line
            set lines [dict get $::pending($socket) headers]
            check {[dict get $::pending($socket) bytes] <= 16384 && [llength $lines] <= 64} "unbounded native handshake"
            if {$line ne ""} { continue }
            fileevent $socket readable ""
            check {[lindex $lines 0] eq "GET / HTTP/1.1"} "invalid native handshake"
            set headers {}
            foreach line [lrange $lines 1 end-1] {
                check {[regexp {^([^:[:space:]]+):[ \t]*(.*)$} $line -> key value]} "invalid native header"
                set key [string tolower $key]
                if {[dict exists $headers $key]} {
                    check {$key eq "connection"} "duplicate native header"
                    dict append headers $key ", $value"
                } else { dict set headers $key [string trim $value] }
            }
            check {![dict exists $headers origin] && \
                [dict get $headers authorization] eq "Bearer $::token"} "native authentication failed"
            check {[string tolower [dict get $headers upgrade]] eq "websocket" && \
                ![catch {websocket::validate $headers} upgrade]} "invalid native WebSocket upgrade"
            set key [websocket::sec-websocket-accept [dict get $upgrade key]]
            puts $socket "HTTP/1.1 101 Switching Protocols\nUpgrade: websocket\nConnection: Upgrade\nSec-WebSocket-Accept: $key\n"
            flush $socket
            unset ::pending($socket)
            dict set ::peers $socket connected
            incr ::connections
            websocket::takeover $socket connection 1
            return
        }
        check {![eof $socket] && [dict get $::pending($socket) bytes] + [chan pending input $socket] <= 16384} "incomplete native handshake"
    } message] == 1} { bgerror $message }
}

set output ""
set quitOffset -1
set snapshotRequested 0
set snapshotAttempts 0
set footerRestored 0
set pickedPresented 0
set selectedId $threadId
set pickerStage initial
proc native_input {bytes} {
    control input data [js [binary encode base64 -maxlen 0 $bytes]]
}
proc native_type {text {done {}}} {
    # Picker input must arrive as keystrokes, rather than a single paste event.
    if {$text eq ""} {
        # Keep Enter separate from the native paste-burst suppression window.
        # Search selection still waits for its rendered result below.
        if {$done ne ""} { after 250 $done }
        return
    }
    native_input [string index $text 0]
    after 50 [list native_type [string range $text 1 end] $done]
}
proc open_picker {} {
    native_type /resume {native_input "\r"}
}
proc select_picker {} {
    if {$::pickerStage eq "search_typed"} {
        set screen [screen::text]
        if {[string first Pickertarget $screen] < 0 || \
            [string first Decoyfixture $screen] >= 0} { return }
        set ::pickerStage selecting
        native_input "\r"
    }
}
proc picker_presented {} {
    if {$::pickerStage ni {cancel_ready search_ready}} { return }
    set screen [screen::text]
    if {[string first Decoyfixture $screen] < 0 || \
        [string first Pickertarget $screen] < 0} { return }
    if {$::pickerStage eq "cancel_ready"} {
        set ::pickerStage cancelling
        native_input "\033"
    } else {
        set ::pickerStage searching
        native_type Picker {
            incr ::pickerSearches
            set ::pickerStage search_typed
            select_picker
        }
    }
}
set enablePaste "\033\[?2004h"
set disablePaste "\033\[?2004l"
proc quit_native {} {
    set ::quitOffset [string length $::output]
    control input data [js [binary encode base64 -maxlen 0 "\004"]]
}
proc observe {event} {
    switch -- [dict get $event event] {
        data {
            set bytes [binary decode base64 [dict get $event data]]
            append ::output $bytes
            check {[string length $::output] <= 262144} "unbounded native presentation"
            screen::feed $bytes
            picker_presented
            select_picker
            # A history write can temporarily release the terminal. Its final
            # bytes need not arrive in the same observation as raw-mode reentry.
            set history [screen::text]
            set marker [expr {$::pickerStage eq "picked" ? "FIXTURE_PICKED_END" : "FIXTURE_LIVE_END"}]
            if {!$::snapshotRequested && $::resumed && \
                [string first $marker $history] >= 0} {
                if {$::pickerStage eq "picked"} {
                    check {$::quitOffset < 0} "live history crossed the exit boundary"
                    set ::pickedPresented 1
                }
                set ::snapshotRequested 1
                control snapshot
            }
            set boundary [string last $::disablePaste $::output]
            if {$::quitOffset >= 0 && $boundary >= $::quitOffset && \
                ([string first "Disconnected from this task." $::output $boundary] >= 0 || \
                 ($::wrapped && [string first "To resume this session, run:" $::output $boundary] >= 0))} {
                check {[dict get $event restored]} "native footer arrived before terminal restoration"
                set ::footerRestored 1
            }
        }
        snapshot {
            if {[dict get $event canonical] || [dict get $event restored]} {
                check {[incr ::snapshotAttempts] <= 50} "native never entered interactive mode after rendering history"
                after 10 {control snapshot}
                return
            }
            check {![dict get $event canonical] && ![dict get $event restored]} "native never entered interactive mode"
            check {$::quitOffset < 0} "duplicate quit request"
            # Initial replay can replace usage received alongside the resume
            # reply. Publish the same cumulative snapshot once the UI is live,
            # then let its event loop consume it before requesting normal exit.
            if {$::pickerStage eq "initial"} {
                set ::pickerStage cancel
                after 100 open_picker
            } elseif {$::pickerStage eq "picked"} {
                token_usage
                after 100 quit_native
            }
        }
        exited {
            check {[dict get $event status] == 0} "native normal exit status changed"
            check {[dict get $event restored]} "native exit did not restore terminal attributes"
            check {[dict get $event reaped] && [dict get $event groupGone] && \
                [dict get $event ptyEof]} "native child or terminal survived exit"
            set ::exited 1
            finish
        }
        default { error "invalid native orchestration event" }
    }
}

proc finish {} {
    if {!$::exited || !$::disconnected || [dict size $::peers] != 0} { return }
    check {$::resumed == 2 && $::selectedId eq $::pickedId && $::quitOffset >= 0 && $::footerRestored} "native session lifecycle was incomplete"
    check {$::connections >= 3 && $::pickerLists >= 2 && $::pickerSearches == 1} "native session lifecycle was incomplete"
    check {[llength [lsearch -all -exact $::methods initialize]] == $::connections && \
        [llength [lsearch -all -exact $::methods initialized]] >= 1} "native metadata handshake was incomplete"
    set boundary [string last $::disablePaste $::output]
    set enabled [string last $::enablePaste $::output]
    check {$enabled >= 0 && $enabled < $::quitOffset && $boundary >= $::quitOffset && \
        [string first $::disablePaste $::output $::quitOffset] == $boundary} "missing ordered terminal restoration sequence"
    set live [plain [string range $::output 0 [expr {$boundary - 1}]]]
    # Selected history can retain cells from the previous view; its marker was
    # checked on screen before quit, rather than as contiguous redraw bytes.
    check {$::pickedPresented} "live history was not rendered before terminal restoration"
    foreach text {FIXTURE_LIVE_BEGIN {Disconnected from this task.} {To reconnect, run:} LIVE_LOOKALIKE FIXTURE_LIVE_END} {
        if {$::wrapped} {
            # Ratatui may place spaces with cursor movements instead of bytes.
            # Keep all marker/content/punctuation checks; fake PTYs check bytes.
            regsub -all {[ \t\n]} $live {} compactLive
            regsub -all {[ \t\n]} $text {} compactText
            check {[string first $compactText $compactLive] >= 0} "live history was not rendered before terminal restoration"
        } else {
            check {[string first $text $live] >= 0} "live history was not rendered before terminal restoration"
        }
    }
    # This byte boundary, not the terminal's later mode, excludes buffered live
    # lookalikes. The adapter must preserve the entire preceding byte stream.
    set footer [plain [string range $::output [expr {$boundary + [string length $::disablePaste]}] end]]
    check {[string first FIXTURE_LIVE $footer] < 0 && \
        [string first FIXTURE_PICKED $footer] < 0} "live history crossed the exit boundary"
    if {$::wrapped} {
        check {[regexp -all {To resume this session, run:} $footer] == 1} "missing or duplicate wrapper recovery"
        set launcher [file normalize [file join [file dirname [info script]] .. codex-retry]]
        check {[regexp {To resume this session, run:\n[ \t]*([^\n]+)} $footer -> command]} "wrapper recovery was not copyable"
        set words [split [exec sh -c "set -- $command; printf '%s\\n' \"\$@\""] \n]
        check {$words eq [list codex-retry resume $::pickedId]} "wrapper recovery changed launcher or session arguments"
        set resolved [exec sh -c {command -v "$1"} sh [lindex $words 0]]
        file stat $resolved actualIdentity
        file stat $launcher expectedIdentity
        check {$actualIdentity(dev) == $expectedIdentity(dev) && \
            $actualIdentity(ino) == $expectedIdentity(ino)} "wrapper recovery resolved to another launcher"
        check {[string first "client disconnected; shared server and background work may continue" $footer] >= 0} "shared-server lifetime advice was missing"
        foreach mode {1000 1002 1003 1005 1006 1015} {
            check {[string first "\033\[?${mode}l" $::output $::quitOffset] >= 0} "wrapper did not disable terminal mouse mode"
        }
        foreach obsolete {{Disconnected from this task.} {To reconnect, run:} --remote CODEX_RETRY_TOKEN agents} {
            check {[string first $obsolete $footer] < 0} "obsolete remote advice survived wrapper exit"
        }
    } else {
        check {[regexp -all {Disconnected from this task\.} $footer] == 1 && \
            [regexp -all {To reconnect, run:} $footer] == 1} "missing or duplicate native exit advice"
        set disconnect [string first "Disconnected from this task." $footer]
        set reconnect [string first "To reconnect, run:" $footer]
        set command [string first "codex --remote $::endpoint --remote-auth-token-env CODEX_RETRY_TOKEN resume $::pickedId" $footer]
        set stop [string first agents $footer $command]
        check {$disconnect >= 0 && $reconnect > $disconnect && $command > $reconnect && \
            $stop > $command} "native reconnect or remote stop advice was incomplete or out of order"
    }
    check {[regexp -all {Token usage(?: so far)?:} $footer] == 1} "native synthetic token summary was missing or duplicated"
    regexp {Token usage(?: so far)?:([^\n]*)} $footer -> summary
    foreach pattern {{total\s*=\s*17\M} {input\s*=\s*11\M} {output\s*=\s*6\M}} {
        check {[regexp $pattern $summary]} "native synthetic token counts changed"
    }
    check {[string first $::token $::output] < 0} "native output exposed the bearer token"
    catch {close $::peer}
    set ::peer ""
    set listener $::listener
    close $listener
    set ::listener ""
    check {[catch {fconfigure $listener}] && [dict size $::peers] == 0 && \
        [array size ::pending] == 0} "native fixture listener survived cleanup"
    control complete
    exit 0
}
proc read_control {} {
    if {[catch {
        while {[gets stdin line] >= 0} { observe [json::json2dict $line] }
        check {![eof stdin]} "native orchestration disconnected"
    } message]} { bgerror $message }
}

fconfigure stdin -blocking 0 -encoding utf-8 -translation lf
fconfigure stdout -buffering line -encoding utf-8 -translation lf
set listener [socket -server accept -myaddr 127.0.0.1 0]
set endpoint ws://127.0.0.1:[lindex [fconfigure $listener -sockname] 2]/
fileevent stdin readable read_control
after 20000 {bgerror "native exit characterization timed out"}
control launch endpoint [js $endpoint] token [js $token] session [js $threadId]
vwait forever
