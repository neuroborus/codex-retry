#!/usr/bin/env tclsh

package require huddle::json
package require json
source [file join [file dirname [info script]] .. codex-retry]
set proxyFixture [file normalize [file join [file dirname [info script]] proxy-fixture.tcl]]
# Every fake child inherits an empty wrapper configuration, never the user's.
set configEnvironment [concat [array get env XDG_CONFIG_HOME] [array get env TMPDIR]]
set configChannel [file tempfile configScratch]
set unitFailure 0
set unitPhase 10
set transportJob ""
proc transport_output {channel} {
    puts -nonewline [read $channel]
    if {[eof $channel]} { fileevent $channel readable "" }
}
try {
    close $configChannel
    file delete $configScratch
    file mkdir $configScratch
    file attributes $configScratch -permissions 0700
    set env(XDG_CONFIG_HOME) $configScratch
    set env(TMPDIR) $configScratch

proc check {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}

# Dependency failure must happen before server or TUI effects, with no fallback.
set dependencyProbe {
    rename package native_package
    proc package {command args} {
        if {$command eq "require" && [lindex $args 0] eq "tdom"} { error "fixture: tDOM unavailable" }
        native_package $command {*}$args
    }
    proc exec {args} { puts stderr UNEXPECTED_PROCESS; exit 92 }
    proc spawn {args} { puts stderr UNEXPECTED_PROCESS; exit 92 }
    set argv0 dependency-probe
}
append dependencyProbe [list source [file normalize [file join [file dirname [info script]] .. codex-retry]]] "\n"
set failed [catch {exec [info nameofexecutable] << $dependencyProbe 2>@1} message options]
check {$failed && [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS" && \
    [lindex [dict get $options -errorcode] 2] == 1 && \
    [string first "tDOM 0.9.3 or newer is required" $message] >= 0 && \
    [string first UNEXPECTED_PROCESS $message] < 0} "missing tDOM did not stop startup clearly before process effects"
unset dependencyProbe failed message options

# Native initialization guards observe the original JSON callback interface.
set callbackProbe "set argv0 callback-probe\n[list source [file normalize [file join [file dirname [info script]] .. codex-retry]]]\n"
append callbackProbe {
    proc backend_send {json} { lappend ::forwarded $json }
    proc bgerror {message} { error $message }
    rename retry::client retry::observed_client
    proc retry::client {json} {
        set message [json::json2dict $json]
        if {[field $message method] ni {initialize initialized}} { error "metadata handshake only" }
        retry::observed_client $json
    }
    set initialize { {"id":0,"method":"initialize","params":{}} }
    set initialized {{"method":"initialized"}}
    set forwarded {}
    connection fixture text $initialize
    connection fixture text $initialized
    if {$forwarded ne [list $initialize $initialized]} { error "metadata JSON changed" }
    puts CALLBACK_COMPATIBLE
}
set failed [catch {exec [info nameofexecutable] << $callbackProbe 2>@1} message]
check {!$failed && $message eq "CALLBACK_COMPATIBLE"} "native initialization callback compatibility failed: $message"
unset callbackProbe failed message

# Duplicate protocol members are fatal before routing or recovery can act.
proc reject_duplicate {script} {
    set failed [catch {uplevel 1 $script} message]
    check {$failed && $message eq "duplicate JSON key"} "duplicate protocol JSON was not rejected"
}

# Public tDOM conversion retains every JSON kind without guessing from text.
set domCommands [lsort [info commands ::dom*]]
foreach json {
    null true false 0 -0 503.0 5.03e2 9007199254740993123456789
    {""} {"503"} {"true"} {"null"} {[]} {{}}
    {[1,"1",true,"true",null,"null",{},[]]}
    {{"types":{"object":{},"array":[],"number":503,"decimal":503.0,"exponent":5.03e2,"string":"503","boolean":true,"null":null}}}
    {{"unicode":"éλ","escaped":"\u00e9\u03bb","pair":"\uD83D\uDE00","nul":"\u0000","key\u0000tail":"kept","controls":"\"\\\/\b\f\n\r\t"}}
    {{"nested":[{"a":[null,false,{"b":"x"}]}],"interpolation":"$HOME [pid] `literal`"}}
} {
    set value [json_decode $json]
    check {[huddle equal $value [::huddle::json2huddle $json]]} "tDOM changed a typed JSON value"
    check {[json_value $value] eq [json::json2dict $json]} "untyped routing view changed"
    check {[lsort [info commands ::dom*]] eq $domCommands} "successful decoding leaked DOM commands"
}
foreach number {0 -0 503 503.0 5.03e2 1E+09 -1.25e-07 9007199254740993123456789} {
    set value [json_decode $number]
    check {[huddle type $value] eq "number" && [json_dump $value] eq $number} "numeric spelling changed"
    check {![huddle equal $value [huddle string $number]]} "numeric and string identities merged"
}
set value [automatic::decode {{"":"","\u0061":"éλ","pair":"\ud83d\ude00","raw":"😀","key\u0000tail":"\u0000","\u007b":"brace","HUDDLE {s key}":"literal"}}]
check {[huddle get_stripped $value a] eq "éλ" && \
    [huddle get_stripped $value pair] eq [huddle get_stripped $value raw]} "escaped Unicode changed"
check {[huddle get_stripped $value "key\u0000tail"] eq "\u0000" && \
    [huddle get_stripped $value ""] eq "" && \
    [huddle get_stripped $value "\{"] eq "brace" && \
    [huddle get_stripped $value {HUDDLE {s key}}] eq "literal"} "member names or NUL changed"
foreach json [list {} {null true} {{} {}} {{} trailing} {{} /* comment */} \
    {/* comment */ {}} {{"x":1,}} {[1,]} {{"n":01}} {{"n":+1}} {{"n":NaN}} \
    {{"n":1.}} {{"n":1e}} {{"s":"\v"}} {{"s":"\uZZZZ"}} {{"s":"unterminated}} \
    {{"a":1,"a":2}} {{"a":1,"\u0061":2}} {{"nested":{"x":1,"x":2}}} \
    {{"x":[{"k":1,"k":2}]}} {{"key\u0000tail":1,"key\u0000tail":2}} \
    "\{\"x\":\"raw\ncontrol\"\}" "\{\"x\":\"raw\u0000control\"\}" \
    "\{\u00a0\"x\":1\}" "\{\}\u0000trailing"] {
    check {[catch {json_decode $json}]} "invalid or duplicate JSON was accepted"
    check {[lsort [info commands ::dom*]] eq $domCommands} "rejected JSON leaked DOM commands"
}
for {set code 0} {$code < 32} {incr code} {
    set json [format {{"raw":"%c"}} $code]
    check {[catch {json_decode $json}]} "unescaped JSON control character was accepted"
    check {[lsort [info commands ::dom*]] eq $domCommands} "raw control rejection leaked DOM commands"
}
foreach json {null true false 1 {"object"} {[]} {[{}]}} {
    check {[catch {automatic::decode $json}]} "protocol accepted a non-object root"
}
# Force a conversion exception independently of parser and duplicate failures.
rename json_node original_json_node
try {
    proc json_node {node} { error "injected conversion failure" }
    check {[catch {json_decode {{"valid":true}}} message] && \
        $message eq "injected conversion failure"} "conversion exception was lost"
} finally {
    rename json_node {}
    rename original_json_node json_node
}
check {[lsort [info commands ::dom*]] eq $domCommands} "conversion exception leaked DOM commands"
unset domCommands value number json message code

# Large JSON strings must not stall the terminal's shared event loop.
set latencyText [string repeat "Neutral fixture output. \" \u00e9 \u03bb\n" 60000]
set latencyJson [json::write object method [json::write string fixture/metadata] \
    params [json::write object text [json::write string $latencyText]]]
set latencyStart [clock milliseconds]
set latencyObject [automatic::decode $latencyJson]
set latencyElapsed [expr {[clock milliseconds] - $latencyStart}]
check {[huddle get_stripped $latencyObject params text] eq $latencyText} "large typed JSON changed content"
check {$latencyElapsed < 1000} "large JSON parsing blocked terminal input for at least one second"
unset latencyText latencyJson latencyStart latencyObject latencyElapsed

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
proc compacted {turn {thread t1}} {
    retry::server [json_dump [huddle create method [huddle string thread/compacted] \
        params [huddle create threadId [huddle string $thread] turnId [huddle string $turn]]]]
}
set request {{"id":7,"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"original\nrequest \"quoted\" é\u0001"},{"type":"localImage","path":"sample.png"}],"effort":"high","sandboxPolicy":{"type":"readOnly"},"special":{"odd\"key":"escaped"},"optional":null,"flag":true,"count":3,"emptyObject":{},"emptyArray":[]}}}
set userItem {{"type":"userMessage","id":"original-user","clientId":null,"content":[{"text_elements":[],"text":"original\nrequest \"quoted\" é\u0001","type":"text"},{"path":"sample.png","type":"localImage"}]}}
set userItems [json::write array $userItem]
proc user_event {method {item ""} {turn turn1} {thread t1}} {
    if {$item eq ""} { set item $::userItem }
    retry::server [format {{"method":"%s","params":{"threadId":"%s","turnId":"%s","item":%s}}} $method $thread $turn $item]
}
proc begin {{acknowledge 1}} {
    retry::reset
    set ::retry::finished {}
    retry::client $::request
    if {$acknowledge} { reply 7 turn1; started turn1 }
}

# Opt-in recovery uses the same controlled timers and transport as overloads.
rename automatic::notify automatic::native_notify
set notices {}
proc automatic::notify {json} { lappend ::notices [::huddle::json2huddle $json]; return 1 }
proc configure_fixture {json} {
    set path [file join $::configScratch codex-retry config.json]
    file mkdir [file dirname $path]
    set channel [open $path w]
    puts -nonewline $channel $json
    close $channel
    automatic::configure
}
automatic::configure
check {$automatic::flags eq {auto_reset_limit 0 auto_continue_after_stop 0}} "missing config enabled recovery"
foreach json {
    {{}}
    {{"unknown":true}}
    {{"auto_reset_limit":false,"auto_continue_after_stop":false}}
} {
    configure_fixture $json
    check {$automatic::flags eq {auto_reset_limit 0 auto_continue_after_stop 0} && $automatic::configWarning eq ""} "default flags changed"
}
foreach value {null 0 1 {"true"} {"false"} {[]} {{}}} {
    configure_fixture [format {{"auto_reset_limit":true,"auto_continue_after_stop":%s}} $value]
    check {$automatic::flags eq {auto_reset_limit 0 auto_continue_after_stop 0} && $automatic::configWarning ne ""} "invalid JSON flag did not disable both modes"
}
foreach json [list {[]} {true} {} {{"auto_reset_limit":true} trailing} \
    {{"auto_reset_limit":true},{}} {{"auto_reset_limit":true,}} \
    {{"auto_reset_limit":"true","auto_reset_limit":true}} \
    "\{\"auto_reset_limit\":true,\"unknown\":\"raw\nnewline\"\}" \
    "\{\"auto_reset_limit\":true,\u00a0\"unknown\":null\}" \
    {/* comment */ "auto_reset_limit":true} [string repeat x 16385]] {
    configure_fixture $json
    check {$automatic::flags eq {auto_reset_limit 0 auto_continue_after_stop 0} && $automatic::configWarning ne ""} "malformed config enabled recovery"
}
set path [file join $configScratch codex-retry config.json]
file delete $path
file mkdir $path
automatic::configure
check {$automatic::configWarning ne ""} "unreadable config was silently accepted"
file delete $path
retry::client {{"method":"initialized"}}
retry::client {{"method":"initialized"}}
check {[llength $notices] == 1 && [huddle get_stripped [lindex $notices 0] method] eq "warning"} "config warning was missing or repeated"
foreach reset {0 1} {
    foreach follow {0 1} {
        configure_fixture [format {{"auto_reset_limit":%s,"auto_continue_after_stop":%s}} \
            [expr {$reset ? "true" : "false"}] [expr {$follow ? "true" : "false"}]]
        check {[dict get $automatic::flags auto_reset_limit] == $reset && \
            [dict get $automatic::flags auto_continue_after_stop] == $follow && \
            $automatic::configWarning eq ""} "JSON boolean combination was not preserved"
    }
}
file delete [file join $configScratch codex-retry config.json]
automatic::configure
set autoSequence 0
proc auto_begin {{reset 0} {follow 1} {acknowledge 1} {client ""}} {
    automatic::cancel
    retry::reset
    set ::sent {}
    set ::notices {}
    set ::automatic::live {}
    set ::automatic::flags [list auto_reset_limit $reset auto_continue_after_stop $follow]
    automatic::selected [::huddle::json2huddle {{"model":"fixture-model","modelProvider":"openai"}}] t1
    set ::autoRequest [::huddle::json2huddle $::request]
    set ::autoId [json::write string manual-[incr ::autoSequence]]
    set ::autoTurn own-$::autoSequence
    huddle set ::autoRequest id [::huddle::json2huddle $::autoId]
    huddle set ::autoRequest params toolOutput [huddle create text [huddle string old-output]]
    huddle set ::autoRequest params additionalContext [huddle create old [huddle string context]]
    huddle set ::autoRequest params parentTurnId [huddle string old-parent]
    if {$client ne ""} { huddle set ::autoRequest params clientUserMessageId [huddle string $client] }
    retry::client [json_dump $::autoRequest]
    if {$acknowledge} { reply $::autoId $::autoTurn; started $::autoTurn }
}
proc auto_reply {result {id ""}} {
    if {$id eq ""} { set id [dict get $::automatic::current opId] }
    retry::server [format {{"id":%s,"result":%s}} $id $result]
}
proc limits_fixture {json path value} {
    set object [::huddle::json2huddle $json]
    huddle set object {*}$path [::huddle::json2huddle $value]
    return [json_dump $object]
}
proc auto_followup {} {
    set follow [::huddle::json2huddle [lindex $::sent end]]
    set params [huddle get $follow params]
    check {[huddle get_stripped $follow method] eq "turn/start" && \
        [huddle get_stripped $params threadId] eq "t1"} "follow-up changed thread or method"
    check {[huddle type $params input] eq "list" && [huddle llength [huddle get $params input]] == 1 && \
        [huddle get_stripped $params input 0 type] eq "text" && \
        [huddle get_stripped $params input 0 text] eq "continue"} "follow-up was not exactly plain ASCII continue"
    check {[huddle type $params clientUserMessageId] eq "string" && \
        [huddle get_stripped $params clientUserMessageId] ne ""} "follow-up omitted its fresh user identity"
    foreach key {effort sandboxPolicy} {
        check {[huddle equal [huddle get $params $key] [huddle get $::autoRequest params $key]]} "follow-up changed effective settings"
    }
    foreach key {toolOutput additionalContext parentTurnId rootTurnId special flag count} {
        check {![huddle exists $params $key]} "follow-up replayed original context or metadata"
    }
    return [json_dump [huddle get $follow id]]
}
set exhausted {{"accountId":"account-A","ordinaryUsageAllowed":false,"rateLimits":{"limitId":"codex","normalModelSlug":null,"spendControlReached":false,"rateLimitReachedType":"rate_limit_reached","primary":{"usedPercent":100,"resetsAt":1000},"secondary":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":1,"credits":null}}}
set restored [string map [list {"ordinaryUsageAllowed":false} {"ordinaryUsageAllowed":true} \
    {"rateLimitReachedType":"rate_limit_reached"} {"rateLimitReachedType":null}] $exhausted]
proc auto_until {stage} {
    auto_begin 1 1
    completed $::autoTurn failed usageLimitExceeded
    if {$stage eq "queued_read"} { return }
    fire
    if {$stage eq "read"} { return }
    auto_reply $::exhausted
    if {$stage eq "queued_consume"} { return }
    fire
    if {$stage eq "consume"} { return }
    auto_reply {{"outcome":"reset"}}
    if {$stage eq "verify"} { return }
    auto_reply $::restored
}

# Both flags default off, and each flag authorizes only its own terminal code.
foreach reset {0 1} {
    foreach follow {0 1} {
        auto_begin $reset $follow
        completed $autoTurn failed cyberPolicy
        check {[dict size $timers] == $follow} "content-stop flag combination scheduled the wrong action"
        if {$follow} { fire; auto_followup; check {[llength $sent] == 1} "content stop also tried a reset" }
        auto_begin $reset $follow
        completed $autoTurn failed usageLimitExceeded
        check {[dict size $timers] == $reset} "usage-limit flag combination scheduled the wrong action"
        if {$reset} {
            fire
            check {[field [json::json2dict [lindex $sent end]] method] eq "account/rateLimits/read"} "usage failure skipped the authoritative read"
        }
    }
}
foreach code {other misalignmentPolicyViolation rateLimitExceeded sessionBudgetExceeded contextWindowExceeded unauthorized} {
    auto_begin 1 1
    completed $autoTurn failed $code
    check {[dict size $timers] == 0 && $sent eq ""} "an unrelated error triggered opt-in recovery"
}
auto_begin 1 1
retry::server [format {{"method":"error","params":{"threadId":"t1","turnId":"%s","willRetry":false,"error":{"codexErrorInfo":"cyberPolicy","message":"This content cannot be shown"}}}} $autoTurn]
retry::server [format {{"method":"model/safetyBuffering/updated","params":{"threadId":"t1","turnId":"%s","showBufferingUi":true}}} $autoTurn]
retry::server [format {{"method":"turn/moderationMetadata","params":{"threadId":"t1","turnId":"%s","metadata":{"stop":"cyberPolicy"}}}} $autoTurn]
check {[dict size $timers] == 0} "a nonterminal restriction event scheduled continuation"
completed $autoTurn completed cyberPolicy
check {[dict size $timers] == 0} "normal successful completion triggered continuation"

# Partial tool effects permit a new neutral turn, never original-request replay.
auto_begin 1 1
user_event item/completed {} $autoTurn
completed $autoTurn failed cyberPolicy {[{"type":"commandExecution","id":"already-applied"}]}
completed $autoTurn failed cyberPolicy
check {[dict size $timers] == 1 && [llength $sent] == 0} "duplicate stop acted early or scheduled multiple turns"
fire
set followId [auto_followup]
check {[reply $followId continued-turn] == 0} "internal continuation reply leaked to native client"
started continued-turn
completed continued-turn failed serverOverloaded
check {[dict size $timers] == 1 && [lindex $delays end] == 5000} "continuation lost the default overload retry"
fire
set replayId [auto_followup]
reply $replayId replayed-continuation
started replayed-continuation
completed replayed-continuation failed usageLimitExceeded
check {[dict size $timers] == 1 && [llength $notices] == 0 && [llength $sent] == 2} "overload replay blocked a later eligible reset"
fire
auto_reply $exhausted
fire
auto_reply {{"outcome":"reset"}}
auto_reply $restored
fire
set id [auto_followup]
check {[llength $sent] == 6 && [dict size $timers] == 0} "reset after overload did not submit one continuation"
reply $id recovered-after-overload
completed recovered-after-overload completed
# A manual new turn, without resetting the engine, remains eligible.
huddle set autoRequest id [huddle string renewed-manual]
retry::client [json_dump $autoRequest]
reply {"renewed-manual"} renewed-turn
completed renewed-turn failed cyberPolicy
fire
auto_followup
check {[llength $sent] == 7} "new manual input lost recovery eligibility"

# Reset outcomes require an authoritative, account-matched post-redemption read.
foreach outcome {reset alreadyRedeemed} {
    auto_until read
    set readId [dict get $automatic::current opId]
    check {[auto_reply $exhausted] == 0} "internal limits reply leaked"
    set logical [json_dump [dict get $automatic::current redemption]]
    auto_reply $exhausted $readId
    completed $autoTurn failed usageLimitExceeded
    check {[json_dump [dict get $automatic::current redemption]] eq $logical && [dict size $timers] == 1} "duplicates changed the logical redemption"
    fire
    set consume [::huddle::json2huddle [lindex $sent end]]
    check {[huddle get_stripped $consume method] eq "account/rateLimitResetCredit/consume" && \
        [huddle get_stripped $consume params idempotencyKey] ne "" && \
        ![huddle exists $consume params creditId]} "count-only credit was not redeemable"
    set consumeId [json_dump [huddle get $consume id]]
    auto_reply [format {{"outcome":"%s"}} $outcome]
    auto_reply [format {{"outcome":"%s"}} $outcome] $consumeId
    check {[llength $sent] == 3 && [field [json::json2dict [lindex $sent end]] method] eq "account/rateLimits/read"} "consume outcome skipped or duplicated verification"
    auto_reply $restored
    check {[llength $sent] == 3} "verification submitted continuation before native forwarding"
    fire
    auto_followup
    check {[llength $sent] == 4 && [dict size $timers] == 0} "verified reset did not submit exactly one continuation"
}

# Distinct failures recover independently; stale events cannot steer a later
# incident, authorize its account operations, or spend its verification read.
proc auto_stale {replies turns} {
    set before [list $::automatic::current $::retry::current $::automatic::live \
        $::timers $::sent $::notices]
    foreach {id result} $replies {
        check {[auto_reply $result $id] == 0} "an earlier account reply leaked to the client"
        check {[retry::server [format {{"id":%s,"error":{"code":-1,"message":"late account error"}}} $id]] == 0} "an earlier account error leaked to the client"
    }
    foreach {turn code} $turns {
        started $turn
        completed $turn failed $code
        user_event item/completed {{"type":"commandExecution","id":"earlier-tool"}} $turn
    }
    check {[list $::automatic::current $::retry::current $::automatic::live \
        $::timers $::sent $::notices] eq $before} "earlier-incident events changed a later recovery"
}
foreach {reset follow codes} {
    0 1 {cyberPolicy cyberPolicy cyberPolicy}
    1 0 {usageLimitExceeded usageLimitExceeded}
    1 1 {usageLimitExceeded cyberPolicy usageLimitExceeded}
    1 1 {cyberPolicy usageLimitExceeded cyberPolicy}
} {
    auto_begin $reset $follow
    set turn $autoTurn
    set oldReplies {}
    set oldTurns {}
    set redemptionKeys {}
    set followIds {}
    set userIds {}
    set incident 0
    foreach code $codes {
        incr incident
        set dispatched [llength $sent]
        completed $turn failed $code
        set pending $timers
        completed $turn failed $code
        auto_stale $oldReplies $oldTurns
        check {$timers eq $pending && [dict size $timers] == 1 && \
            [llength $sent] == $dispatched} "duplicate failure changed its queued action"
        if {$code eq "usageLimitExceeded"} {
            fire
            set readId [dict get $automatic::current opId]
            check {[lsearch -exact $oldReplies $readId] < 0 && \
                [field [json::json2dict [lindex $sent end]] method] eq "account/rateLimits/read"} "a reset incident reused an account operation or skipped fresh eligibility"
            auto_stale $oldReplies $oldTurns
            auto_reply $exhausted
            set logical [json_dump [dict get $automatic::current redemption]]
            set key [huddle get_stripped [dict get $automatic::current redemption] idempotencyKey]
            check {[lsearch -exact $redemptionKeys $key] < 0} "distinct reset incidents reused a logical redemption key"
            lappend redemptionKeys $key
            set pending $timers
            auto_reply $exhausted $readId
            completed $turn failed $code
            check {$timers eq $pending && [json_dump [dict get $automatic::current redemption]] eq $logical} "duplicates changed a reset's logical redemption"
            fire
            set consumeId [dict get $automatic::current opId]
            set consume [::huddle::json2huddle [lindex $sent end]]
            check {[huddle get_stripped $consume method] eq "account/rateLimitResetCredit/consume" && \
                [json_dump [huddle get $consume params]] eq $logical} "redemption changed at dispatch"
            auto_stale $oldReplies $oldTurns
            set pending $timers
            auto_reply $exhausted $readId
            completed $turn failed $code
            check {$timers eq $pending && [llength $sent] == $dispatched + 2} "duplicate failure or eligibility reply consumed another reset"
            auto_reply {{"outcome":"reset"}}
            set verifyId [dict get $automatic::current opId]
            auto_stale $oldReplies $oldTurns
            # Spend the bounded extra verification on each incident. A later
            # incident must get its own budget and authoritative account read.
            retry::server {{"method":"account/rateLimits/updated","params":{}}}
            auto_reply $restored
            set finalVerifyId [dict get $automatic::current opId]
            check {$finalVerifyId ne $verifyId && [field $automatic::current phase] eq "verify"} "a later reset lost its independent verification read"
            auto_stale $oldReplies $oldTurns
            auto_reply $restored
            lappend oldReplies $readId $exhausted $consumeId {{"outcome":"reset"}} \
                $verifyId $restored $finalVerifyId $restored
        }
        lappend oldTurns $turn $code
        auto_stale $oldReplies [lrange $oldTurns 0 end-2]
        fire
        set id [auto_followup]
        set followRequest [::huddle::json2huddle [lindex $sent end]]
        set userId [huddle get_stripped $followRequest params clientUserMessageId]
        check {[lsearch -exact $followIds $id] < 0 && [lsearch -exact $userIds $userId] < 0} "distinct continuations reused request or user identity"
        lappend followIds $id
        lappend userIds $userId
        set dispatched $sent
        # Duplicates after dispatch must neither queue another turn nor cancel
        # ownership while the new acknowledgement is still pending.
        auto_stale $oldReplies $oldTurns
        set turn repeated-$autoSequence-$incident
        reply $id $turn
        started $turn
        set params [huddle get $followRequest params]
        set echo [huddle create type [huddle string userMessage] id [huddle string user-$turn] \
            clientId [huddle get $params clientUserMessageId] content [huddle get $params input]]
        user_event item/completed [json_dump $echo] $turn
        auto_stale $oldReplies $oldTurns
        check {$sent eq $dispatched && [dict size $timers] == 0 && $notices eq ""} "duplicate events dispatched another continuation or stopped a valid one"
    }
    completed $turn completed
    check {[dict size $timers] == 0 && $notices eq ""} "success after repeated recovery continued or warned"
}
auto_until read
set detailed [string map [list {"credits":null} {"credits":[{"id":"earned-current","status":"available","resetType":"codexRateLimits"}]}] $exhausted]
auto_reply $detailed
fire
check {[field [json::json2dict [lindex $sent end]] params creditId] eq "earned-current"} "credit ID was not selected from the current read"
foreach outcome {noCredit nothingToReset unknown} {
    auto_until consume
    auto_reply [format {{"outcome":"%s"}} $outcome]
    check {[dict size $timers] == 0 && [llength $notices] == 1 && [llength $sent] == 2} "failed redemption continued or looped"
}
foreach {path value} {
    {rateLimitResetCredits availableCount} 0
    {rateLimitResetCredits availableCount} null
    {rateLimitResetCredits availableCount} {"1"}
    rateLimitResetCredits null
    rateLimitResetCredits {{}}
    ordinaryUsageAllowed true
    ordinaryUsageAllowed null
    {rateLimits spendControlReached} true
    {rateLimits spendControlReached} null
    {rateLimits rateLimitReachedType} {"workspace_owner_usage_limit_reached"}
    {rateLimits limitId} {"unrelated-quota"}
    accountId null
} {
    auto_until read
    auto_reply [limits_fixture $exhausted $path $value]
    check {[dict size $timers] == 0 && [llength $notices] == 1 && [llength $sent] == 1} "unverified exhaustion or credits consumed a reset"
}
foreach {path value} {
    ordinaryUsageAllowed null
    ordinaryUsageAllowed false
    accountId {"account-B"}
    {rateLimits limitId} {"other-quota"}
    {rateLimits rateLimitReachedType} {"rate_limit_reached"}
    {rateLimits spendControlReached} null
} {
    auto_until verify
    auto_reply [limits_fixture $restored $path $value]
    check {[dict size $timers] == 0 && [llength $notices] == 1 && [llength $sent] == 3} "sparse or unchanged refreshed limits authorized continuation"
}
foreach stage {read consume verify} {
    auto_until $stage
    set pending [dict get $automatic::current opId]
    retry::server [format {{"id":%s,"error":{"code":-32601,"message":"fixture API unsupported"}}} $pending]
    check {[dict size $timers] == 0 && [llength $notices] == 1} "unsupported API was not bounded"
    auto_until $stage
    set before [llength $sent]
    fire
    check {[dict size $timers] == 0 && [llength $notices] == 1 && [llength $sent] == $before} "timeout retried an ambiguous redemption"
}

# Cancel at every asynchronous boundary; late internal replies stay hidden.
foreach stage {queued_read read queued_consume consume verify queued_continue} {
    foreach change {
        {{"method":"thread/goal/set","params":{"threadId":"t1","text":"new goal"}}}
        {{"method":"turn/interrupt","params":{"threadId":"t1","turnId":"ignored"}}}
        {{"method":"thread/resume","params":{"threadId":"other"}}}
    } {
        auto_until $stage
        set pending [field $automatic::current opId]
        set before [llength $sent]
        retry::client $change
        check {$automatic::current eq "" && [dict size $timers] == 0} "manual activity did not cancel pending recovery"
        if {$pending ne ""} { check {[auto_reply $restored $pending] == 0} "late internal reply was exposed" }
        check {[llength $sent] == $before} "late reply resumed canceled work"
    }
    foreach method {thread/settings/updated thread/goal/updated account/updated} {
        auto_until $stage
        retry::server [format {{"method":"%s","params":{"threadId":"t1"}}} $method]
        check {$automatic::current eq "" && [dict size $timers] == 0} "foreign settings or account activity did not cancel recovery"
    }
    auto_until $stage
    started foreign-live-turn
    check {$automatic::current eq "" && [dict size $timers] == 0} "foreign turn did not cancel recovery"
    auto_until $stage
    cleanup
    check {[dict size $timers] == 0} "disconnect cancellation left recovery running"
}
auto_until consume
retry::server {{"method":"account/rateLimits/updated","params":{"ordinaryUsageAllowed":true}}}
check {[field $automatic::current phase] eq "consume"} "a redemption's sparse update bypassed its response"
auto_reply {{"outcome":"reset"}}
auto_reply $restored
fire
auto_followup
auto_until queued_consume
retry::server {{"method":"account/rateLimits/updated","params":{}}}
check {$automatic::current eq "" && [dict size $timers] == 0} "a stale exhaustion snapshot consumed a credit"

# Redemption notifications may arrive on either side of its response. They
# never authorize recovery and can cause only one additional verification read.
foreach outcome {reset alreadyRedeemed} {
    foreach ordering {before_reply during_verify after_verify} {
        auto_until consume
        set consume [lindex $sent end]
        if {$ordering eq "before_reply"} {
            retry::server {{"method":"account/rateLimits/updated","params":{}}}
        }
        auto_reply [format {{"outcome":"%s"}} $outcome]
        set firstRead [dict get $automatic::current opId]
        if {$ordering eq "during_verify"} {
            retry::server {{"method":"account/rateLimits/updated","params":{}}}
            retry::server {{"method":"account/rateLimits/updated","params":{"ordinaryUsageAllowed":true}}}
        }
        auto_reply $restored
        if {$ordering eq "after_verify"} {
            retry::server {{"method":"account/rateLimits/updated","params":{}}}
        }
        if {$ordering ne "before_reply"} {
            check {[field $automatic::current phase] eq "verify" && [llength $sent] == 4} "reset update lost or duplicated verification"
            check {[auto_reply $restored $firstRead] == 0 && [llength $sent] == 4} "stale verification response advanced recovery"
            auto_reply $restored
        }
        fire
        auto_followup
        set redemptions {}
        foreach json $sent {
            if {[field [json::json2dict $json] method] eq "account/rateLimitResetCredit/consume"} { lappend redemptions $json }
        }
        check {$redemptions eq [list $consume] && $notices eq ""} "notification ordering redeemed again or prevented continuation"
    }
}
auto_until verify
retry::server {{"method":"account/rateLimits/updated","params":{}}}
auto_reply $restored
retry::server {{"method":"account/rateLimits/updated","params":{}}}
auto_reply $restored
check {$automatic::current eq "" && [dict size $timers] == 0 && [llength $sent] == 4 && \
    [llength $notices] == 1} "repeated limit changes caused unbounded verification or continuation"

foreach provider {unknown custom-provider} {
    auto_until read
    automatic::selected [huddle create model [huddle string fixture-model] modelProvider [huddle string $provider]] t1
    auto_reply $exhausted
    check {[dict size $timers] == 0 && [llength $notices] == 1} "unknown provider provenance consumed an account reset"
}
auto_until read
set conflicting [limits_fixture $exhausted rateLimitsByLimitId \
    {{"codex":{"limitId":"codex","spendControlReached":false,"rateLimitReachedType":null}}}]
auto_reply $conflicting
check {[dict size $timers] == 0 && [llength $sent] == 1} "conflicting quota views consumed a reset"
auto_until read
set alias [limits_fixture $exhausted {rateLimits limitId} {"fixture-alias"}]
set alias [limits_fixture $alias {rateLimits normalModelSlug} {"fixture-model"}]
auto_reply $alias
check {[field $automatic::current phase] eq "consume_ready"} "a confirmed matching model quota was rejected"
auto_begin 1 0
completed $autoTurn failed usageLimitExceeded {[{"type":"fileChange","id":"already-applied"}]}
fire
auto_reply $exhausted
fire
auto_reply {{"outcome":"reset"}}
auto_reply $restored
fire
auto_followup
check {[llength $sent] == 4} "partial progress blocked the neutral reset follow-up"

# Completed native stream failures share overload replay and opt-in follow-ups.
proc stream_completed {turn error {items {[]}} {thread t1} {status failed}} {
    retry::server [json::write object method [json::write string turn/completed] params \
        [json::write object threadId [json::write string $thread] turn \
            [json::write object id [json::write string $turn] status [json::write string $status] \
                items $items error $error]]]
}
set streamError {{"message":"stream disconnected before completion: stream closed before response.completed","codexErrorInfo":"other","additionalDetails":null,"misalignment":null}}
set websocketError {{"message":"stream disconnected before completion: websocket closed by server before response.completed","codexErrorInfo":"other"}}
set streamProgress {[{"type":"agentMessage","id":"partial-stream-output","text":"Neutral partial output."}]}
set streamErrors [list $streamError $websocketError]
foreach variant {responseStreamConnectionFailed responseStreamDisconnected responseTooManyFailedAttempts httpConnectionFailed} {
    foreach payload {{{}} {{"httpStatusCode":null}} {{"httpStatusCode":408}} {{"httpStatusCode":429}}
        {{"httpStatusCode":500}} {{"httpStatusCode":502}} {{"httpStatusCode":503}} {{"httpStatusCode":504}}} {
        lappend streamErrors [json::write object message [json::write string "Neutral transport failure."] \
            codexErrorInfo [json::write object $variant $payload]]
    }
}
foreach error $streamErrors {
    foreach follow {0 1} {
        foreach progressed {0 1} {
            auto_begin 0 $follow
            set items [expr {$progressed ? $streamProgress : {[]}}]
            stream_completed $autoTurn $error $items
            stream_completed $autoTurn $error $items
            set eligible [expr {!$progressed || $follow}]
            check {[dict size $timers] == $eligible && $sent eq ""} "stream recovery bypassed progress/opt-in or acted before backoff"
            if {$eligible} {
                check {[lindex $delays end] == 5000} "stream recovery skipped its initial delay"
                fire
                if {$progressed} {
                    auto_followup
                } else {
                    check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                        [huddle get $autoRequest params]]} "stream replay changed original input, attachments or settings"
                }
                check {[llength $sent] == 1} "stream failure duplicated work or consumed a reset"
                stream_completed $autoTurn $error $items
                check {[dict size $timers] == 0} "stale stream completion re-armed recovery"
            }
        }
    }
}
# Reset eligibility never grants permission to continue partial stream work.
foreach error [list $streamError $websocketError] {
    foreach follow {0 1} {
        auto_begin 1 $follow
        user_event item/started {{"type":"commandExecution","id":"stream-tool"}} $autoTurn
        stream_completed $autoTurn $error
        check {[dict size $timers] == $follow && $sent eq ""} "reset flag authorized partial stream continuation"
        if {$follow} { fire; auto_followup; check {[llength $sent] == 1} "stream recovery tried an account operation" }
    }
}

# Unknown shapes, policy/auth failures and lookalike messages stay excluded.
set rejectedStreams {}
foreach variant {responseStreamConnectionFailed responseStreamDisconnected responseTooManyFailedAttempts httpConnectionFailed} {
    lappend rejectedStreams [limits_fixture $streamError {codexErrorInfo} [json::write string $variant]]
    foreach payload {null {[]} {["httpStatusCode",503]} {"httpStatusCode 503"} 503 true
        {{"httpStatusCode":"503"}} {{"httpStatusCode":503.0}} {{"httpStatusCode":5.03e2}}
        {{"httpStatusCode":true}} {{"httpStatusCode":[]}} {{"httpStatusCode":{}}}
        {{"httpStatusCode":-503}} {{"httpStatusCode":0}} {{"httpStatusCode":400}}
        {{"httpStatusCode":401}} {{"httpStatusCode":403}} {{"httpStatusCode":404}}
        {{"httpStatusCode":409}} {{"httpStatusCode":422}} {{"httpStatusCode":501}}
        {{"httpStatusCode":65536}} {{"httpStatusCode":503,"unknown":null}} {{"message":"closed"}}} {
        lappend rejectedStreams [limits_fixture $streamError {codexErrorInfo} [json::write object $variant $payload]]
    }
}
foreach code {null {[]} {["other"]} {["serverOverloaded"]} {{"other":{}}} {{"unknown":{}}}
    {{"responseStreamDisconnected":{},"httpConnectionFailed":{}}}
    {{"responseStreamDisconnected":{},"unauthorized":{}}}
    {{"responseStreamDisconnected":{},"unknown":null}}
    {"unauthorized"} {"misalignmentPolicyViolation"} {"badRequest"} {"rateLimitExceeded"}} {
    lappend rejectedStreams [limits_fixture $streamError {codexErrorInfo} $code]
}
foreach message [list {stream closed before response.completed} \
    {websocket closed by server before response.completed} \
    {stream disconnected before completion: unknown reason} \
    {stream disconnected before completion: Stream closed before response.completed} \
    "stream disconnected before completion: stream closed before response.completed\n" \
    {stream disconnected before completion: stream closed before response.completed (401)} \
    {policy: stream disconnected before completion: stream closed before response.completed}] {
    lappend rejectedStreams [limits_fixture $streamError {message} [json::write string $message]]
}
foreach path {{message} {codexErrorInfo} {additionalDetails} {misalignment} {unknown}} {
    foreach value {null false {""} {[]} {{}} {"stream disconnected before completion: stream closed before response.completed"}} {
        if {$path in {additionalDetails misalignment} && $value eq "null"} { continue }
        if {$path eq "message" && $value eq {"stream disconnected before completion: stream closed before response.completed"}} { continue }
        lappend rejectedStreams [limits_fixture $streamError $path $value]
    }
}
foreach error $rejectedStreams {
    foreach progressed {0 1} {
        auto_begin 0 $progressed
        stream_completed $autoTurn $error [expr {$progressed ? $streamProgress : {[]}}]
        check {[dict size $timers] == 0 && $sent eq ""} "an unverified stream error triggered recovery"
    }
}
foreach code [list {"other"} {{"responseStreamDisconnected":{"httpStatusCode":503}}}] {
    foreach key {additionalDetails misalignment unknown} {
        auto_begin 0 1
        set error [limits_fixture $streamError {codexErrorInfo} $code]
        set error [limits_fixture $error $key {{"reason":"unverified"}}]
        stream_completed $autoTurn $error $streamProgress
        check {[dict size $timers] == 0 && $sent eq ""} "contradictory stream metadata authorized continuation"
    }
}
foreach follow {0 1} {
    foreach error {
        {{"message":"stream disconnected before completion: stream closed before response.completed","codexErrorInfo":"unauthorized","codexErrorInfo":"other"}}
        {{"message":"Neutral failure.","codexErrorInfo":{"responseStreamDisconnected":{"httpStatusCode":401,"httpStatusCode":503}}}}
        {{"message":"Neutral failure.","codexErrorInfo":{"responseStreamDisconnected":null,"responseStreamDisconnected":{}}}}
    } {
        auto_begin 0 $follow
        reject_duplicate {stream_completed $autoTurn $error}
        check {[dict size $timers] == 0 && $sent eq ""} "duplicate JSON keys authorized stream recovery"
    }
}
foreach code {cyberPolicy usageLimitExceeded} {
    auto_begin 0 0
    set error [limits_fixture $streamError {codexErrorInfo} [json::write string $code]]
    stream_completed $autoTurn $error
    check {[dict size $timers] == 0 && $sent eq ""} "stream prose reclassified a policy or quota failure"
}

# Native retries and terminal ACK snapshots alone cannot create wrapper work.
foreach error [list $streamError $websocketError [lindex $streamErrors end]] {
    foreach progressed {0 1} {
        foreach outcome {completed interrupted failed} {
            auto_begin 0 1
            if {$progressed} { user_event item/started {{"type":"agentMessage","id":"stream-output","text":"Neutral partial output."}} $autoTurn }
            foreach willRetry {true false} {
                retry::server [format {{"method":"error","params":{"threadId":"t1","turnId":"%s","willRetry":%s,"error":%s}}} $autoTurn $willRetry $error]
                check {[dict size $timers] == 0 && $sent eq ""} "native retry notification scheduled wrapper work"
            }
            stream_completed $autoTurn $error {[]} t1 $outcome
            check {[dict size $timers] == ($outcome eq "failed")} "native completion status did not control recovery"
        }
        auto_begin 0 1 0
        started $autoTurn
        stream_completed $autoTurn $error [expr {$progressed ? $streamProgress : {[]}}]
        check {[dict size $timers] == 0} "stream completion acknowledged its own start"
        reply $autoId $autoTurn
        check {[dict size $timers] == 1 && [lindex $delays end] == 5000} "early stream failure lost ACK correlation"
        fire
        if {$progressed} { auto_followup }
    }
    auto_begin 0 1 0
    retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","status":"failed","items":[],"error":%s}}}} $autoId $autoTurn $error]
    check {[dict size $timers] == 0 && $sent eq ""} "terminal start reply replaced turn/completed"
    auto_begin 0 1 0
    started $autoTurn
    stream_completed $autoTurn $error $streamProgress
    reply $autoId foreign-stream-turn
    check {[dict size $timers] == 0 && $sent eq ""} "mismatched ACK claimed stream failure"
}
# A status-less start ACK still needs the matching completed failure.
foreach error [list $streamError $websocketError [lindex $streamErrors end]] {
    foreach order {ack-first completion-first} {
        auto_begin 0 0 0
        if {$order eq "completion-first"} { stream_completed $autoTurn $error }
        check {[dict size $timers] == 0} "stream failure acted before its ACK"
        retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","items":[]}}}} $autoId $autoTurn]
        if {$order eq "ack-first"} {
            check {[dict size $timers] == 0} "a status-less ACK replaced turn/completed"
            stream_completed $autoTurn $error
        }
        check {[dict size $timers] == 1 && $sent eq ""} "a status-less ACK lost correlated stream recovery"
        fire
        check {[llength $sent] == 1 && [huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
            [huddle get $autoRequest params]]} "a status-less ACK changed stream replay input or settings"
    }
}
foreach acknowledgement {
    {"result":{"turn":{"id":["@TURN@"],"status":"inProgress","items":[]}}}
    {"result":{"turn":{"id":"@TURN@","status":["inProgress"],"items":[]}}}
    {"result":{"turn":{"id":"@TURN@","status":null,"items":[]}}}
    {"result":{"turn":{"id":"@TURN@","status":"unknown","items":[]}}}
    {"result":{"turn":{"id":"@TURN@","status":1,"items":[]}}}
    {"result":{"turn":{"id":"@TURN@","status":{},"items":[]}}}
    {"result":{"turn":{"id":"@TURN@","status":"inProgress","items":[]}},"method":null}
} {
    auto_begin 0 0 0
    set fields [string map [list @TURN@ $autoTurn] $acknowledgement]
    retry::server [format {{"id":%s,%s}} $autoId $fields]
    stream_completed $autoTurn $streamError
    check {[dict size $timers] == 0 && $sent eq ""} "ambiguous ACK authorized default stream replay"
}
auto_begin 0 0 0
reject_duplicate {retry::server [format {{"id":%s,"result":{"turn":{"id":"wrong","id":"%s","status":"inProgress","items":[]}}}} $autoId $autoTurn]}
stream_completed $autoTurn $streamError
check {[dict size $timers] == 0 && $sent eq ""} "duplicate ACK authorized stream replay"
foreach {path value} {
    method {["turn/start"]}
    id {[7]}
    {params threadId} {["t1"]}
    {params input} {"request"}
} {
    automatic::cancel
    retry::reset
    set automatic::flags {auto_reset_limit 0 auto_continue_after_stop 0}
    set automatic::live {}
    set sent {}
    retry::client [limits_fixture $request $path $value]
    reply 7 turn1
    stream_completed turn1 $streamError
    check {[dict size $timers] == 0 && $sent eq ""} "ambiguous request authorized stream replay"
}
foreach follow {0 1} {
    foreach {path value} {
        method {["turn/completed"]}
        {params threadId} {["t1"]}
        {params turn id} {["@TURN@"]}
        {params turn status} {["failed"]}
    } {
        auto_begin 0 $follow
        set event [format {{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"%s","status":"failed","items":[],"error":%s}}}} $autoTurn $streamError]
        retry::server [limits_fixture $event $path [string map [list @TURN@ $autoTurn] $value]]
        check {[dict size $timers] == 0 && $sent eq ""} "ambiguous completion authorized stream recovery"
    }
}

# One timer retains exponential backoff across overload/stream and replay/continue.
auto_begin 0 1
set turn $autoTurn
set index 0
foreach delay {5000 10000 20000 40000 80000 160000 320000 640000 1280000 1800000 1800000} {
    set error [lindex [list $streamError {{"message":"Neutral overload.","codexErrorInfo":"serverOverloaded"}} \
        [lindex $streamErrors end] $websocketError] [expr {$index % 4}]]
    set items [expr {$index % 2 ? $streamProgress : {[]}}]
    stream_completed $turn $error $items
    stream_completed $turn $error $items
    check {[dict size $timers] == 1 && [lindex $delays end] == $delay} "mixed transport recovery reset backoff or duplicated its timer"
    set original [huddle get [dict get $retry::current request] params]
    fire
    if {$index % 2} {
        set id [auto_followup]
    } else {
        set replay [::huddle::json2huddle [lindex $sent end]]
        check {[huddle equal [huddle get $replay params] $original]} "mixed failure replay changed effective input/settings"
        set id [json_dump [huddle get $replay id]]
    }
    stream_completed $turn $error $items
    check {[dict size $timers] == 0} "mixed chain accepted a duplicate failure"
    set turn mixed-stream-[incr index]-$autoSequence
    reply $id $turn
    started $turn
}
completed $turn completed
check {$retry::delay == 5000 && [dict size $timers] == 0} "success did not reset mixed transport backoff"

foreach progressed {0 1} {
    foreach {side event} {
        client {{"method":"turn/interrupt","params":{"threadId":"t1","turnId":"ignored"}}}
        client {{"id":510,"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"Fresh manual work."}]}}}
        client {{"method":"thread/resume","params":{"threadId":"another-thread"}}}
        client {{"method":"thread/settings/update","params":{"threadId":"t1","model":"different"}}}
        client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}}
        client {{"method":"account/logout","params":{}}}
        server {{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"foreign-stream-work","status":"inProgress","items":[]}}}}
    } {
        auto_begin 0 1
        stream_completed $autoTurn $streamError [expr {$progressed ? $streamProgress : {[]}}]
        set callback [lindex [dict values $timers] 0]
        retry::$side $event
        uplevel #0 $callback
        stream_completed $autoTurn $streamError
        check {[dict size $timers] == 0 && $sent eq "" && $retry::delay == 5000} "manual change failed to cancel stream recovery"
    }
}

# Ownership, order and types are required even when progress is otherwise allowed.
foreach ack {0 1} {
    auto_begin 1 1 $ack
    if {!$ack} { started $autoTurn }
    completed $autoTurn failed cyberPolicy
    if {!$ack} { check {[dict size $timers] == 0} "a terminal event acknowledged work" }
    if {!$ack} { reply $autoId $autoTurn }
    check {[dict size $timers] == 1} "a confirmed reordered terminal event lost recovery"
    check {![dict exists $automatic::live t1]} "a terminal acknowledgement restored a live-turn guard"
}
auto_begin 1 1 0
completed $autoTurn failed cyberPolicy
reply $autoId $autoTurn
check {[dict size $timers] == 0} "a completion without a confirmed start candidate triggered recovery"
auto_begin 1 1 0
started $autoTurn
reply $autoId $autoTurn
completed $autoTurn failed cyberPolicy
check {[dict size $timers] == 1} "a correlated early start lost valid ownership"
foreach code {{["cyberPolicy"]} {null} {{"cyberPolicy":{}}}} {
    auto_begin 1 1
    retry::server [format {{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"%s","status":"failed","items":[],"error":{"message":"neutral","codexErrorInfo":%s}}}}} $autoTurn $code]
    check {[dict size $timers] == 0} "a malformed error code triggered recovery"
}
auto_begin 1 1 0
reject_duplicate {retry::server [format {{"id":"unrelated","result":{"turn":{"id":"%s","status":"inProgress","items":[]}},"id":%s}} $autoTurn $autoId]}
completed $autoTurn failed cyberPolicy
check {[dict size $timers] == 0} "an ambiguous duplicate envelope acknowledged work"
auto_until read
reject_duplicate {auto_reply [string map [list {"availableCount":1} {"availableCount":0,"availableCount":1}] $exhausted]}
check {[dict size $timers] == 0 && [llength $sent] == 1} "duplicate credit fields consumed a reset"
foreach item {
    {{"type":"userMessage","id":"foreign","content":[{"type":"text","text":"different input"}]}}
    {{"type":"userMessage","id":"foreign","content":"not an array"}}
} {
    auto_begin 1 1
    user_event item/completed $item $autoTurn
    completed $autoTurn failed cyberPolicy
    check {[dict size $timers] == 0} "same-turn foreign input allowed recovery"
}
auto_begin 1 1 0
reply 99999 foreign-response
completed $autoTurn failed usageLimitExceeded
reply $autoId $autoTurn
check {[dict size $timers] == 0} "a foreign response established ownership"
auto_begin 1 1
started preexisting-foreign
huddle set autoRequest id [huddle string manual-steering-foreign]
retry::client [json_dump $autoRequest]
reply {"manual-steering-foreign"} preexisting-foreign
completed preexisting-foreign failed cyberPolicy
check {[dict size $timers] == 0 && $automatic::current eq ""} "steering an existing foreign turn established ownership"

# Resume snapshots can expose running turns without turn/started delivery,
# including paginated history or only an active thread status.
proc auto_resume {source} {
    auto_begin 1 1
    set ::foreignTurn resumed-foreign-$::autoSequence
    set turns [format {[{"id":"%s","status":"inProgress","items":[]}]} $::foreignTurn]
    set page null
    if {$source eq "page"} { set page [format {{"data":%s}} $turns]; set turns {[]} }
    if {$source eq "status"} { set turns {[]} }
    set id [json::write string activation-$::autoSequence]
    set request [format {{"id":%s,"method":"thread/resume","params":{"threadId":"t1"}}} $id]
    recovery::client $request
    retry::client $request
    retry::server [format {{"id":%s,"result":{"thread":{"id":"t1","status":{"type":"active","activeFlags":[]},"turns":%s,"ephemeral":%s},"model":"fixture-model","modelProvider":"openai","initialTurnsPage":%s}}} $id $turns [expr {$source eq "ephemeral" ? "true" : "false"}] $page]
}
proc thread_status {status {thread t1}} {
    set state [huddle create type [huddle string $status]]
    if {$status eq "active"} { huddle set state activeFlags [huddle list] }
    retry::server [json_dump [huddle create method [huddle string thread/status/changed] \
        params [huddle create threadId [huddle string $thread] status $state]]]
}
foreach source {history page status ephemeral} {
    foreach code {cyberPolicy usageLimitExceeded} {
        auto_resume $source
        set id [json::write string steer-resumed-$autoSequence]
        huddle set autoRequest id [::huddle::json2huddle $id]
        retry::client [json_dump $autoRequest]
        reply $id $foreignTurn
        completed $foreignTurn failed $code
        check {$automatic::current eq "" && [dict size $timers] == 0 && $sent eq ""} "resumed foreign work was claimed as a new manual chain"
        if {$source eq "status"} { thread_status idle }
        set id [json::write string new-after-resume-$autoSequence]
        huddle set autoRequest id [::huddle::json2huddle $id]
        retry::client [json_dump $autoRequest]
        reply $id fresh-after-resume-$autoSequence
        completed fresh-after-resume-$autoSequence failed cyberPolicy
        fire
        auto_followup
    }
}
foreach stage {queued_read read queued_consume consume verify queued_continue} {
    auto_until $stage
    thread_status active
    check {$automatic::current eq "" && [dict size $timers] == 0} "active foreign status left queued recovery eligible"
}
auto_begin 1 1 0
thread_status active
started $autoTurn
reply $autoId $autoTurn
thread_status active
completed $autoTurn failed cyberPolicy
thread_status active other-thread
check {[dict size $timers] == 1} "our running status or an unrelated thread canceled confirmed work"
fire
auto_followup

# Context invalidation must also remove an overload timer for a continuation.
proc auto_backoff {{echo 0}} {
    auto_begin 1 1
    completed $::autoTurn failed cyberPolicy
    fire
    set id [auto_followup]
    set ::continuationTurn continuation-$::autoSequence
    reply $id $::continuationTurn
    started $::continuationTurn
    set params [huddle get [dict get $::automatic::current request] params]
    set ::continuationUser [huddle create type [huddle string userMessage] \
        id [huddle string continuation-user-$::autoSequence] \
        clientId [huddle get $params clientUserMessageId] content [huddle get $params input]]
    if {$echo} { user_event item/started [json_dump $::continuationUser] $::continuationTurn }
    completed $::continuationTurn failed serverOverloaded
    check {[dict size $::timers] == 1} "continuation overload did not enter backoff"
}

# A verified identical echo is neither new input nor progress during backoff.
foreach method {item/started item/completed} {
    auto_backoff 1
    set pending $timers
    user_event $method [json_dump $continuationUser] $continuationTurn
    check {$timers eq $pending && [field $automatic::current phase] eq "overload"} "duplicate user echo canceled continuation backoff"
    fire
    set id [auto_followup]
    reply $id replayed-echo-$autoSequence
    completed replayed-echo-$autoSequence failed cyberPolicy
    check {[dict size $timers] == 1 && [llength $notices] == 0} "overload replay blocked a later content stop"
    fire
    auto_followup
}
foreach change {input identity client unverified progress} {
    auto_backoff [expr {$change ne "unverified"}]
    set item $continuationUser
    switch -- $change {
        input { huddle set item content 0 text [huddle string {changed fixture input}] }
        identity { huddle set item id [huddle string different-user] }
        client { huddle set item clientId [huddle string different-client] }
        progress { set item [huddle create type [huddle string commandExecution] id [huddle string tool-progress]] }
    }
    user_event item/completed [json_dump $item] $continuationTurn
    check {$automatic::current eq "" && [dict size $timers] == 0 && [llength $sent] == 1} "new input or progress survived continuation backoff"
}
auto_begin 1 1
user_event item/started {} $autoTurn
completed $autoTurn failed cyberPolicy
user_event item/completed {} $autoTurn
fire
auto_followup

# Repeated terminal snapshots still have to prove input ownership.
foreach phase {stop limit overload} {
    foreach change {same input identity additional unverified client} {
        if {$change eq "client" && $phase ne "overload"} { continue }
        if {$phase eq "overload"} {
            auto_backoff [expr {$change ne "unverified"}]
            set turn $continuationTurn
            set original $continuationUser
            set code serverOverloaded
        } else {
            auto_begin 1 1
            if {$change ne "unverified"} { user_event item/started {} $autoTurn }
            set turn $autoTurn
            set original [::huddle::json2huddle $userItem]
            set code [expr {$phase eq "stop" ? "cyberPolicy" : "usageLimitExceeded"}]
            completed $turn failed $code
        }
        set pending $timers
        set dispatched $sent
        set item $original
        switch -- $change {
            input { huddle set item content 0 text [huddle string {changed fixture input}] }
            identity - additional { huddle set item id [huddle string additional-user] }
            client { huddle set item clientId [huddle string different-client] }
        }
        set items [json::write array [json_dump $item]]
        if {$change eq "additional"} { set items [json::write array [json_dump $original] [json_dump $item]] }
        completed $turn failed $code $items
        if {$change eq "same"} {
            check {$timers eq $pending && $sent eq $dispatched} "identical terminal snapshot replaced the pending action"
            fire
            if {$phase eq "limit"} {
                check {[field [json::json2dict [lindex $sent end]] method] eq "account/rateLimits/read"} "identical terminal snapshot lost reset recovery"
            } else {
                set id [auto_followup]
                reply $id snapshot-followup-$autoSequence
                completed snapshot-followup-$autoSequence failed cyberPolicy
                check {[dict size $timers] == 1 && [llength $notices] == 0} "a distinct follow-up stop lost recovery eligibility"
                fire
                auto_followup
            }
        } else {
            check {$automatic::current eq "" && [dict size $timers] == 0 && $sent eq $dispatched} "conflicting terminal snapshot left recovery armed"
        }
    }
}

foreach event {
    {{"method":"account/updated","params":{}}}
    {{"method":"account/gatewayOAuth/changed","params":{}}}
    {{"method":"thread/settings/updated","params":{"threadId":"t1","threadSettings":{"modelProvider":"other-provider"}}}}
    {{"method":"model/rerouted","params":{"threadId":"t1","turnId":"ignored","toModel":"other-model"}}}
} {
    auto_backoff
    retry::server $event
    completed $continuationTurn failed serverOverloaded
    check {$automatic::current eq "" && $retry::current eq "" && [dict size $timers] == 0 && \
        [llength $sent] == 1} "context invalidation left a continuation replay armed"
}
foreach invalidatingRequest {
    {{"method":"account/logout","params":{}}}
    {{"method":"thread/settings/update","params":{"threadId":"t1","model":"other-model"}}}
} {
    auto_backoff
    retry::client $invalidatingRequest
    check {$retry::current eq "" && [dict size $timers] == 0} "manual context change left continuation backoff active"
}

# Account/auth changes invalidate original-input replay independently of flags.
# Reads and quota notifications preserve its ownership, timer and backoff.
foreach reset {0 1} {
    foreach follow {0 1} {
        foreach {side method cancel} {
            client account/logout 1
            client account/login/start 1
            client account/login/cancel 1
            client modelProvider/auth/set 1
            client modelProvider/auth/clear 1
            server account/updated 1
            server account/gatewayOAuth/changed 1
            client account/read 0
            client account/rateLimits/read 0
            client account/usage/read 0
            client account/workspaceMessages/read 0
            client account/gatewayOAuth/read 0
            server account/rateLimits/updated 0
        } {
            foreach stage {running before_ack backoff} {
                auto_begin $reset $follow [expr {$stage ne "before_ack"}]
                if {$stage eq "before_ack"} { started $autoTurn }
                if {$stage ne "running"} { completed $autoTurn failed serverOverloaded }
                set previous [list $automatic::current $retry::current $retry::delay $timers]
                retry::$side [json_dump [huddle create method [huddle string $method] params [huddle create]]]
                if {$cancel} {
                    check {$automatic::current eq "" && $retry::current eq "" && [dict size $timers] == 0} "account/auth change left original-input recovery armed ($method/$stage)"
                    reply $autoId $autoTurn
                    completed $autoTurn failed serverOverloaded
                    retry::fire
                    check {$retry::current eq "" && [dict size $timers] == 0 && $sent eq ""} "late protocol data or dispatch replayed canceled account/auth work"
                } else {
                    check {[list $automatic::current $retry::current $retry::delay $timers] eq $previous} "account metadata changed overload tracking or backoff"
                    if {$stage eq "before_ack"} { reply $autoId $autoTurn }
                    if {$stage eq "running"} { completed $autoTurn failed serverOverloaded }
                    fire
                    check {[llength $sent] == 1 && [huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                        [huddle get $autoRequest params]]} "account metadata changed original input/settings on replay"
                }
            }
        }
    }
}

# Manual turn/start can steer a live continuation. Sparse later snapshots
# cannot erase progress already observed before canceling its automatic chain.
proc auto_progress {{startEvent 1}} {
    auto_begin 1 1
    completed $::autoTurn failed cyberPolicy
    fire
    set id [auto_followup]
    set ::continuationTurn running-continuation-$::autoSequence
    reply $id $::continuationTurn
    if {$startEvent} { started $::continuationTurn }
    user_event item/started {{"type":"commandExecution","id":"applied-tool"}} $::continuationTurn
    check {[field $::retry::current progress] eq "1"} "tool progress was not observed before steering"
}
foreach startEvent {0 1} {
    foreach invalidation {
        {}
        {{"method":"account/updated","params":{}}}
        {{"method":"thread/settings/updated","params":{"threadId":"t1","threadSettings":{"modelProvider":"other-provider"}}}}
    } {
        foreach acknowledgement {same_turn different_turn} {
            auto_progress $startEvent
            if {$invalidation ne ""} {
                retry::server $invalidation
                check {$retry::current eq "" && [field $automatic::live t1] eq $continuationTurn} "context invalidation lost the live-turn guard"
            }
            set id [huddle string manual-steering-$autoSequence]
            set steering [huddle create id $id method [huddle string turn/start] params [huddle create \
                threadId [huddle string t1] input [huddle list [huddle create type [huddle string text] \
                    text [huddle string {additional fixture input}]]]]]
            retry::client [json_dump $steering]
            check {$automatic::current eq "" && [field $retry::current progress] eq "1" && \
                [field $retry::current previous] eq $continuationTurn} "steering erased the live continuation replay guard"
            set acknowledged $continuationTurn
            if {$acknowledgement eq "different_turn"} { set acknowledged replacement-$autoSequence }
            reply [json_dump $id] $acknowledged
            completed $acknowledged failed serverOverloaded
            check {[dict size $timers] == 0 && [llength $sent] == 1} "sparse steering snapshots allowed replay after tool progress"
        }
        # A real new turn on another thread or after completion keeps normal replay.
        foreach boundary {other_thread completed_turn} {
            auto_progress $startEvent
            if {$invalidation ne ""} { retry::server $invalidation }
            set thread t2
            if {$boundary eq "completed_turn"} {
                completed $continuationTurn failed serverOverloaded
                set thread t1
            }
            set id [huddle string fresh-manual-$autoSequence]
            set fresh [huddle create id $id method [huddle string turn/start] params [huddle create \
                threadId [huddle string $thread] input [huddle list [huddle create type [huddle string text] \
                    text [huddle string {fresh fixture input}]]]]]
            retry::client [json_dump $fresh]
            reply [json_dump $id] fresh-turn-$autoSequence
            completed fresh-turn-$autoSequence failed serverOverloaded {[]} $thread
            fire
            check {[llength $sent] == 2 && [huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                [huddle get $fresh params]]} "steering protection changed replay for a fresh manual turn"
        }
    }
}

# Strictly rejected activation/settings data cannot establish reset provenance
# or seed activity snapshots. A later valid authoritative update can restore it.
proc auto_activation {providers {active 0}} {
    set id [json::write string provenance-activation-[incr ::autoSequence]]
    set activation [format {{"id":%s,"method":"thread/resume","params":{"threadId":"t1"}}} $id]
    recovery::client $activation
    retry::client $activation
    set status {{"type":"idle"}}
    set turns {[]}
    if {$active} {
        set status {{"type":"active","activeFlags":[]}}
        set turns {[{"id":"rejected-foreign-turn","status":"inProgress","items":[]}]}
    }
    retry::server [format {{"id":%s,"result":{"thread":{"id":"t1","status":%s,"turns":%s},"model":"fixture-model",%s}}} \
        $id $status $turns $providers]
}
foreach source {activation settings} {
    foreach repaired {0 1} {
        auto_begin 1 0
        completed $autoTurn completed
        if {$source eq "activation"} {
            reject_duplicate {auto_activation {"modelProvider":"other-provider","modelProvider":"openai"} 1}
        } else {
            auto_activation {"modelProvider":"openai"}
            reject_duplicate {retry::server {{"method":"thread/settings/updated","params":{"threadId":"t1","threadSettings":{"modelProvider":"other-provider","modelProvider":"openai"}}}}}
        }
        check {$automatic::selection eq ""} "rejected protocol data established automatic provenance"
        check {![dict exists $automatic::live t1]} "rejected activation data seeded a live-turn snapshot"
        if {$repaired} {
            if {$source eq "activation"} {
                auto_activation {"modelProvider":"openai"}
            } else {
                retry::server {{"method":"thread/settings/updated","params":{"threadId":"t1","threadSettings":{"model":"fixture-model","modelProvider":"openai"}}}}
            }
        }
        set id [huddle string provenance-manual-[incr autoSequence]]
        huddle set autoRequest id $id
        retry::client [json_dump $autoRequest]
        set turn provenance-turn-$autoSequence
        reply [json_dump $id] $turn
        started $turn
        completed $turn failed usageLimitExceeded
        fire
        auto_reply $exhausted
        if {$repaired} {
            fire
            check {[field [json::json2dict [lindex $sent end]] method] eq "account/rateLimitResetCredit/consume"} "valid authoritative data did not restore reset eligibility"
        } else {
            check {$automatic::current eq "" && [dict size $timers] == 0 && \
                [llength $sent] == 1 && [llength $notices] == 1} "rejected provenance authorized reset redemption"
        }
    }
}

# Goal accounting and automatic stalls must preserve owned overload recovery.
set goalSequence 0
proc goal_fixture {{status active}} {
    return [huddle create threadId [huddle string t1] objective [huddle string "fixture goal"] \
        status [huddle string $status] createdAt [huddle number 1] updatedAt [huddle number 2] \
        tokensUsed [huddle number 12] timeUsedSeconds [huddle number 1] tokenBudget [huddle null]]
}
proc goal_read_request_fixture {} {
    set id [huddle string goal-read-[incr ::goalSequence]]
    retry::client [json_dump [huddle create id $id method [huddle string thread/goal/get] \
        params [huddle create threadId [huddle string t1]]]]
    return $id
}
proc goal_read_fixture {{goal ""}} {
    if {$goal eq ""} { set goal [goal_fixture] }
    set id [goal_read_request_fixture]
    check {[retry::server [json_dump [huddle create id $id result [huddle create goal $goal]]]] == 1} \
        "native goal read reply was hidden"
    return $id
}
proc goal_event {goal turn} {
    return [json_dump [huddle create method [huddle string thread/goal/updated] \
        params [huddle create threadId [huddle string t1] turnId $turn goal $goal]]]
}
foreach follow {0 1} {
    foreach progress {0 1} {
        foreach ordering {before_failure after_failure} {
            auto_begin 0 $follow
            goal_read_fixture
            if {$progress} {
                user_event item/started {{"type":"commandExecution","id":"goal-progress"}} $autoTurn
            }
            if {$ordering eq "before_failure"} {
                retry::server [goal_event [goal_fixture] [huddle string $autoTurn]]
            }
            completed $autoTurn
            if {$ordering eq "after_failure"} {
                retry::server [goal_event [goal_fixture blocked] [huddle string $autoTurn]]
            }
            set expected [expr {!$progress || $follow}]
            check {[dict size $timers] == $expected && $sent eq ""} \
                "owned goal metadata canceled overload recovery or bypassed its opt-in"
            if {$expected} {
                check {[lindex $delays end] == 5000} "goal accounting changed overload backoff"
                fire
                if {$progress} {
                    auto_followup
                } else {
                    check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                        [huddle get $autoRequest params]]} "goal accounting changed original-input replay"
                }
                check {[llength $sent] == 1} "goal accounting duplicated model work"
            }
        }
    }
}
foreach ordering {before_failure after_failure} {
    auto_begin 0 1
    goal_read_fixture
    user_event item/started {{"type":"commandExecution","id":"automatic-goal-progress"}} $autoTurn
    if {$ordering eq "after_failure"} { completed $autoTurn }
    set id [huddle string goal-stall-[incr goalSequence]]
    retry::client [json_dump [huddle create id $id method [huddle string thread/goal/set] \
        params [huddle create threadId [huddle string t1] origin [huddle string automatic] \
            status [huddle string blocked] objective [huddle null] tokenBudget [huddle null]]]]
    set goal [goal_fixture blocked]
    check {[retry::server [json_dump [huddle create id $id result [huddle create goal $goal]]]] == 1} \
        "native automatic goal acknowledgement was hidden"
    retry::server [goal_event $goal [huddle null]]
    retry::server [goal_event $goal [huddle null]]
    if {$ordering eq "before_failure"} { completed $autoTurn }
    check {[dict size $timers] == 1 && $sent eq "" && [lindex $delays end] == 5000} \
        "verified native automatic goal stall canceled overload continuation"
    fire
    auto_followup
    check {[llength $sent] == 1} "automatic goal metadata duplicated continuation"
}

# A baseline read before manual work survives activation and retry resets.
automatic::cancel
retry::reset
recovery::client {{"id":"goal-activation","method":"thread/resume","params":{"threadId":"t1"}}}
retry::client {{"id":"goal-activation","method":"thread/resume","params":{"threadId":"t1"}}}
retry::server {{"id":"goal-activation","result":{"thread":{"id":"t1","status":{"type":"idle"}},"model":"fixture-model","modelProvider":"openai"}}}
goal_read_fixture
auto_begin 1 1
retry::server [goal_event [goal_fixture blocked] [huddle string $autoTurn]]
completed $autoTurn
check {[dict size $timers] == 1 && $sent eq ""} "activation-time goal baseline was lost on manual work"
fire
check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
    [huddle get $autoRequest params]]} "activation goal accounting changed input or settings"

proc goal_set_fixture {} {
    return [huddle create id [huddle string goal-set-[incr ::goalSequence]] \
        method [huddle string thread/goal/set] params [huddle create threadId [huddle string t1] \
            origin [huddle string automatic] status [huddle string blocked] \
            objective [huddle null] tokenBudget [huddle null]]]
}
proc goal_ack_fixture {request {goal ""}} {
    if {$goal eq ""} { set goal [goal_fixture blocked] }
    check {[retry::server [json_dump [huddle create result [huddle create goal $goal] \
        id [huddle get $request id]]]] == 1} "native goal acknowledgement was hidden or misrouted"
}
proc goal_failure_fixture {{progress 1} {follow 1}} {
    auto_begin 0 $follow
    goal_read_fixture
    if {$progress} { user_event item/started {{"type":"commandExecution","id":"goal-tool"}} $::autoTurn }
    completed $::autoTurn
}
proc goal_canceled_fixture {message} {
    completed $::autoTurn
    retry::fire
    automatic::advance
    check {[dict size $::timers] == 0 && $::sent eq ""} $message
}

# Accounting may advance, and the native optional budget may be omitted.
auto_begin 0 0
set goal [huddle remove [goal_fixture] tokenBudget]
goal_read_fixture $goal
huddle set goal updatedAt [huddle number 3]
huddle set goal tokensUsed [huddle number 20]
huddle set goal timeUsedSeconds [huddle number 2]
retry::server [goal_event $goal [huddle string $autoTurn]]
completed $autoTurn
check {[dict size $timers] == 1} "owned goal accounting canceled default overload replay"
fire
check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
    [huddle get $autoRequest params]]} "goal accounting changed original-input replay"
retry::client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}}

# Neither foreign read replies nor metadata alone establish a baseline or turn.
foreach source {missing foreign_id typed_id} {
    retry::client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}}
    auto_begin 0 1
    set readId [huddle number [incr goalSequence]]
    retry::client [json_dump [huddle create id $readId method [huddle string thread/goal/get] \
        params [huddle create threadId [huddle string t1]]]]
    if {$source ne "missing"} {
        set responseId [huddle string [huddle get_stripped $readId]]
        if {$source eq "foreign_id"} { set responseId [huddle string foreign-goal-read] }
        retry::server [json_dump [huddle create id $responseId result [huddle create goal [goal_fixture]]]]
    }
    completed $autoTurn
    retry::server [goal_event [goal_fixture blocked] [huddle string $autoTurn]]
    goal_canceled_fixture "unverified read reply established a goal baseline"
}

# Native automatic stalls preserve either replay or opt-in continuation.
foreach follow {0 1} {
    foreach progress {0 1} {
        goal_failure_fixture $progress $follow
        set goalRequest [goal_set_fixture]
        retry::client [json_dump $goalRequest]
        goal_ack_fixture $goalRequest
        retry::server [goal_event [goal_fixture blocked] [huddle null]]
        check {[dict size $timers] == (!$progress || $follow) && $sent eq ""} \
            "automatic goal metadata bypassed flags or lost safe replay"
        if {[dict size $timers]} {
            fire
            if {$progress} { auto_followup } else {
                check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                    [huddle get $autoRequest params]]} "automatic stall replayed different input or settings"
            }
            check {[llength $sent] == 1} "automatic stall duplicated recovery"
        }
    }
}

# Goal metadata cannot replace the acknowledgement of the model request.
foreach source {correlated native} {
    auto_begin 0 1 0
    goal_read_fixture
    started $autoTurn
    user_event item/started {{"type":"commandExecution","id":"early-goal-tool"}} $autoTurn
    if {$source eq "native"} {
        set goalRequest [goal_set_fixture]
        retry::client [json_dump $goalRequest]
        goal_ack_fixture $goalRequest
        retry::server [goal_event [goal_fixture blocked] [huddle null]]
    } else { retry::server [goal_event [goal_fixture blocked] [huddle string $autoTurn]] }
    completed $autoTurn
    check {[dict size $timers] == 0 && $sent eq ""} "goal metadata acknowledged model work"
    reply {"foreign-goal-ack"} $autoTurn
    check {[dict size $timers] == 0} "foreign reply acknowledged goal-preserved work"
    reply $autoId $autoTurn
    check {[dict size $timers] == 1} "early goal metadata lost acknowledged overload recovery"
    fire
    auto_followup
}

# Both native numeric and string IDs acknowledge metadata without changing type.
foreach type {number string} {
    goal_failure_fixture
    set goalRequest [goal_set_fixture]
    huddle set goalRequest id [huddle $type [incr goalSequence]]
    retry::client [json_dump $goalRequest]
    goal_ack_fixture $goalRequest
    # A same-goal read between the acknowledgement and notification is harmless.
    goal_read_fixture [goal_fixture blocked]
    retry::server [goal_event [goal_fixture blocked] [huddle string $autoTurn]]
    retry::server [goal_event [goal_fixture blocked] [huddle null]]
    check {[dict size $timers] == 1} "typed goal ID or harmless read lost automatic stall recovery"
    fire
    auto_followup
}

# A rejected read stays metadata, but cannot supply a goal preservation baseline.
goal_failure_fixture
set readId [huddle string rejected-goal-read]
retry::client [json_dump [huddle create id $readId method [huddle string thread/goal/get] \
    params [huddle create threadId [huddle string t1]]]]
retry::server [json_dump [huddle create id $readId error [huddle create \
    code [huddle number -32601] message [huddle string unavailable]]]]
check {[dict size $timers] == 1} "rejected metadata read canceled an independently eligible failure"
retry::server [goal_event [goal_fixture blocked] [huddle string $autoTurn]]
goal_canceled_fixture "rejected read authorized goal preservation"

# Correlated goal reads report terminal stops before or after overload completes.
foreach progress {0 1} {
    foreach status {paused usageLimited budgetLimited complete} {
        foreach ordering {before_failure after_failure} {
            auto_begin 0 1
            goal_read_fixture
            if {$progress} { user_event item/started {{"type":"commandExecution","id":"goal-read-stop-tool"}} $autoTurn }
            if {$ordering eq "after_failure"} { completed $autoTurn }
            goal_read_fixture [goal_fixture $status]
            goal_canceled_fixture "terminal goal read allowed overload recovery"
        }
    }
}

# A completed goal observed before fresh manual work is historical metadata.
# Refreshing that unchanged goal must not cancel a different manually started task.
proc historical_goal_fixture {{follow 1} {acknowledge 1} {reset 0} {client ""}} {
    automatic::cancel
    retry::reset
    goal::forget 1
    set ::automatic::live {}
    goal_read_fixture [goal_fixture complete]
    auto_begin $reset $follow $acknowledge $client
}
foreach follow {0 1} {
    foreach progress {0 1} {
        foreach ordering {before_failure after_failure} {
            historical_goal_fixture $follow
            if {$progress} {
                user_event item/started {{"type":"commandExecution","id":"historical-goal-tool"}} $autoTurn
            }
            if {$ordering eq "after_failure"} { completed $autoTurn }
            set previous [list $retry::current $automatic::current $retry::delay $timers $delays]
            goal_read_fixture [goal_fixture complete]
            goal_read_fixture [goal_fixture complete]
            check {[list $retry::current $automatic::current $retry::delay $timers $delays] eq $previous} \
                "historical goal refresh changed ownership, timer or accumulated backoff"
            if {$ordering eq "before_failure"} { completed $autoTurn }
            set expected [expr {!$progress || $follow}]
            check {[dict size $timers] == $expected && $sent eq ""} \
                "refreshing a historical completed goal canceled fresh overload recovery"
            if {$expected} {
                check {[lindex $delays end] == 5000} "historical goal refresh changed backoff"
                fire
                if {$progress} {
                    auto_followup
                } else {
                    check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                        [huddle get $autoRequest params]]} "historical goal refresh changed replay input"
                }
                check {[llength $sent] == 1} "historical goal refresh duplicated work"
            }
        }
    }
}

# Historical reads before acknowledgement cannot acknowledge or complete work.
foreach progress {0 1} {
    foreach ordering {before_failure after_failure} {
        historical_goal_fixture 1 0
        started $autoTurn
        if {$progress} { user_event item/started {{"type":"commandExecution","id":"historical-early-tool"}} $autoTurn }
        if {$ordering eq "after_failure"} { completed $autoTurn }
        goal_read_fixture [goal_fixture complete]
        check {[dict size $timers] == 0 && $sent eq ""} "historical metadata acknowledged model work"
        if {$ordering eq "before_failure"} { completed $autoTurn }
        reply {"foreign-historical-ack"} $autoTurn
        check {[dict size $timers] == 0} "foreign reply acknowledged historical-goal work"
        reply $autoId $autoTurn
        check {[dict size $timers] == 1} "historical refresh lost recovery after the real acknowledgement"
        fire
        if {$progress} { auto_followup }
        check {[llength $sent] == 1} "early historical metadata duplicated work"
    }
}

# Recovery chains keep their one exponential timer across exact historical reads.
foreach progress {0 1} {
    historical_goal_fixture
    set turn $autoTurn
    foreach delay {5000 10000 20000} {
        if {$progress} { user_event item/started {{"type":"commandExecution","id":"historical-chain-tool"}} $turn }
        completed $turn
        set previous [list $timers $delays $retry::delay]
        goal_read_fixture [goal_fixture complete]
        completed $turn
        check {[list $timers $delays $retry::delay] eq $previous && [lindex $delays end] == $delay} \
            "historical refresh or duplicate failure restarted overload backoff"
        fire
        set recovery [::huddle::json2huddle [lindex $sent end]]
        if {$progress} { auto_followup } else {
            check {[huddle equal [huddle get $recovery params] [huddle get $autoRequest params]]} \
                "historical recovery chain changed original input or settings"
        }
        set turn historical-retry-[incr goalSequence]
        reply [json_dump [huddle get $recovery id]] $turn
        started $turn
    }
    completed $turn completed
    check {[dict size $timers] == 0 && $retry::delay == 5000 && [llength $sent] == 3} \
        "historical recovery chain duplicated work or failed to reset on success"
}

# Only the exact validated completed baseline is historical; changes still stop.
foreach progress {0 1} {
    foreach {key value} {
        threadId {"other"} createdAt 9 objective {"changed objective"} tokenBudget 100 tokenBudget {"100"}
        updatedAt 3 tokensUsed 13 timeUsedSeconds 2 tokensUsed {"12"}
        status {"active"} status {"blocked"} status {"paused"}
        status {"usageLimited"} status {"budgetLimited"}
    } {
        historical_goal_fixture
        if {$progress} { user_event item/started {{"type":"commandExecution","id":"historical-change-tool"}} $autoTurn }
        completed $autoTurn
        set goal [goal_fixture complete]
        huddle set goal $key [::huddle::json2huddle $value]
        goal_read_fixture $goal
        goal_canceled_fixture "changed completed-goal snapshot preserved recovery"
    }
}

# First reads during work, late reads, invalid baselines and attached work cannot
# manufacture historical provenance, even if a later refresh is exactly equal.
foreach baseline {unknown late foreign_id typed_id malformed attached attached_default} {
    automatic::cancel
    retry::reset
    goal::forget 1
    set automatic::live {}
    set goal [goal_fixture complete]
    if {$baseline in {attached attached_default}} {
        set automatic::flags [list auto_reset_limit 0 auto_continue_after_stop [expr {$baseline eq "attached"}]]
        auto_activation {"modelProvider":"openai"} 1
        goal_read_fixture $goal
        completed rejected-foreign-turn completed
    } elseif {$baseline ne "unknown"} {
        set id [huddle number [incr goalSequence]]
        retry::client [json_dump [huddle create id $id method [huddle string thread/goal/get] \
            params [huddle create threadId [huddle string t1]]]]
        set responseId $id
        if {$baseline eq "foreign_id"} { set responseId [huddle string foreign-historical-read] }
        if {$baseline eq "typed_id"} { set responseId [huddle string [huddle get_stripped $id]] }
        if {$baseline eq "malformed"} { huddle set goal tokensUsed [huddle string 12] }
        if {$baseline ne "late"} {
            retry::server [json_dump [huddle create id $responseId result [huddle create goal $goal]]]
        }
    }
    auto_begin
    if {$baseline eq "late"} {
        retry::server [json_dump [huddle create id $id result [huddle create goal $goal]]]
    }
    completed $autoTurn
    goal_read_fixture [goal_fixture complete]
    goal_canceled_fixture "unverified or late completed baseline authorized recovery"
}

# Historical reads cannot neutralize notifications, mutations or real context changes.
foreach boundary {notification automatic_set manual_set steer settings thread account disconnect foreign_turn} {
    historical_goal_fixture
    completed $autoTurn
    switch -- $boundary {
        notification { retry::server [goal_event [goal_fixture complete] [huddle string $autoTurn]] }
        automatic_set - manual_set {
            set goalRequest [goal_set_fixture]
            if {$boundary eq "manual_set"} { huddle set goalRequest params origin [huddle string user] }
            retry::client [json_dump $goalRequest]
            goal_ack_fixture $goalRequest
        }
        steer { retry::client [format {{"method":"turn/steer","params":{"threadId":"t1","expectedTurnId":"%s","input":[]}}} $autoTurn] }
        settings { retry::server {{"method":"thread/settings/updated","params":{"threadId":"t1","threadSettings":{"model":"other"}}}} }
        thread { retry::client {{"id":"historical-other-thread","method":"thread/resume","params":{"threadId":"other"}}} }
        account { retry::server {{"method":"account/updated","params":{}}} }
        disconnect { transport::retire }
        foreign_turn { started foreign-historical-turn; completed foreign-historical-turn completed }
    }
    goal_canceled_fixture "historical baseline hid a real context change"
    auto_begin
    completed $autoTurn
    goal_read_fixture [goal_fixture complete]
    goal_canceled_fixture "historical provenance leaked across a real context change"
}

# Foreign work between the idle baseline and manual submission expires history,
# including unscoped activity with optional recovery disabled.
foreach activity {turn status} {
    historical_goal_fixture 0
    completed $autoTurn completed
    if {$activity eq "turn"} {
        started foreign-idle-goal-turn
        completed foreign-idle-goal-turn completed
    } else {
        retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"active"}}}}
    }
    # Preserve the real activity guard; auto_begin intentionally clears it.
    set id [json::write string historical-busy-[incr goalSequence]]
    huddle set autoRequest id [::huddle::json2huddle $id]
    retry::client [json_dump $autoRequest]
    set autoTurn busy-historical-turn-$goalSequence
    reply $id $autoTurn
    completed $autoTurn
    goal_read_fixture [goal_fixture complete]
    goal_canceled_fixture "foreign idle work retained historical goal provenance"
    auto_begin
    completed $autoTurn
    goal_read_fixture [goal_fixture complete]
    goal_canceled_fixture "busy submission retained history for later manual work"
}

# Native activity expires both idle snapshots and pending reads, including
# delayed activation replies received before the next manual task.
foreach follow {0 1} {
    foreach activity {status activation status_only_activation turns_only_activation} {
        foreach baseline {snapshot pending} {
            automatic::cancel
            retry::reset
            goal::forget 1
            set automatic::live {}
            set automatic::ids {}
            set automatic::flags [list auto_reset_limit 0 auto_continue_after_stop $follow]
            set id [json::write string historical-activation-[incr goalSequence]]
            if {$activity ne "status"} {
                set activation [format {{"id":%s,"method":"thread/resume","params":{"threadId":"t1"}}} $id]
                recovery::client $activation
                retry::client $activation
            }
            if {$baseline eq "snapshot"} {
                goal_read_fixture [goal_fixture complete]
            } else { set readId [goal_read_request_fixture] }
            if {$activity eq "status"} {
                retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"active"}}}}
            } else {
                set status active
                set turns {[{"id":"delayed-foreign-turn","status":"inProgress","items":[]}]}
                if {$activity eq "status_only_activation"} { set turns {[]} }
                if {$activity eq "turns_only_activation"} { set status idle }
                retry::server [format {{"id":%s,"result":{"thread":{"id":"t1","status":{"type":"%s"},"turns":%s}}}} \
                    $id $status $turns]
            }
            retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
            if {$baseline eq "pending"} {
                retry::server [json_dump [huddle create id $readId result [huddle create goal [goal_fixture complete]]]]
            }
            auto_begin 0 $follow
            completed $autoTurn
            goal_read_fixture [goal_fixture complete]
            goal_canceled_fixture "intervening native activity retained completed-goal history after becoming idle"
        }
    }
}

# Pending idle reads have the same activity boundary even without a baseline.
# Keep the live-turn guard when submitting steering after foreign tool effects.
foreach follow {0 1} {
    foreach ordering {running idle terminal_only} {
        automatic::cancel
        retry::reset
        goal::forget 1
        set automatic::live {}
        set automatic::ids {}
        set sent {}
        set automatic::flags [list auto_reset_limit 0 auto_continue_after_stop $follow]
        set id [goal_read_request_fixture]
        set foreignTurn pending-goal-foreign-[incr goalSequence]
        if {$ordering eq "terminal_only"} {
            completed $foreignTurn completed serverOverloaded {[{"type":"commandExecution","id":"pending-terminal-tool"}]}
        } else {
            started $foreignTurn
            user_event item/started {{"type":"commandExecution","id":"pending-goal-tool"}} $foreignTurn
        }
        if {$ordering eq "idle"} { completed $foreignTurn completed }
        retry::server [json_dump [huddle create id $id result [huddle create goal [goal_fixture complete]]]]
        if {$ordering eq "running"} {
            set autoRequest [::huddle::json2huddle $request]
            set autoId [json::write string goal-steering-[incr autoSequence]]
            huddle set autoRequest id [::huddle::json2huddle $autoId]
            set autoTurn $foreignTurn
            retry::client [json_dump $autoRequest]
            reply $autoId $autoTurn
        } else { auto_begin 0 $follow }
        completed $autoTurn
        if {$ordering eq "running"} {
            check {[dict size $timers] == 0 && $sent eq ""} "late goal read allowed replay of foreign partial work"
        }
        goal_read_fixture [goal_fixture complete]
        goal_canceled_fixture "pending goal read acquired history across foreign work"
    }
}

# Context notifications are scoped to the pending read's thread, not just an
# established snapshot or model request. An unrelated thread remains harmless.
foreach follow {0 1} {
    foreach method {thread/settings/updated thread/archived thread/environment/connected thread/environment/disconnected} {
        foreach thread {t1 other} {
            automatic::cancel
            retry::reset
            goal::forget 1
            set automatic::live {}
            set automatic::ids {}
            set automatic::flags [list auto_reset_limit 0 auto_continue_after_stop $follow]
            set id [goal_read_request_fixture]
            retry::server [json_dump [huddle create method [huddle string $method] \
                params [huddle create threadId [huddle string $thread]]]]
            retry::server [json_dump [huddle create id $id result [huddle create goal [goal_fixture complete]]]]
            auto_begin 0 $follow
            completed $autoTurn
            goal_read_fixture [goal_fixture complete]
            if {$thread eq "t1"} {
                goal_canceled_fixture "pending idle goal read survived a matching context change"
            } else {
                fire
                check {[llength $sent] == 1 && [huddle equal \
                    [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                    [huddle get $autoRequest params]]} "unrelated thread context invalidated historical recovery"
            }
        }
    }
}

# Activity belonging to the fresh owned task still preserves historical reads.
foreach activity {status activation} {
    automatic::cancel
    retry::reset
    goal::forget 1
    set automatic::live {}
    set automatic::ids {}
    set id [json::write string owned-goal-activation-[incr goalSequence]]
    if {$activity eq "activation"} {
        set activation [format {{"id":%s,"method":"thread/resume","params":{"threadId":"t1"}}} $id]
        recovery::client $activation
        retry::client $activation
    }
    goal_read_fixture [goal_fixture complete]
    auto_begin 0 0
    if {$activity eq "status"} {
        retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"active"}}}}
    } else {
        retry::server [format {{"id":%s,"result":{"thread":{"id":"t1","status":{"type":"active"},"turns":[{"id":"%s","status":"inProgress","items":[]}]}}}} \
            $id $autoTurn]
    }
    completed $autoTurn
    goal_read_fixture [goal_fixture complete]
    fire
    check {[llength $sent] == 1 && [huddle equal \
        [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
        [huddle get $autoRequest params]]} "owned native activity expired eligible historical recovery"
}

# Progress can arrive without turn/started; it still expires idle history and
# prevents steering partial work from becoming a fresh replay candidate.
proc goal_progress_fixture {method turn {thread t1}} {
    set params [huddle create threadId [huddle string $thread] turnId [huddle string $turn]]
    if {$method eq "item/started"} {
        huddle set params item [huddle create type [huddle string commandExecution] id [huddle string goal-progress-tool]]
    }
    retry::server [json_dump [huddle create method [huddle string $method] params $params]]
}
proc goal_manual_fixture {turn} {
    set ::autoRequest [::huddle::json2huddle $::request]
    set ::autoId [json::write string goal-progress-manual-[incr ::autoSequence]]
    set ::autoTurn $turn
    huddle set ::autoRequest id [::huddle::json2huddle $::autoId]
    retry::client [json_dump $::autoRequest]
    reply $::autoId $turn
}
foreach follow {0 1} {
    foreach method {item/started hook/started} {
        foreach baseline {snapshot pending} {
            foreach state {running idle} {
                automatic::cancel
                retry::reset
                goal::forget 1
                set automatic::live {}
                set automatic::ids {}
                set sent {}
                set automatic::flags [list auto_reset_limit $follow auto_continue_after_stop $follow]
                if {$baseline eq "snapshot"} {
                    goal_read_fixture [goal_fixture complete]
                } else { set id [goal_read_request_fixture] }
                set turn progress-without-start-[incr goalSequence]
                goal_progress_fixture $method $turn
                if {$state eq "idle"} { completed $turn completed }
                if {$baseline eq "pending"} {
                    retry::server [json_dump [huddle create id $id result [huddle create goal [goal_fixture complete]]]]
                }
                if {$state eq "idle"} { set turn fresh-after-progress-[incr goalSequence] }
                goal_manual_fixture $turn
                completed $autoTurn
                if {$state eq "running"} {
                    check {[dict size $timers] == 0 && $sent eq ""} "progress without a start allowed steering replay"
                }
                goal_read_fixture [goal_fixture complete]
                goal_canceled_fixture "foreign progress without a start preserved completed-goal history"
            }
        }
    }
}

# Finished turns and other threads preserve the selected thread's history and
# fresh-work eligibility.
foreach method {item/started hook/started} {
    foreach baseline {snapshot pending} {
        foreach source {stale other_thread} {
            automatic::cancel
            retry::reset
            goal::forget 1
            set automatic::live {}
            set automatic::ids {}
            set sent {}
            set automatic::flags {auto_reset_limit 0 auto_continue_after_stop 0}
            set turn irrelevant-progress-[incr goalSequence]
            if {$source eq "stale"} { completed $turn completed }
            if {$baseline eq "snapshot"} {
                goal_read_fixture [goal_fixture complete]
            } else { set id [goal_read_request_fixture] }
            set thread t1
            if {$source eq "other_thread"} { set thread other }
            goal_progress_fixture $method $turn $thread
            if {$baseline eq "pending"} {
                retry::server [json_dump [huddle create id $id result [huddle create goal [goal_fixture complete]]]]
            }
            goal_manual_fixture fresh-after-irrelevant-[incr goalSequence]
            completed $autoTurn
            goal_read_fixture [goal_fixture complete]
            fire
            check {[llength $sent] == 1 && [huddle equal \
                [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                [huddle get $autoRequest params]]} "irrelevant progress changed historical recovery"
        }
    }
}

# Acknowledged owned progress needs no start notification to retain opt-in
# continuation; the same metadata cannot enable continuation with the flag off.
foreach follow {0 1} {
    foreach method {item/started hook/started} {
        automatic::cancel
        retry::reset
        goal::forget 1
        set automatic::live {}
        set automatic::ids {}
        set sent {}
        set automatic::flags [list auto_reset_limit 0 auto_continue_after_stop $follow]
        goal_read_fixture [goal_fixture complete]
        goal_manual_fixture owned-progress-without-start-[incr goalSequence]
        goal_progress_fixture $method $autoTurn
        completed $autoTurn
        set previous [list $timers $delays $retry::delay]
        goal_read_fixture [goal_fixture complete]
        check {[dict size $timers] == $follow && [list $timers $delays $retry::delay] eq $previous} \
            "owned progress without a start lost recovery or changed its backoff"
        if {$follow} { fire; auto_followup }
        check {[llength $sent] == $follow} "owned progress without a start bypassed opt-in or duplicated work"
    }
}

# User-item correlation also bounds history for subsequent fresh work. Matching
# echoes, finished turns and other threads cannot be mistaken for steering.
foreach reset {0 1} {
    foreach follow {0 1} {
        foreach change {same content client identity stale other_thread foreign_turn} {
            foreach delivery {notification reply started completed} {
                if {$change in {stale other_thread foreign_turn} && $delivery ne "notification"} { continue }
                set staleTurn goal-stale-user-[incr goalSequence]
                if {$change eq "stale"} { completed $staleTurn completed }
                set automatic::ids {}
                set client goal-client-[incr goalSequence]
                historical_goal_fixture $follow 0 $reset $client
                started $autoTurn
                set original [huddle create type [huddle string userMessage] \
                    id [huddle string goal-user-$goalSequence] clientId [huddle string $client] \
                    content [huddle get $autoRequest params input]]
                user_event item/started [json_dump $original] $autoTurn
                if {$delivery ne "reply"} { reply $autoId $autoTurn }
                set item $original
                switch -- $change {
                    content - stale - other_thread - foreign_turn { huddle set item content 0 text [huddle string "foreign fixture input"] }
                    client { huddle set item clientId [huddle string foreign-client] }
                    identity { huddle set item id [huddle string additional-goal-user] }
                }
                set items [json::write array [json_dump $item]]
                switch -- $delivery {
                    notification {
                        set turn $autoTurn
                        set thread t1
                        if {$change eq "stale"} { set turn $staleTurn }
                        if {$change eq "other_thread"} { set thread other }
                        if {$change eq "foreign_turn"} { set turn foreign-goal-user-[incr goalSequence] }
                        user_event item/completed [json_dump $item] $turn $thread
                    }
                    reply { reply $autoId $autoTurn $items }
                    started { started $autoTurn t1 $items }
                    completed { completed $autoTurn completed serverOverloaded $items }
                }
                if {$change eq "foreign_turn"} {
                    retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
                } elseif {$delivery ne "completed"} { completed $autoTurn completed }
                check {[dict size $timers] == 0 && $sent eq ""} "user-item correlation submitted recovery without failure"
                goal_manual_fixture after-goal-user-item-[incr goalSequence]
                completed $autoTurn
                set previous [list $timers $delays $retry::delay]
                goal_read_fixture [goal_fixture complete]
                if {$change in {same stale other_thread}} {
                    check {[list $timers $delays $retry::delay] eq $previous} "matching or irrelevant user item changed historical backoff"
                    fire
                    check {[llength $sent] == 1 && [huddle equal \
                        [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                        [huddle get $autoRequest params]]} "matching or irrelevant user item lost historical recovery"
                } else { goal_canceled_fixture "detected steering retained history for a later fresh task" }
            }
        }
    }
}

# A generated turn may lose its retry tracker inside the opt-in detector. Clear
# history there as well, before cancellation prevents default-engine correlation.
foreach reset {0 1} {
    foreach {change stopped} {same 0 content 0 client 0 identity 0 same 1 content 1 client 1} {
        set automatic::ids {}
        historical_goal_fixture 1 1 $reset
        goal_progress_fixture item/started $autoTurn
        completed $autoTurn
        fire
        set id [auto_followup]
        set turn goal-generated-user-[incr goalSequence]
        reply $id $turn
        started $turn
        set params [huddle get [dict get $automatic::current request] params]
        set item [huddle create type [huddle string userMessage] \
            id [huddle string goal-generated-echo-$goalSequence] \
            clientId [huddle get $params clientUserMessageId] content [huddle get $params input]]
        if {$stopped} {
            completed $turn
        } else { user_event item/started [json_dump $item] $turn }
        switch -- $change {
            content { huddle set item content 0 text [huddle string "foreign continuation input"] }
            client { huddle set item clientId [huddle string foreign-client] }
            identity { huddle set item id [huddle string additional-generated-user] }
        }
        set sent {}
        user_event item/completed [json_dump $item] $turn
        if {!$stopped} { completed $turn completed }
        goal_manual_fixture after-generated-steering-[incr goalSequence]
        completed $autoTurn
        goal_read_fixture [goal_fixture complete]
        if {$change eq "same"} {
            fire
            check {[llength $sent] == 1 && [huddle equal \
                [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                [huddle get $autoRequest params]]} "matching generated echo lost historical recovery"
        } else { goal_canceled_fixture "generated-turn steering retained historical recovery" }
    }
}

# A model acknowledgement must confirm provisional ownership before idle history
# can survive into another manual task. Retry resets alone retain the baseline.
foreach follow {0 1} {
    foreach event {start tool hook} {
        foreach outcome {matching different error malformed} {
            set automatic::ids {}
            historical_goal_fixture $follow 0
            set candidate provisional-goal-turn-[incr goalSequence]
            if {$event eq "start"} {
                started $candidate
            } else {
                set method item/started
                if {$event eq "hook"} { set method hook/started }
                goal_progress_fixture $method $candidate
            }
            goal_read_fixture [goal_fixture complete]
            switch -- $outcome {
                matching { reply $autoId $candidate }
                different { reply $autoId actual-goal-turn-[incr goalSequence] }
                error { retry::server [format {{"id":%s,"error":{"code":-32602,"message":"synthetic rejection"}}} $autoId] }
                malformed { retry::server [format {{"id":%s,"result":{"turn":{}}}} $autoId] }
            }
            if {$outcome eq "matching"} { completed $candidate completed }
            retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
            goal_manual_fixture after-provisional-goal-[incr goalSequence]
            completed $autoTurn
            goal_read_fixture [goal_fixture complete]
            if {$outcome eq "matching"} {
                fire
                check {[llength $sent] == 1 && [huddle equal \
                    [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                    [huddle get $autoRequest params]]} "matching acknowledgement lost historical recovery"
            } else {
                goal_canceled_fixture "disproved provisional ownership retained completed-goal history"
            }
        }
    }
}

# Thread activity is provisional before ACK, even without a turn ID. Strict
# parsing failures must expire unresolved history before either tracker is lost.
# With no activity, even a rejected ACK or reset preserves the idle baseline.
foreach reset {0 1} {
    foreach follow {0 1} {
        foreach activity {none status start} {
            foreach outcome {matching error malformed missing_status invalid_status duplicate_error duplicate_result reset} {
                set automatic::ids {}
                historical_goal_fixture $follow 0 $reset
                set candidate thread-activity-before-ack-[incr goalSequence]
                if {$activity eq "status"} {
                    retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"active"}}}}
                } elseif {$activity eq "start"} { started $candidate }
                switch -- $outcome {
                    matching { reply $autoId $candidate }
                    error { retry::server [format {{"id":%s,"error":{"code":-32602,"message":"synthetic rejection"}}} $autoId] }
                    malformed { retry::server [format {{"id":%s,"result":{"turn":{}}}} $autoId] }
                    missing_status { retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","items":[]}}}} $autoId $candidate] }
                    invalid_status { retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","status":"unknown","items":[]}}}} $autoId $candidate] }
                    duplicate_error {
                        reject_duplicate {retry::server [format {{"id":%s,"error":{"code":-32602,"message":"synthetic rejection"},"error":{"code":-32602,"message":"synthetic rejection"}}} $autoId]}
                    }
                    duplicate_result {
                        reject_duplicate {retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","status":"inProgress","items":[]}},"result":{"turn":{"id":"%s","status":"inProgress","items":[]}}}} $autoId $candidate $candidate]}
                    }
                    reset { retry::reset }
                }
                if {$activity eq "none"} {
                    retry::reset
                } elseif {$outcome eq "matching"} { completed $candidate completed }
                retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
                check {[dict size $timers] == 0 && $sent eq ""} "provisional thread activity submitted work"
                goal_manual_fixture after-thread-activity-[incr goalSequence]
                completed $autoTurn
                set previous [list $timers $delays $retry::delay]
                goal_read_fixture [goal_fixture complete]
                if {$activity eq "none" || $outcome eq "matching"} {
                    check {[list $timers $delays $retry::delay] eq $previous} "resolved or absent activity changed historical backoff"
                    fire
                    check {[llength $sent] == 1 && [huddle equal \
                        [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                        [huddle get $autoRequest params]]} "resolved or absent activity lost historical recovery"
                } else { goal_canceled_fixture "unresolved thread activity retained historical recovery" }
            }
        }
        # A rejected ACK before activity cannot establish historical ownership.
        # Only the none control resets without any subsequent work notification.
        foreach outcome {matching duplicate_result invalid_status method_null numeric_turn_id} {
            foreach activity {none status start completion} {
                set automatic::ids {}
                historical_goal_fixture $follow 0 $reset
                set candidate invalid-ack-before-activity-[incr goalSequence]
                if {$outcome eq "numeric_turn_id"} { set candidate $goalSequence }
                switch -- $outcome {
                    matching { reply $autoId $candidate }
                    duplicate_result {
                        reject_duplicate {retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","status":"inProgress","items":[]}},"result":{"turn":{"id":"%s","status":"inProgress","items":[]}}}} $autoId $candidate $candidate]}
                    }
                    invalid_status { retry::server [format {{"id":%s,"result":{"turn":{"id":"%s","status":"unknown","items":[]}}}} $autoId $candidate] }
                    method_null { retry::server [format {{"id":%s,"method":null,"result":{"turn":{"id":"%s","status":"inProgress","items":[]}}}} $autoId $candidate] }
                    numeric_turn_id {
                        retry::server [format {{"id":%s,"result":{"turn":{"id":%s,"status":"inProgress","items":[]}}}} $autoId $candidate]
                    }
                }
                switch -- $activity {
                    status { retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"active"}}}} }
                    start { started $candidate; completed $candidate completed }
                    completion { completed $candidate completed }
                }
                retry::reset
                retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
                goal_manual_fixture after-invalid-ack-activity-[incr goalSequence]
                completed $autoTurn
                set previous [list $timers $delays $retry::delay]
                goal_read_fixture [goal_fixture complete]
                if {$outcome eq "matching" || $activity eq "none"} {
                    check {[list $timers $delays $retry::delay] eq $previous} "valid ACK or no-activity reset changed historical backoff"
                    fire
                    check {[llength $sent] == 1 && [huddle equal \
                        [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                        [huddle get $autoRequest params]]} "valid ACK or no-activity reset lost recovery"
                } else { goal_canceled_fixture "rejected ACK established ownership for later activity" }
            }
        }
        # A new manual submission must not overwrite unresolved proof before
        # retry reset can expire it. An overload still awaiting ACK is not idle.
        set automatic::ids {}
        historical_goal_fixture $follow 0 $reset
        set candidate replaced-before-ack-[incr goalSequence]
        started $candidate
        completed $candidate
        retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
        goal_manual_fixture after-unacknowledged-overload-[incr goalSequence]
        completed $autoTurn
        goal_read_fixture [goal_fixture complete]
        goal_canceled_fixture "manual replacement retained unresolved historical activity"
    }
}

# A generated continuation may discard both engines during ACK rejection. Its
# provisional history must be reconciled before either tracker disappears.
foreach outcome {matching different} {
    set automatic::ids {}
    historical_goal_fixture
    goal_progress_fixture item/started $autoTurn
    completed $autoTurn
    fire
    set autoId [auto_followup]
    set sent {}
    set candidate provisional-continuation-[incr goalSequence]
    started $candidate
    if {$outcome eq "matching"} {
        reply $autoId $candidate
        completed $candidate completed
    } else { reply $autoId actual-continuation-[incr goalSequence] }
    retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
    goal_manual_fixture after-provisional-continuation-[incr goalSequence]
    completed $autoTurn
    goal_read_fixture [goal_fixture complete]
    if {$outcome eq "matching"} {
        fire
        check {[llength $sent] == 1 && [huddle equal \
            [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
            [huddle get $autoRequest params]]} "matching continuation ACK lost historical recovery"
    } else { goal_canceled_fixture "continuation ACK rejection retained disproved history" }
}

# With no intervening activity, ordinary resets and rejected acknowledgements
# cannot make an otherwise unchanged completed baseline a new terminal stop.
foreach outcome {reset error malformed} {
    set automatic::ids {}
    historical_goal_fixture 0 0
    switch -- $outcome {
        reset { retry::reset }
        error { retry::server [format {{"id":%s,"error":{"code":-32602,"message":"synthetic rejection"}}} $autoId] }
        malformed { retry::server [format {{"id":%s,"result":{"turn":{}}}} $autoId] }
    }
    goal_manual_fixture after-neutral-reset-[incr goalSequence]
    completed $autoTurn
    goal_read_fixture [goal_fixture complete]
    fire
    check {[llength $sent] == 1 && [huddle equal \
        [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
        [huddle get $autoRequest params]]} "ordinary retry reset erased completed-goal history"
}

# A terminal candidate can discard the retry tracker before its start ACK.
# Unresolved history expires there, even if a matching ACK eventually arrives.
foreach follow {0 1} {
    foreach terminal {completed interrupted failed} {
        foreach outcome {matching matching_without_read different error malformed missing} {
            set automatic::ids {}
            historical_goal_fixture $follow 0
            set candidate terminal-before-ack-[incr goalSequence]
            started $candidate
            set code serverOverloaded
            if {$terminal eq "failed"} { set code internalServerError }
            completed $candidate $terminal $code
            switch -- $outcome {
                matching - matching_without_read { reply $autoId $candidate }
                different { reply $autoId disproving-terminal-ack-[incr goalSequence] }
                error { retry::server [format {{"id":%s,"error":{"code":-32602,"message":"synthetic rejection"}}} $autoId] }
                malformed { retry::server [format {{"id":%s,"result":{"turn":{}}}} $autoId] }
            }
            retry::server {{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}}
            check {[dict size $timers] == 0 && $sent eq ""} "unresolved terminal ownership submitted work"
            # A new idle read may establish history after the unresolved boundary.
            if {$outcome eq "matching"} { goal_read_fixture [goal_fixture complete] }
            goal_manual_fixture after-terminal-ack-[incr goalSequence]
            completed $autoTurn
            goal_read_fixture [goal_fixture complete]
            if {$outcome eq "matching"} {
                fire
                check {[llength $sent] == 1 && [huddle equal \
                    [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                    [huddle get $autoRequest params]]} "fresh idle baseline after a matched terminal ACK lost recovery"
            } else {
                goal_canceled_fixture "terminal before ACK retained disproved or unresolved historical ownership"
            }
        }
    }
}

# Stale terminal notifications cannot resolve another turn's pending mutation.
foreach progress {0 1} {
    foreach status {completed interrupted} {
        foreach outcome {error unresolved success} {
            set staleTurn stale-goal-[incr goalSequence]
            completed $staleTurn $status
            goal_failure_fixture $progress
            set goalRequest [goal_set_fixture]
            retry::client [json_dump $goalRequest]
            set pendingTimers $timers
            completed $staleTurn $status
            check {$timers eq $pendingTimers} "stale completion changed overload backoff"
            switch -- $outcome {
                error {
                    retry::server [json_dump [huddle create id [huddle get $goalRequest id] \
                        error [huddle create code [huddle number -32602] message [huddle string rejected]]]]
                    goal_canceled_fixture "stale completion masked a rejected automatic mutation"
                }
                unresolved {
                    fire
                    goal_canceled_fixture "stale completion erased an unresolved automatic mutation"
                }
                success {
                    goal_ack_fixture $goalRequest
                    retry::server [goal_event [goal_fixture blocked] [huddle null]]
                    check {[dict size $timers] == 1} "stale completion lost valid automatic mutation correlation"
                    fire
                    if {$progress} { auto_followup } else {
                        check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                            [huddle get $autoRequest params]]} "stale completion changed original-input replay"
                    }
                }
            }
        }
    }
}

# Owned accounting cannot hide a subsequent correlated read of a changed goal.
foreach progress {0 1} {
    foreach {key value} {unchanged null createdAt 9 objective {"changed objective"} tokenBudget 100} {
        retry::client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}}
        goal_failure_fixture $progress
        set readId [goal_read_request_fixture]
        set goal [goal_fixture]
        huddle set goal updatedAt [huddle number 3]
        huddle set goal tokensUsed [huddle number 13]
        retry::server [goal_event $goal [huddle string $autoTurn]]
        if {$key ne "unchanged"} { huddle set goal $key [::huddle::json2huddle $value] }
        check {[retry::server [json_dump [huddle create id $readId result [huddle create goal $goal]]]] == 1} \
            "interleaved native goal read reply was hidden"
        if {$key ne "unchanged"} {
            goal_canceled_fixture "owned accounting masked a conflicting goal read"
        } else {
            check {[dict size $timers] == 1} "unchanged interleaved goal read canceled overload recovery"
            fire
            if {$progress} { auto_followup } else {
                check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                    [huddle get $autoRequest params]]} "interleaved goal read changed original-input replay"
            }
        }
    }
}

# Nullable mutation fields mean unchanged, including a non-null typed budget.
foreach explicit {0 1} {
    retry::client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}}
    auto_begin 0 1
    set goal [goal_fixture]
    huddle set goal tokenBudget [huddle number 100]
    goal_read_fixture $goal
    completed $autoTurn failed serverOverloaded {[{"type":"commandExecution","id":"budget-tool"}]}
    set goalRequest [goal_set_fixture]
    if {$explicit} {
        huddle set goalRequest params tokenBudget [huddle number 100]
        huddle set goalRequest params objective [huddle string "fixture goal"]
    }
    retry::client [json_dump $goalRequest]
    huddle set goal status [huddle string blocked]
    goal_ack_fixture $goalRequest $goal
    retry::server [goal_event $goal [huddle null]]
    check {[dict size $timers] == 1} "native nullable fields changed a goal budget"
    fire
    auto_followup
    retry::client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}}
}

# Same-turn IDs and acknowledged automatic provenance never excuse a real change.
foreach source {correlated native} {
    foreach {key value} {
        threadId {"other"} createdAt 9 objective {"another goal"} tokenBudget 100 tokenBudget {"100"}
        status {"paused"} status {"usageLimited"} status {"budgetLimited"} status {"complete"}
        updatedAt 0 tokensUsed 0
    } {
        goal_failure_fixture
        if {$source eq "native"} {
            set goalRequest [goal_set_fixture]
            retry::client [json_dump $goalRequest]
            goal_ack_fixture $goalRequest
        }
        set goal [goal_fixture blocked]
        huddle set goal $key [::huddle::json2huddle $value]
        set turn [huddle null]
        if {$source eq "correlated"} { set turn [huddle string $autoTurn] }
        retry::server [goal_event $goal $turn]
        goal_canceled_fixture "changed goal metadata preserved recovery"
    }
}
foreach turn [list [huddle null] [huddle string foreign-goal-turn] [huddle number 1]] {
    goal_failure_fixture
    retry::server [goal_event [goal_fixture blocked] $turn]
    goal_canceled_fixture "uncorrelated goal update preserved recovery"
}

# Automatic origin alone cannot authorize a goal mutation.
foreach {key value} {
    origin {"user"} origin null origin {"AUTOMATIC"} origin true
    status {"paused"} objective {"changed"} tokenBudget 100 tokenBudget {"100"}
    threadId {"other"}
} {
    goal_failure_fixture
    set goalRequest [goal_set_fixture]
    huddle set goalRequest params $key [::huddle::json2huddle $value]
    retry::client [json_dump $goalRequest]
    goal_ack_fixture $goalRequest
    retry::server [goal_event [goal_fixture blocked] [huddle null]]
    goal_canceled_fixture "manual or changed goal request preserved recovery"
}
goal_failure_fixture
set goalRequest [goal_set_fixture]
set goalRequest [huddle remove $goalRequest params origin]
retry::client [json_dump $goalRequest]
goal_ack_fixture $goalRequest
goal_canceled_fixture "missing goal origin preserved recovery"

# Only the matching typed request ID and a successful same-goal reply prove origin.
foreach response {error malformed foreign_id numeric_id changed_goal notification_first unresolved reused_id} {
    goal_failure_fixture
    set goalRequest [goal_set_fixture]
    if {$response eq "numeric_id"} { huddle set goalRequest id [huddle number 700001] }
    if {$response eq "reused_id"} { huddle set goalRequest id [::huddle::json2huddle $autoId] }
    retry::client [json_dump $goalRequest]
    switch -- $response {
        error { retry::server [json_dump [huddle create id [huddle get $goalRequest id] \
            error [huddle create code [huddle number -32602] message [huddle string rejected]]]] }
        malformed { retry::server [json_dump [huddle create id [huddle get $goalRequest id] result [huddle create]]] }
        foreign_id { huddle set goalRequest id [huddle string foreign-goal-response]; goal_ack_fixture $goalRequest }
        numeric_id { huddle set goalRequest id [huddle string 700001]; goal_ack_fixture $goalRequest }
        changed_goal {
            set goal [goal_fixture blocked]
            huddle set goal objective [huddle string changed]
            goal_ack_fixture $goalRequest $goal
        }
        notification_first {
            retry::server [goal_event [goal_fixture blocked] [huddle null]]
            goal_ack_fixture $goalRequest
        }
        unresolved { fire }
        reused_id { goal_ack_fixture $goalRequest }
    }
    retry::server [goal_event [goal_fixture blocked] [huddle null]]
    goal_canceled_fixture "unverified goal acknowledgement authorized recovery"
}

# A second in-flight mutation is ambiguous; another client's read is harmless.
foreach concurrent {mutation read} {
    goal_failure_fixture
    set goalRequest [goal_set_fixture]
    retry::client [json_dump $goalRequest]
    if {$concurrent eq "mutation"} {
        retry::client [json_dump [goal_set_fixture]]
    } else {
        retry::client {{"id":"foreign-goal-get","method":"thread/goal/get","params":{"threadId":"other"}}}
        retry::server [json_dump [huddle create id [huddle string foreign-goal-get] \
            result [huddle create goal [goal_fixture]]]]
    }
    goal_ack_fixture $goalRequest
    retry::server [goal_event [goal_fixture blocked] [huddle null]]
    if {$concurrent eq "mutation"} {
        goal_canceled_fixture "overlapping goal mutations retained provenance"
    } else {
        check {[dict size $timers] == 1} "foreign goal read invalidated automatic stall recovery"
        fire
        auto_followup
    }
}

# Interleaved owned accounting cannot acknowledge or erase a pending mutation.
foreach outcome {success error unresolved} {
    goal_failure_fixture
    set goalRequest [goal_set_fixture]
    retry::client [json_dump $goalRequest]
    retry::server [goal_event [goal_fixture] [huddle string $autoTurn]]
    switch -- $outcome {
        success {
            goal_ack_fixture $goalRequest
            retry::server [goal_event [goal_fixture blocked] [huddle null]]
            fire
            auto_followup
        }
        error {
            retry::server [json_dump [huddle create id [huddle get $goalRequest id] \
                error [huddle create code [huddle number -32602] message [huddle string rejected]]]]
            goal_canceled_fixture "owned accounting masked a rejected automatic mutation"
        }
        unresolved {
            fire
            goal_canceled_fixture "owned accounting acknowledged an unresolved automatic mutation"
        }
    }
}

# An old proof cannot cross another turn, manual context change or disconnection.
foreach boundary {new_turn foreign_turn settings clear disconnect} {
    goal_failure_fixture
    set goalRequest [goal_set_fixture]
    retry::client [json_dump $goalRequest]
    goal_ack_fixture $goalRequest
    retry::server [goal_event [goal_fixture blocked] [huddle null]]
    switch -- $boundary {
        new_turn {
            fire
            set id [auto_followup]
            set sent {}
            reply $id next-goal-turn
            set autoTurn next-goal-turn
            completed $autoTurn
        }
        foreign_turn { started foreign-goal-turn }
        settings { retry::client {{"method":"thread/settings/update","params":{"threadId":"t1","model":"changed"}}} }
        clear { retry::client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}} }
        disconnect { transport::retire }
    }
    goal_ack_fixture $goalRequest
    retry::server [goal_event [goal_fixture blocked] [huddle null]]
    goal_canceled_fixture "stale automatic goal proof crossed a context boundary"
}

# Automatic goal updates retain accumulated overload delay across follow-ups.
auto_begin 1 1
goal_read_fixture
foreach delay {5000 10000 20000} {
    completed $autoTurn failed serverOverloaded {[{"type":"commandExecution","id":"goal-backoff-tool"}]}
    set goalRequest [goal_set_fixture]
    retry::client [json_dump $goalRequest]
    goal_ack_fixture $goalRequest
    foreach duplicate {1 2} { retry::server [goal_event [goal_fixture blocked] [huddle null]] }
    check {[dict size $timers] == 1 && [lindex $delays end] == $delay} "goal lifecycle reset or duplicated overload backoff"
    fire
    set id [auto_followup]
    set autoTurn goal-backoff-$delay
    reply $id $autoTurn
}
completed $autoTurn completed
check {$retry::delay == 5000 && [dict size $timers] == 0} "goal-preserved recovery failed to reset on success"
retry::client {{"method":"thread/goal/clear","params":{"threadId":"t1"}}}

# Installed metadata requests neither steer work nor change the selected thread.
set metadataSequence 0
proc metadata_read {method thread} {
    set params [huddle create threadId [huddle string $thread]]
    switch -- $method {
        thread/list - thread/loaded/list - thread/realtime/listVoices - account/read -
        account/rateLimits/read - account/workspaceMessages/read - account/gatewayOAuth/read {
            set params [huddle create]
        }
        thread/search { set params [huddle create searchTerm [huddle string fixture]] }
        thread/searchOccurrences { huddle set params searchTerm [huddle string fixture] }
        thread/attachmentOwner/list {
            set params [huddle create attachmentType [huddle string file] identityKey [huddle string fixture]]
        }
        thread/items/read {
            huddle set params turnId [huddle string fixture-turn]
            huddle set params itemIds [huddle list [huddle string fixture-item]]
        }
        thread/readState/update {
            huddle set params expectedRevision [huddle string fixture-revision]
            huddle set params operation [huddle create type [huddle string read]]
        }
        thread/name/set {
            huddle set params name [huddle string "Neutral fixture title"]
        }
    }
    return [json_dump [huddle create id [huddle string metadata-[incr ::metadataSequence]] \
        method [huddle string $method] params $params]]
}
foreach method {thread/queue/list thread/backgroundTerminals/list thread/items/read thread/timeline/list
    thread/read thread/readState/update thread/name/set thread/list thread/loaded/list thread/search thread/searchOccurrences thread/turns/list
    thread/items/list thread/goal/get thread/attachment/list thread/attachmentOwner/list thread/realtime/listVoices
    account/read account/rateLimits/read account/usage/read account/workspaceMessages/read account/gatewayOAuth/read} {
    foreach stage {running queued_stop verify} {
        if {$stage eq "verify"} {
            auto_until verify
        } else {
            auto_begin 1 1
            if {$stage eq "queued_stop"} { completed $autoTurn failed cyberPolicy }
        }
        set previous $automatic::current
        set previousRetry [list $retry::current $retry::delay $timers]
        foreach thread {t1 metadata-other-thread} {
            retry::client [metadata_read $method $thread]
        }
        check {$automatic::current eq $previous} "metadata read canceled or changed recovery ownership"
        check {[list $retry::current $retry::delay $timers] eq $previousRetry} "metadata read changed overload tracking or backoff"
        if {$stage eq "running"} { completed $autoTurn failed cyberPolicy }
        if {$stage eq "verify"} { auto_reply $restored }
        fire
        auto_followup
    }
}

# Native 0.165 inline settings and explicitly marked title helpers share the
# foreground connection, but neither can acknowledge or replace its model turn.
set capacitySequence 0
proc capacity_client {json} {
    recovery::client $json
    retry::client $json
}
proc capacity_activation {thread} {
    set result [automatic::decode {{"thread":{"id":"t1","status":{"type":"idle"}},"model":"fixture-model","modelProvider":"openai","cwd":"/fixture","approvalPolicy":"never","approvalsReviewer":"user","sandbox":{"type":"readOnly","networkAccess":false},"activePermissionProfile":null,"disabledPluginIds":[],"reasoningEffort":null,"serviceTier":null,"multiAgentMode":"explicitRequestOnly"}}]
    huddle set result thread id [huddle string $thread]
    return $result
}
proc capacity_begin {{follow 1} {acknowledge 1} {numeric 0} {baselineOverrides ""} {requestOverrides ""}} {
    automatic::cancel
    retry::reset
    goal::forget 1
    resume::reset
    foreach name {pending seen deleted helpers helperRequests} { set ::recovery::$name {} }
    foreach name {usedIds internal finished} { set ::retry::$name {} }
    set ::automatic::ids {}
    set ::automatic::live {}
    set ::automatic::flags [list auto_reset_limit 0 auto_continue_after_stop $follow]
    set ::retry::finished {}
    set ::sent {}
    set ::transport::reattaching 0
    set sequence [incr ::capacitySequence]
    set activation [huddle string capacity-activation-$sequence]
    capacity_client [json_dump [huddle create id $activation method [huddle string thread/start] params [huddle create]]]
    set baseline [capacity_activation t1]
    if {$baselineOverrides ne ""} {
        foreach key [huddle keys $baselineOverrides] { huddle set baseline $key [huddle get $baselineOverrides $key] }
    }
    retry::server [json_dump [huddle create id $activation result $baseline]]
    set ::capacityId [huddle string capacity-work-$sequence]
    if {$numeric} { set ::capacityId [huddle number [expr {100000 + $sequence}]] }
    set ::capacityTurn capacity-turn-$sequence
    set ::capacityRequest [automatic::decode {{"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"Neutral foreground task","text_elements":[]}],"cwd":"/fixture","runtimeWorkspaceRoots":["/fixture"],"disabledPluginIds":null,"approvalPolicy":"never","approvalsReviewer":"user","sandboxPolicy":null,"permissions":null,"model":"fixture-model","serviceTierForTurn":null,"effort":null,"summary":null,"personality":null,"multiAgentMode":null,"collaborationMode":{"mode":"default","settings":{"model":"fixture-model","reasoning_effort":null,"developer_instructions":null}}}}}]
    huddle set ::capacityRequest id $::capacityId
    if {$requestOverrides ne ""} {
        foreach key [huddle keys $requestOverrides] { huddle set ::capacityRequest params $key [huddle get $requestOverrides $key] }
    }
    capacity_client [json_dump $::capacityRequest]
    set ::capacitySettings [automatic::decode {{"method":"thread/settings/updated","params":{"threadId":"t1","threadSettings":{"disabledPluginIds":[],"cwd":"/fixture","approvalPolicy":"never","approvalsReviewer":"user","sandboxPolicy":{"networkAccess":false,"type":"readOnly"},"activePermissionProfile":null,"model":"fixture-model","modelProvider":"openai","serviceTier":null,"effort":null,"summary":null,"collaborationMode":{"settings":{"developer_instructions":"Native resolved preset","reasoning_effort":null,"model":"fixture-model"},"mode":"default"},"multiAgentMode":"explicitRequestOnly","personality":null}}}}]
    if {$acknowledge} { reply [json_dump $::capacityId] $::capacityTurn; started $::capacityTurn }
}
proc capacity_echo {} {
    check {[retry::server [json_dump $::capacitySettings]] == 1} "own settings notification was hidden"
}
proc capacity_state {} {
    list $::retry::current $::retry::timer $::retry::delay $::automatic::current \
        $::automatic::timer $::automatic::selection $::automatic::live \
        $::goal::snapshot $::goal::pending $::goal::proof $::recovery::target $::recovery::yolo $::timers
}
proc capacity_title {id {thread title-thread} {acknowledge 1}} {
    set request [huddle create id $id method [huddle string thread/start] \
        params [huddle create threadSource [huddle string thread_title] ephemeral [huddle true]]]
    capacity_client [json_dump $request]
    if {$acknowledge} {
        retry::server [json_dump [huddle create id $id result [huddle create thread \
            [huddle create id [huddle string $thread] threadSource [huddle string thread_title] ephemeral [huddle true]]]]]
    }
    return $request
}
proc capacity_title_turn {id {thread title-thread}} {
    set request [huddle create id $id method [huddle string turn/start] \
        params [huddle create threadId [huddle string $thread] input \
            [huddle list [huddle create type [huddle string text] text [huddle string "Neutral helper work"]]]]]
    capacity_client [json_dump $request]
    return $request
}
proc capacity_followup {} {
    set follow [automatic::decode [lindex $::sent end]]
    check {[automatic::text $follow method] eq "turn/start" &&
        [automatic::text $follow params threadId] eq "t1" &&
        [huddle llength [huddle get $follow params input]] == 1 &&
        [automatic::text $follow params input 0 type] eq "text" &&
        [automatic::text $follow params input 0 text] eq "continue"} "capacity recovery did not submit literal continue"
    foreach key {cwd approvalPolicy approvalsReviewer sandboxPolicy permissions model collaborationMode} {
        check {[huddle equal [huddle get $follow params $key] [huddle get $::capacityRequest params $key]]} \
            "capacity continuation changed settings"
    }
}

foreach numeric {0 1} {
    foreach follow {0 1} {
        foreach progress {0 1} {
            foreach ordering {early late completed_before_ack} {
                capacity_begin $follow [expr {$ordering eq "late"}] $numeric
                goal_read_fixture
                if {$ordering ne "late"} {
                    capacity_echo
                    check {![field $retry::current accepted] && [dict size $timers] == 0} \
                        "settings echo acknowledged a foreground request"
                    started $capacityTurn
                }
                if {$progress} { user_event item/started {{"type":"commandExecution","id":"capacity-progress"}} $capacityTurn }
                if {$ordering eq "completed_before_ack"} { completed $capacityTurn }
                capacity_echo
                set preserved [capacity_state]
                capacity_echo
                check {[capacity_state] eq $preserved} "repeated own settings changed ownership or goal provenance"
                if {$ordering ne "late"} {
                    reply [json_dump [expr {$numeric ? [huddle string [huddle get_stripped $capacityId]] : [huddle number 100001]}]] foreign-turn
                    check {![field $retry::current accepted] && [dict size $timers] == 0} "a foreign typed ID acknowledged settings"
                    reply [json_dump $capacityId] $capacityTurn
                }
                if {$ordering ne "completed_before_ack"} { completed $capacityTurn }
                completed $capacityTurn
                set expected [expr {!$progress || $follow}]
                check {[dict size $timers] == $expected && $sent eq ""} "own settings lost recovery or bypassed opt-in"
                if {$expected} {
                    set preserved [capacity_state]
                    capacity_echo
                    check {[capacity_state] eq $preserved} "late settings reset backoff"
                    check {[lindex $delays end] == 5000} "settings changed first backoff"
                    fire
                    if {$progress} {
                        capacity_followup
                    } else {
                        check {[huddle equal [huddle get [automatic::decode [lindex $sent end]] params] \
                            [huddle get $capacityRequest params]]} "settings changed original-input replay"
                    }
                }
            }
        }
    }
}

# Defaults, effective permissions/profile data and explicit collaboration settings
# are compared as typed protocol values. New or malformed settings still cancel.
foreach variant {optional_defaults optional_collaboration explicit_preset inline_change profile} {
    capacity_begin
    switch -- $variant {
        optional_defaults {
            foreach key {personality summary serviceTier} { set capacitySettings [huddle remove $capacitySettings params threadSettings $key] }
        }
        optional_collaboration {
            huddle set capacityRequest params collaborationMode settings [huddle create model [huddle string fixture-model]]
            dict set retry::current request $capacityRequest
            set capacitySettings [huddle remove $capacitySettings params threadSettings collaborationMode settings reasoning_effort]
            huddle set capacitySettings params threadSettings collaborationMode settings developer_instructions [huddle null]
        }
        explicit_preset {
            huddle set capacityRequest params collaborationMode settings developer_instructions [huddle string "Explicit instructions"]
            dict set retry::current request $capacityRequest
            huddle set capacitySettings params threadSettings collaborationMode settings developer_instructions [huddle string "Explicit instructions"]
        }
        inline_change {
            huddle set capacityRequest params collaborationMode settings model [huddle string selected-model]
            huddle set capacityRequest params collaborationMode settings reasoning_effort [huddle string high]
            huddle set capacityRequest params sandboxPolicy [huddle create type [huddle string dangerFullAccess]]
            dict set retry::current request $capacityRequest
            huddle set capacitySettings params threadSettings model [huddle string selected-model]
            huddle set capacitySettings params threadSettings effort [huddle string high]
            huddle set capacitySettings params threadSettings sandboxPolicy [huddle create type [huddle string dangerFullAccess]]
            huddle set capacitySettings params threadSettings collaborationMode settings model [huddle string selected-model]
            huddle set capacitySettings params threadSettings collaborationMode settings reasoning_effort [huddle string high]
        }
        profile {
            set profile [huddle create id [huddle string fixture-profile] extends [huddle null]]
            set settings [dict get $retry::current settings]
            huddle set settings activePermissionProfile $profile
            dict set retry::current settings $settings
            huddle set capacityRequest params permissions [huddle string fixture-profile]
            dict set retry::current request $capacityRequest
            huddle set capacitySettings params threadSettings activePermissionProfile $profile
        }
    }
    capacity_echo
    completed $capacityTurn
    check {[dict size $timers] == 1} "verified effective settings canceled replay"
}
foreach mutation {
    {model {"foreign-model"}} {modelProvider {"foreign-provider"}} {cwd {"/foreign"}}
    {approvalPolicy {"on-request"}} {approvalsReviewer {"guardian_subagent"}}
    {sandboxPolicy {{"type":"dangerFullAccess"}}} {activePermissionProfile {{"id":"foreign-profile"}}}
    {disabledPluginIds ["foreign"]} {effort {"high"}} {multiAgentMode {"foreign"}}
    {collaborationMode {{"mode":"plan","settings":{"model":"fixture-model","reasoning_effort":null,"developer_instructions":"Native resolved preset"}}}}
    {model 4} {collaborationMode null} {unknownSetting null}
} {
    capacity_begin
    lassign $mutation key value
    huddle set capacitySettings params threadSettings $key [json_decode $value]
    capacity_echo
    completed $capacityTurn
    check {$retry::current eq "" && $automatic::current eq "" && [dict size $timers] == 0} "foreign/malformed settings retained recovery"
}
capacity_begin
capacity_echo
huddle set capacitySettings params threadSettings collaborationMode settings developer_instructions [huddle string "Changed instructions"]
capacity_echo
check {$retry::current eq "" && $automatic::current eq ""} "changed resolved instructions masqueraded as a repeated echo"
capacity_begin 1 0
capacity_echo
reply [json_dump $capacityId] wrong-turn
started $capacityTurn
completed $capacityTurn
check {[dict size $timers] == 0} "settings echo bypassed a mismatched start ACK"
capacity_begin
dict unset retry::current settings
capacity_echo
check {$retry::current eq "" && $automatic::current eq ""} "settings without activation proof retained ownership"
capacity_begin 0
capacity_client {{"id":"manual-rights","method":"thread/settings/update","params":{"threadId":"t1","approvalPolicy":"on-request"}}}
huddle set capacitySettings params threadSettings approvalPolicy [huddle string on-request]
huddle set capacitySettings params threadSettings sandboxPolicy [huddle create type [huddle string dangerFullAccess]]
retry::server [json_dump $capacitySettings]
set capacityId [huddle string after-manual-rights]
huddle set capacityRequest id $capacityId
huddle set capacityRequest params approvalPolicy [huddle string on-request]
capacity_client [json_dump $capacityRequest]
capacity_echo
reply [json_dump $capacityId] fresh-rights-turn
completed fresh-rights-turn
check {[dict size $timers] == 1} "new work could not verify its updated native permissions baseline"
foreach malformed {method thread params} {
    capacity_begin
    user_event item/started {{"type":"agentMessage","id":"malformed-settings-progress"}} $capacityTurn
    switch -- $malformed {
        method { huddle set capacitySettings method [huddle list [huddle string thread/settings/updated]] }
        thread { huddle set capacitySettings params threadId [huddle list [huddle string t1]] }
        params { huddle set capacitySettings params [huddle list] }
    }
    retry::server [json_dump $capacitySettings]
    completed $capacityTurn
    check {$automatic::current eq "" && $retry::current eq "" && [dict size $timers] == 0} \
        "malformed settings canceled only one recovery engine"
}

# Historical completed-goal proof survives both native bookkeeping paths and a
# delayed start ACK; neither path establishes this proof on its own.
capacity_begin 1 0
automatic::cancel
retry::reset
goal_read_fixture [goal_fixture complete]
set capacityId [huddle string capacity-historical-work]
huddle set capacityRequest id $capacityId
capacity_client [json_dump $capacityRequest]
capacity_echo
set preserved [capacity_state]
capacity_title [huddle string historical-title]
check {[capacity_state] eq $preserved} "title activation discarded completed-goal provenance"
started $capacityTurn
user_event item/started {{"type":"commandExecution","id":"historical-capacity-work"}} $capacityTurn
completed $capacityTurn
capacity_echo
check {[dict size $timers] == 0} "bookkeeping bypassed historical-goal start acknowledgement"
reply [json_dump $capacityId] $capacityTurn
set preserved [capacity_state]
goal_read_fixture [goal_fixture complete]
check {[capacity_state] eq $preserved && [dict size $timers] == 1} "bookkeeping expired unchanged historical-goal recovery"
fire
capacity_followup

# A helper can run concurrently, even before the foreground ACK. Its success,
# failure and cleanup preserve the foreground goal, selection, advice and timer.
foreach follow {0 1} {
    foreach early {0 1} {
        foreach outcome {completed failed} {
            capacity_begin $follow [expr {!$early}]
            goal_read_fixture
            capacity_echo
            set preserved [capacity_state]
            foreach id {702 {"702"}} thread {title-one title-two} {
                capacity_title [json_decode $id] $thread
                capacity_title_turn [huddle string helper-turn-$thread] $thread
                started helper-$thread $thread
            }
            check {[dict size $recovery::helpers] == 2} "typed helper IDs collided during concurrent work"
            foreach id {{"702"} 702} thread {title-two title-one} {
                retry::server [json_dump [huddle create id [json_decode $id] result [huddle create thread \
                    [huddle create id [huddle string $thread] threadSource [huddle string thread_title] ephemeral [huddle true]]]]]
                completed helper-$thread $outcome serverOverloaded {[]} $thread
                reply [json::write string helper-turn-$thread] helper-$thread
                reply [json::write string helper-turn-$thread] helper-$thread
                foreach status {active idle notLoaded systemError} {
                    retry::server [format {{"method":"thread/status/changed","params":{"threadId":"%s","status":{"type":"%s"}}}} $thread $status]
                }
                capacity_client [format {{"id":"unsubscribe-%s","method":"thread/unsubscribe","params":{"threadId":"%s"}}} $thread $thread]
                retry::server [format {{"id":"unsubscribe-%s","result":{}}} $thread]
                retry::server [format {{"method":"thread/deleted","params":{"threadId":"%s"}}} $thread]
            }
            check {[capacity_state] eq $preserved} "title helper changed foreground proof, backoff or selection"
            check {[string first {resume t1} [recovery::advice]] >= 0} "title helper became exit resume target"
            if {$early} { reply [json_dump $capacityId] $capacityTurn; started $capacityTurn }
            user_event item/started {{"type":"agentMessage","id":"foreground-output"}} $capacityTurn
            completed $capacityTurn
            set preserved [capacity_state]
            capacity_title [huddle string helper-during-backoff] backoff-title
            capacity_title_turn [huddle string backoff-title-turn] backoff-title
            reply {"backoff-title-turn"} title-success
            completed title-success completed serverOverloaded {[]} backoff-title
            check {[capacity_state] eq $preserved && [dict size $timers] == $follow} "helper success reset foreground backoff or bypassed opt-in"
            if {!$follow} { check {$sent eq ""} "helper replayed partial work"; continue }
            fire
            capacity_followup
            set followup [automatic::decode [lindex $sent end]]
            reply [json_dump [huddle get $followup id]] continued-turn
            started continued-turn
            user_event item/started {{"type":"agentMessage","id":"continued-output"}} continued-turn
            completed continued-turn
            check {[lindex $delays end] == 10000 && [dict size $timers] == 1} "helper activity reset exponential delay"
        }
    }
}

capacity_begin 0
capacity_echo
capacity_title [huddle string no-progress-title]
completed $capacityTurn
set preserved [capacity_state]
capacity_title_turn [huddle string no-progress-title-turn]
reply {"no-progress-title-turn"} no-progress-helper
completed no-progress-helper completed serverOverloaded {[]} title-thread
check {[capacity_state] eq $preserved && [dict size $timers] == 1} "helper success canceled default pre-progress replay"
fire
check {[huddle equal [huddle get [automatic::decode [lindex $sent end]] params] \
    [huddle get $capacityRequest params]]} "helper activity changed original-input replay"

# Only explicit, typed, correlated helper lifecycles are isolated.
foreach variant {source ephemeral collision no_foreground before_start_ack wrong_thread malformed_ack malformed_method contradictory_ack wrong_turn rejected_start rejected_turn} {
    capacity_begin
    capacity_echo
    set id [huddle string helper-negative-$variant]
    if {$variant eq "collision"} { set id $capacityId }
    set helper [huddle create id $id method [huddle string thread/start] \
        params [huddle create threadSource [huddle string thread_title] ephemeral [huddle true]]]
    if {$variant ni {source ephemeral no_foreground}} { capacity_client [json_dump $helper] }
    switch -- $variant {
        source - ephemeral - no_foreground {
            if {$variant eq "source"} { huddle set helper params threadSource [huddle string user] }
            if {$variant eq "ephemeral"} { huddle set helper params ephemeral [huddle string true] }
            if {$variant eq "no_foreground"} { set recovery::target ""; set automatic::selection {} }
            capacity_client [json_dump $helper]
        }
        before_start_ack { capacity_title_turn [huddle string premature-helper-turn] title-negative }
        wrong_thread - malformed_ack - contradictory_ack {
            set thread title-negative
            if {$variant eq "wrong_thread"} { set thread t1 }
            set result [huddle create thread [huddle create id [huddle string $thread] \
                ephemeral [huddle true] threadSource [huddle string thread_title]]]
            if {$variant eq "malformed_ack"} { huddle set result thread ephemeral [huddle string true] }
            retry::server [json_dump [huddle create id $id result $result]]
            if {$variant eq "contradictory_ack"} {
                huddle set result thread id [huddle string spoofed-helper]
                retry::server [json_dump [huddle create id $id result $result]]
            }
        }
        malformed_method { retry::server [json_dump [huddle create id $id method [huddle null] result [huddle create]]] }
        wrong_turn - rejected_turn {
            retry::server [json_dump [huddle create id $id result [huddle create thread \
                [huddle create id [huddle string title-negative] ephemeral [huddle true] threadSource [huddle string thread_title]]]]]
            capacity_title_turn [huddle string negative-title-turn] title-negative
            if {$variant eq "wrong_turn"} {
                started title-early title-negative
                reply {"negative-title-turn"} title-other
            } else {
                retry::server {{"id":"negative-title-turn","error":{"code":-1,"message":"helper unavailable"}}}
            }
        }
        rejected_start { retry::server [json_dump [huddle create id $id error [huddle create code [huddle number -1] message [huddle string unavailable]]]] }
    }
    completed $capacityTurn
    set expected [expr {$variant in {rejected_start rejected_turn}}]
    check {[dict size $timers] == $expected} "unproven helper lifecycle bypassed cancellation or helper rejection canceled foreground"
}
capacity_begin
capacity_title [huddle string duplicate-title] title-duplicate 0
set failed [catch {retry::server {{"id":"duplicate-title","result":{"thread":{"id":"title-duplicate","id":"spoofed","ephemeral":true,"threadSource":"thread_title"}}}}} message]
check {$failed && $message eq "duplicate JSON key" && $retry::current eq "" && $automatic::current eq "" &&
    $recovery::helpers eq "" && $recovery::helperRequests eq ""} "duplicate helper fields escaped typed rejection or retained authority"

# Display names are exact typed metadata. Real user changes still cancel both
# engines after helper activity and a verified own-settings echo.
foreach mutation {
    {{"method":"thread/settings/update","params":{"threadId":"t1","model":"fixture-model"}}}
    {{"method":"thread/resume","params":{"threadId":"other"}}}
    {{"method":"turn/steer","params":{"threadId":"t1","input":[]}}}
    {{"method":"thread/goal/set","params":{"threadId":"t1","objective":"new goal"}}}
    {{"method":"thread/settings/update","params":{"threadId":"t1","approvalPolicy":"on-request"}}}
    {{"method":"thread/name/set","params":{"threadId":"t1","name":true}}}
    {{"method":"thread/name/set","params":{"threadId":"t1","name":"title","model":"foreign"}}}
} {
    capacity_begin
    capacity_echo
    capacity_title [huddle string cancel-title]
    completed $capacityTurn
    capacity_client $mutation
    check {$retry::current eq "" && $automatic::current eq "" && [dict size $timers] == 0} "manual mutation survived helper isolation"
}
capacity_begin
set resume::armed 1
check {[catch {resume::client [json_dump [huddle create id [huddle string guarded-title] method [huddle string thread/start] \
    params [huddle create threadSource [huddle string thread_title] ephemeral [huddle true]]]]}]} \
    "a title helper consumed guarded startup permissions"
resume::reset
automatic::cancel
retry::reset
foreach name {helpers helperRequests} { set ::recovery::$name {} }

# Reviewer lifecycle/settings regressions use only public typed handlers.
foreach numeric {0 1} {
    foreach boundary {acknowledged unsubscribed changed_id_payload new_helper_turn manual_selection} {
        capacity_begin 0
        set titleStart [capacity_title [huddle string reused-title-start]]
        set id [huddle string 811]
        if {$numeric} { set id [huddle number 811] }
        set helper [capacity_title_turn $id]
        reply [json_dump $id] reused-helper-turn
        started reused-helper-turn title-thread
        set preserved [capacity_state]
        switch -- $boundary {
            unsubscribed {
                capacity_client {{"id":"reused-unsubscribe","method":"thread/unsubscribe","params":{"threadId":"title-thread"}}}
                retry::server {{"id":"reused-unsubscribe","result":{}}}
            }
            changed_id_payload { huddle set helper params input 0 text [huddle string "Changed helper work"] }
            new_helper_turn { huddle set helper id [huddle string new-rejected-helper-turn] }
            manual_selection {
                capacity_client {{"id":"manual-after-helper","method":"thread/resume","params":{"threadId":"other"}}}
            }
        }
        if {$boundary in {acknowledged unsubscribed}} {
            capacity_client [json_dump $titleStart]
            retry::server {{"id":"reused-title-start","result":{"thread":{"id":"title-thread","threadSource":"thread_title","ephemeral":true}}}}
        }
        capacity_client [json_dump $helper]
        reply [json_dump [huddle get $helper id]] reused-helper-turn
        completed reused-helper-turn failed serverOverloaded {[]} title-thread
        capacity_client [json_dump $helper]
        reply [json_dump [huddle get $helper id]] reused-helper-turn
        completed reused-helper-turn failed serverOverloaded {[]} title-thread
        check {[dict size $timers] == 0 && $sent eq ""} "post-ACK helper reuse authorized replay"
        if {$boundary in {acknowledged unsubscribed}} {
            check {[capacity_state] eq $preserved} "an exact post-ACK helper repeat changed foreground ownership"
            completed $capacityTurn
            fire
            check {[huddle equal [huddle get [automatic::decode [lindex $sent end]] params] \
                [huddle get $capacityRequest params]]} "helper repeat displaced foreground replay"
        } else {
            check {$retry::current eq "" && $automatic::current eq ""} "a rejected helper request entered foreground tracking"
        }
    }
}
capacity_begin 0
capacity_title [huddle string malformed-start-provenance] title-rejected 0
retry::server {{"id":"malformed-start-provenance","result":{"thread":{"id":"title-rejected","threadSource":"thread_title","ephemeral":"true"}}}}
set helper [capacity_title_turn [huddle string after-malformed-helper] title-rejected]
reply [json_dump [huddle get $helper id]] unproven-helper-turn
completed unproven-helper-turn failed serverOverloaded {[]} title-rejected
check {$retry::current eq "" && $automatic::current eq "" && [dict size $timers] == 0 && $sent eq ""} \
    "a rejected helper activation later authorized helper replay"
capacity_begin 0
capacity_title [huddle string pending-helper-start] title-unproven 0
set helper [capacity_title_turn [huddle string before-helper-start-ack] title-unproven]
reply [json_dump [huddle get $helper id]] before-helper-start-turn
completed before-helper-start-turn failed serverOverloaded {[]} title-unproven
check {$retry::current eq "" && $automatic::current eq "" && [dict size $timers] == 0 && $sent eq ""} \
    "unproven work before a helper start ACK authorized replay"

# Omitted sandbox defaults and explicit defaults describe the same policy.
foreach minimal {
    {{"type":"readOnly"}}
    {{"type":"workspaceWrite"}}
    {{"type":"externalSandbox"}}
} effective {
    {{"type":"readOnly","networkAccess":false}}
    {{"type":"workspaceWrite","networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false,"writableRoots":[]}}
    {{"type":"externalSandbox","networkAccess":"restricted"}}
} {
    foreach early {0 1} {
        foreach reverse {0 1} {
            set requested [json_decode $minimal]
            set notified [json_decode $effective]
            if {$reverse} { lassign [list $notified $requested] requested notified }
            capacity_begin 0 [expr {!$early}] 0 "" [huddle create sandboxPolicy $requested]
            huddle set capacitySettings params threadSettings sandboxPolicy $notified
            capacity_echo
            if {$early} {
                check {![field $retry::current accepted] && [dict size $timers] == 0} "sandbox defaults granted start authority"
                reply [json_dump $capacityId] $capacityTurn
            }
            completed $capacityTurn
            check {[dict size $timers] == 1} "equivalent sandbox defaults canceled recovery"
            fire
            check {[huddle equal [huddle get [automatic::decode [lindex $sent end]] params] \
                [huddle get $capacityRequest params]]} "sandbox normalization rewrote original settings"
        }
    }
}
foreach policy {
    {{"type":"readOnly","networkAccess":"false"}}
    {{"type":"readOnly","networkAccess":null}}
    {{"type":"dangerFullAccess","networkAccess":false}}
    {{"type":"workspaceWrite","excludeSlashTmp":0}}
    {{"type":"workspaceWrite","writableRoots":[4]}}
    {{"type":"externalSandbox","networkAccess":false}}
    {{"type":"externalSandbox","networkAccess":"unknown"}}
} {
    capacity_begin 0
    huddle set capacitySettings params threadSettings sandboxPolicy [json_decode $policy]
    capacity_echo
    completed $capacityTurn
    check {$retry::current eq "" && [dict size $timers] == 0} "malformed sandbox defaults retained recovery"
}

# Persistent serviceTier changes the thread; serviceTierForTurn does not.
foreach early {0 1} {
    foreach variant {persistent turn_only combined} {
        set overrides [huddle create serviceTierForTurn [huddle string default]]
        set tier [huddle null]
        if {$variant ne "turn_only"} {
            huddle set overrides serviceTier [huddle string fast]
            set tier [huddle string fast]
        }
        if {$variant eq "persistent"} { set overrides [huddle remove $overrides serviceTierForTurn] }
        capacity_begin 0 [expr {!$early}] 0 "" $overrides
        huddle set capacitySettings params threadSettings serviceTier $tier
        capacity_echo
        if {$early} {
            check {![field $retry::current accepted] && [dict size $timers] == 0} "service tier echo granted start authority"
            reply [json_dump $capacityId] $capacityTurn
        }
        completed $capacityTurn
        check {[dict size $timers] == 1} "matching persistent/turn-only service tiers canceled recovery"
        fire
        check {[huddle equal [huddle get [automatic::decode [lindex $sent end]] params] \
            [huddle get $capacityRequest params]]} "service tier recovery changed request settings"
    }
}
capacity_begin 0 1 0 "" [huddle create serviceTier [huddle string fast] serviceTierForTurn [huddle string default]]
huddle set capacitySettings params threadSettings serviceTier [huddle string default]
capacity_echo
check {$retry::current eq "" && [dict size $timers] == 0} "turn-only service tier was mistaken for a persistent echo"

# Granular approval policies are typed variants with two default-false fields.
set granular [json_decode {{"granular":{"sandbox_approval":true,"rules":false,"mcp_elicitations":true}}}]
set explicitGranular $granular
huddle set explicitGranular granular request_permissions [huddle false]
huddle set explicitGranular granular skill_approval [huddle false]
foreach early {0 1} {
    foreach origin {activation inline} {
        set baseline [huddle create]
        set overrides [huddle create approvalPolicy [huddle null]]
        if {$origin eq "activation"} {
            huddle set baseline approvalPolicy $granular
        } else { huddle set overrides approvalPolicy $granular }
        capacity_begin 0 [expr {!$early}] 0 $baseline $overrides
        huddle set capacitySettings params threadSettings approvalPolicy $explicitGranular
        capacity_echo
        if {$early} {
            check {![field $retry::current accepted] && [dict size $timers] == 0} "granular policy echo granted start authority"
            reply [json_dump $capacityId] $capacityTurn
        }
        completed $capacityTurn
        check {[dict size $timers] == 1} "unchanged granular policy canceled recovery"
        fire
        check {[huddle equal [huddle get [automatic::decode [lindex $sent end]] params] \
            [huddle get $capacityRequest params]]} "granular policy normalization rewrote the request"
    }
}
capacity_begin 0 1 0 [huddle create approvalPolicy $granular] [huddle create approvalPolicy [huddle null]]
huddle set capacitySettings params threadSettings approvalPolicy $explicitGranular
huddle set capacitySettings params threadSettings approvalPolicy granular rules [huddle true]
capacity_echo
check {$retry::current eq "" && [dict size $timers] == 0} "a changed granular approval policy preserved ownership"
set optionalGranular $explicitGranular
huddle set optionalGranular granular request_permissions [huddle true]
huddle set optionalGranular granular skill_approval [huddle true]
capacity_begin 0 1 0 "" [huddle create approvalPolicy $optionalGranular]
huddle set capacitySettings params threadSettings approvalPolicy $optionalGranular
capacity_echo
completed $capacityTurn
check {[dict size $timers] == 1} "explicit granular approval flags were replaced by defaults"
capacity_begin 0 1 0 [huddle create approvalPolicy $optionalGranular] [huddle create approvalPolicy [huddle null]]
huddle set capacitySettings params threadSettings approvalPolicy $explicitGranular
capacity_echo
check {$retry::current eq "" && [dict size $timers] == 0} "changed optional granular approval flags were mistaken for defaults"
foreach policy {
    {"unknown"}
    {{"granular":[]}}
    {{"granular":{"sandbox_approval":true,"mcp_elicitations":true}}}
    {{"granular":{"sandbox_approval":"true","rules":false,"mcp_elicitations":true}}}
    {{"granular":{"sandbox_approval":true,"rules":false,"mcp_elicitations":true,"request_permissions":null}}}
    {{"granular":{"sandbox_approval":true,"rules":false,"mcp_elicitations":true,"skill_approval":0}}}
    {{"granular":{"sandbox_approval":true,"rules":false,"mcp_elicitations":true,"unknown":false}}}
    {{"granular":{"sandbox_approval":true,"rules":false,"mcp_elicitations":true},"other":{}}}
} {
    foreach origin {activation inline notification} {
        set baseline [huddle create]
        set overrides [huddle create]
        if {$origin eq "activation"} { huddle set baseline approvalPolicy [json_decode $policy] }
        if {$origin eq "inline"} { huddle set overrides approvalPolicy [json_decode $policy] }
        capacity_begin 0 1 0 $baseline $overrides
        if {$origin eq "notification"} { huddle set capacitySettings params threadSettings approvalPolicy [json_decode $policy] }
        capacity_echo
        completed $capacityTurn
        check {$retry::current eq "" && [dict size $timers] == 0} "a malformed granular policy retained recovery"
    }
}
automatic::cancel
retry::reset
foreach name {helpers helperRequests} { set ::recovery::$name {} }

# A rejected reply's thread ID is not helper classification. Fresh manual
# activation supersedes stale classification while old helper RPC IDs stay inert.
foreach follow {0 1} {
    foreach history {malformed contradictory closed pending verified} {
        capacity_begin $follow
        set titleThread title-original
        if {$history eq "verified"} { set titleThread other }
        capacity_title [huddle string resume-helper-start] $titleThread [expr {$history ni {malformed pending}}]
        set unverified [automatic::decode {{"id":"resume-helper-start","result":{"thread":{"id":"other","threadSource":"thread_title","ephemeral":"true"}}}}]
        switch -- $history {
            malformed - contradictory { retry::server [json_dump $unverified] }
            closed {
                capacity_client {{"id":"resume-helper-unsubscribe","method":"thread/unsubscribe","params":{"threadId":"title-original"}}}
                retry::server {{"id":"resume-helper-unsubscribe","result":{}}}
                retry::server [json_dump $unverified]
            }
            verified {
                capacity_title_turn [huddle string resume-old-title-turn] other
                reply {"resume-old-title-turn"} old-title-turn
                completed old-title-turn completed serverOverloaded {[]} other
            }
        }
        capacity_client {{"id":"fresh-manual-resume","method":"thread/resume","params":{"threadId":"other"}}}
        set activation [capacity_activation other]
        huddle set activation thread ephemeral [huddle false]
        huddle set activation thread threadSource [huddle string user]
        retry::server [json_dump [huddle create id [huddle string fresh-manual-resume] result $activation]]
        set goal [goal_fixture]
        huddle set goal threadId [huddle string other]
        capacity_client {{"id":"other-goal-read","method":"thread/goal/get","params":{"threadId":"other"}}}
        retry::server [json_dump [huddle create id [huddle string other-goal-read] result [huddle create goal $goal]]]
        huddle set capacityRequest id [huddle string other-foreground-request]
        huddle set capacityRequest params threadId [huddle string other]
        capacity_client [json_dump $capacityRequest]
        huddle set capacitySettings params threadId [huddle string other]
        capacity_echo
        check {[field $retry::current accepted] eq "0" && [dict size $timers] == 0} \
            "manual resume lost foreground tracking or settings granted start authority"
        reply {"other-foreground-request"} other-foreground-turn
        started other-foreground-turn other
        set preserved [capacity_state]
        retry::server [json_dump $unverified]
        retry::server [json_dump $unverified]
        if {$history eq "verified"} { reply {"resume-old-title-turn"} old-title-turn }
        check {[capacity_state] eq $preserved} "a late helper reply changed freshly selected foreground ownership"
        if {$follow} {
            user_event item/started {{"type":"commandExecution","id":"other-foreground-progress"}} other-foreground-turn other
        }
        completed other-foreground-turn failed serverOverloaded {[]} other
        check {[dict size $timers] == 1 && $sent eq "" && $recovery::target eq "other"} \
            "stale helper provenance suppressed recovery in a freshly resumed thread"
        fire
        set work [automatic::decode [lindex $sent end]]
        check {[automatic::text $work params threadId] eq "other"} "manual resume recovered in the wrong thread"
        if {$follow} {
            check {[automatic::text $work params input 0 text] eq "continue"} "manual resume replayed progressed work"
        } else {
            check {[huddle equal [huddle get $work params] [huddle get $capacityRequest params]]} \
                "manual resume changed original-input replay"
        }
        reply [json_dump [huddle get $work id]] other-recovery-turn
        started other-recovery-turn other
        if {$follow} {
            user_event item/started {{"type":"commandExecution","id":"other-recovery-progress"}} other-recovery-turn other
        }
        completed other-recovery-turn failed serverOverloaded {[]} other
        check {[dict size $timers] == 1} "resumed foreground lost its recovery chain"
        if {$follow} {
            huddle set capacitySettings params threadSettings model [huddle string changed-model]
            retry::server [json_dump $capacitySettings]
        } else {
            huddle set goal status [huddle string paused]
            retry::server [json_dump [huddle create method [huddle string thread/goal/updated] params \
                [huddle create threadId [huddle string other] turnId [huddle string other-recovery-turn] goal $goal]]]
        }
        check {$retry::current eq "" && $automatic::current eq "" && [dict size $timers] == 0} \
            "stale helper classification swallowed foreground settings or goal changes"
    }
}
automatic::cancel
retry::reset
foreach name {helpers helperRequests} { set ::recovery::$name {} }

# A valid helper start can be acknowledged on either side of a manual switch.
# Its later work must preserve the new foreground, including an existing timer.
foreach ordering {before_switch after_switch} {
    foreach stage {awaiting running backoff} {
        foreach follow {0 1} {
            foreach progress {0 1} {
                capacity_begin $follow
                capacity_title [huddle string switch-helper-start] switch-title 0
                set helperAck {{"id":"switch-helper-start","result":{"thread":{"id":"switch-title","threadSource":"thread_title","ephemeral":true}}}}
                if {$ordering eq "before_switch"} { retry::server $helperAck }
                capacity_client {{"id":"switch-foreground-resume","method":"thread/resume","params":{"threadId":"other"}}}
                retry::server [json_dump [huddle create id [huddle string switch-foreground-resume] \
                    result [capacity_activation other]]]
                set goal [goal_fixture]
                huddle set goal threadId [huddle string other]
                capacity_client {{"id":"switch-goal-read","method":"thread/goal/get","params":{"threadId":"other"}}}
                retry::server [json_dump [huddle create id [huddle string switch-goal-read] result [huddle create goal $goal]]]
                huddle set capacityRequest id [huddle string switch-foreground-work]
                huddle set capacityRequest params threadId [huddle string other]
                capacity_client [json_dump $capacityRequest]
                huddle set capacitySettings params threadId [huddle string other]
                capacity_echo
                if {$stage ne "awaiting"} { reply {"switch-foreground-work"} switch-main-turn }
                started switch-main-turn other
                if {$progress} {
                    user_event item/started {{"type":"commandExecution","id":"switch-main-progress"}} switch-main-turn other
                }
                if {$stage eq "backoff"} { completed switch-main-turn failed serverOverloaded {[]} other }
                set preserved [capacity_state]
                if {$ordering eq "after_switch"} { retry::server $helperAck }
                capacity_title_turn [huddle string switch-helper-turn] switch-title
                started switch-title-turn switch-title
                reply {"switch-helper-turn"} switch-title-turn
                completed switch-title-turn completed serverOverloaded {[]} switch-title
                retry::server {{"method":"thread/status/changed","params":{"threadId":"switch-title","status":{"type":"idle"}}}}
                capacity_client {{"id":"switch-helper-unsubscribe","method":"thread/unsubscribe","params":{"threadId":"switch-title"}}}
                retry::server {{"id":"switch-helper-unsubscribe","result":{}}}
                check {[capacity_state] eq $preserved} "delayed helper lifecycle changed the new foreground or its backoff"
                if {$stage eq "awaiting"} {
                    check {[field $retry::current accepted] eq "0" && [dict size $timers] == 0} \
                        "delayed helper activity acknowledged the new foreground"
                    reply {"switch-foreground-work"} switch-main-turn
                }
                if {$stage ne "backoff"} { completed switch-main-turn failed serverOverloaded {[]} other }
                set eligible [expr {!$progress || $follow}]
                check {[dict size $timers] == $eligible && $sent eq "" && $recovery::target eq "other"} \
                    "delayed title helper canceled recovery or bypassed its opt-in after a switch"
                if {$eligible} {
                    check {[lindex $delays end] == 5000} "switched helper changed foreground recovery delay"
                    fire
                    set work [automatic::decode [lindex $sent end]]
                    check {[automatic::text $work params threadId] eq "other"} "switched helper became the recovery target"
                    if {$progress} {
                        check {[automatic::text $work params input 0 text] eq "continue"} "switched helper caused partial-work replay"
                    } else {
                        check {[huddle equal [huddle get $work params] [huddle get $capacityRequest params]]} \
                            "switched helper changed the original foreground request"
                    }
                }
            }
        }
    }
}
automatic::cancel
retry::reset
foreach name {helpers helperRequests} { set ::recovery::$name {} }

# Native inbox acknowledgements must preserve overload recovery after tool work,
# including acknowledgement ordering, backoff, and rejected metadata revisions.
foreach reset {0 1} {
    foreach follow {0 1} {
        foreach stage {before_ack completed_before_ack running backoff} {
            auto_begin $reset $follow [expr {$stage in {running backoff}}]
            if {$stage in {before_ack completed_before_ack}} { started $autoTurn }
            user_event item/started {{"type":"commandExecution","id":"read-state-progress"}} $autoTurn
            if {$stage in {completed_before_ack backoff}} { completed $autoTurn }
            set previous [list $automatic::current $automatic::selection $automatic::timer \
                $retry::current $retry::timer $retry::delay $timers]
            foreach operation {read unread} {
                foreach thread {t1 metadata-other-thread} {
                    foreach outcome {success conflict} {
                        set update [::huddle::json2huddle [metadata_read thread/readState/update $thread]]
                        huddle set update params operation type [huddle string $operation]
                        retry::client [json_dump $update]
                        set response [huddle create id [huddle get $update id]]
                        if {$outcome eq "conflict"} {
                            huddle set response error [huddle create code [huddle number -32000] \
                                message [huddle string "fixture revision conflict"]]
                        } else {
                            set firstUnread [huddle null]
                            if {$operation eq "unread"} { set firstUnread [huddle create type [huddle string threadStart]] }
                            set readState [huddle create revision [huddle string updated-revision] firstUnread $firstUnread]
                            huddle set response result [huddle create readState $readState]
                            retry::server [json_dump [huddle create method [huddle string thread/readState/changed] \
                                params [huddle create threadId [huddle string $thread] readState $readState]]]
                        }
                        check {[retry::server [json_dump $response]] == 1} "inbox metadata reply was hidden"
                    }
                }
            }
            check {[list $automatic::current $automatic::selection $automatic::timer \
                $retry::current $retry::timer $retry::delay $timers] eq $previous} \
                "read/unread metadata or its reply changed partial-work recovery"
            if {$stage in {before_ack completed_before_ack}} {
                check {[dict size $timers] == 0} "inbox metadata acknowledged model work"
                reply $autoId $autoTurn
            }
            if {$stage in {before_ack running}} { completed $autoTurn }
            completed $autoTurn
            check {[dict size $timers] == $follow && $sent eq ""} "inbox metadata bypassed opt-in or overload backoff"
            if {$follow} {
                check {[lindex $delays end] == 5000} "inbox metadata reset overload backoff"
                fire
                auto_followup
                check {[llength $sent] == 1} "inbox metadata duplicated recovery or replayed partial work"
            }
        }
    }
}
foreach method {thread/queue/list thread/backgroundTerminals/list thread/items/read thread/timeline/list} {
    auto_backoff
    foreach thread {t1 metadata-other-thread} { retry::client [metadata_read $method $thread] }
    fire
    auto_followup
}
auto_begin 1 1
completed $autoTurn failed cyberPolicy
retry::client {{"method":"thread/fixture/list","params":{"threadId":"t1"}}}
check {$automatic::current eq "" && [dict size $timers] == 0} "an unknown method was treated as an installed read"

auto_until read
set pending [dict get $automatic::current opId]
check {[retry::server [format {{"id":%s,"method":"fixture/question","params":{}}} $pending]] == 1} "a server request sharing an internal ID was hidden"
auto_reply $exhausted
check {[field $automatic::current phase] eq "consume_ready"} "a server request consumed an internal reply marker"
foreach method {fixture/read thread/readState/update} {
    auto_begin 0 1 0
    # Without reservation this ID would be used by the continuation's RPC,
    # after its freshly generated clientUserMessageId.
    set collision [huddle string "$retry::prefix-[expr {$retry::sequence + 2}]"]
    set metadata [::huddle::json2huddle [metadata_read $method t1]]
    huddle set metadata id $collision
    retry::client [json_dump $metadata]
    reply [json_dump $collision] $autoTurn
    check {![field $automatic::current accepted] && ![field $retry::current accepted] && \
        [dict size $timers] == 0} "a metadata reply acknowledged model work"
    reply $autoId $autoTurn
    completed $autoTurn failed cyberPolicy
    fire
    check {[auto_followup] ne [json_dump $collision]} "automatic request collided with a native ID"
}

# Capacity failures after partial work need a new neutral turn, never a replay.
foreach reset {0 1} {
    foreach follow {0 1} {
        foreach progress {event snapshot} {
            auto_begin $reset $follow
            set items {[]}
            if {$progress eq "event"} {
                retry::server [format {{"method":"item/commandExecution/outputDelta","params":{"threadId":"t1","turnId":"%s","delta":"partial tool output"}}} $autoTurn]
            } else { set items {[{"type":"commandExecution","id":"already-applied"}]} }
            completed $autoTurn failed serverOverloaded $items
            completed $autoTurn failed serverOverloaded $items
            check {[dict size $timers] == $follow && $sent eq ""} "partial overload ignored opt-in or acted before backoff"
            if {$follow} {
                check {[lindex $delays end] == 5000} "partial overload skipped its initial delay"
                fire
                auto_followup
                check {[llength $sent] == 1} "partial overload repeated original work or consumed a reset"
            }
        }
    }
}

# Automatic compaction is owned progress in both protocol forms, even by itself.
foreach reset {0 1} {
    foreach follow {0 1} {
        foreach form {legacy item} {
            auto_begin $reset $follow
            if {$form eq "legacy"} {
                compacted $autoTurn
                compacted $autoTurn
            } else {
                user_event item/started {{"type":"contextCompaction","id":"compaction"}} $autoTurn
                user_event item/completed {{"type":"contextCompaction","id":"compaction"}} $autoTurn
            }
            check {[field $retry::current progress] == 1} "compaction did not prevent original-input replay"
            if {$reset || $follow} {
                check {[field $automatic::current turnId] eq $autoTurn && \
                    [field $automatic::current progress] == 1} "automatic compaction lost owned recovery tracking"
            }
            completed $autoTurn
            set pending $timers
            completed $autoTurn
            check {$timers eq $pending && [dict size $timers] == $follow && $sent eq ""} "compaction ignored opt-in or duplicated recovery"
            if {$follow} {
                check {[lindex $delays end] == 5000} "compaction skipped overload backoff"
                fire
                auto_followup
                check {[llength $sent] == 1} "compaction replayed original work or requested an account reset"
            }
        }
    }
}

# Legacy compaction follows the same early-start and acknowledgement guards.
foreach ordering {before-ack completed-before-ack reply-without-start} {
    auto_begin 1 1 0
    if {$ordering eq "reply-without-start"} { reply $autoId $autoTurn } else { started $autoTurn }
    compacted $autoTurn
    compacted $autoTurn
    if {$ordering ne "before-ack"} { completed $autoTurn }
    if {$ordering ne "reply-without-start"} {
        reply {"unrelated-compaction-reply"} $autoTurn
        check {[dict size $timers] == 0} "compaction or a foreign reply acknowledged recovery"
        reply $autoId $autoTurn
    }
    if {$ordering eq "before-ack"} { completed $autoTurn }
    check {[dict size $timers] == 1} "correlated early compaction lost acknowledged recovery"
    fire
    auto_followup
}
foreach follow {0 1} {
    auto_begin 0 $follow 0
    compacted $autoTurn
    started $autoTurn
    completed $autoTurn
    reply $autoId $autoTurn
    check {[dict size $timers] == 0 && $sent eq ""} "compaction before a start candidate established recovery or allowed replay"
}
auto_begin 0 1 0
started $autoTurn
compacted $autoTurn
completed $autoTurn
reply $autoId different-compaction-turn
check {$automatic::current eq "" && $retry::current eq "" && [dict size $timers] == 0} "a mismatched acknowledgement adopted compacted work"

# Foreign threads and already finished turns are neutral; live foreign turns
# and ambiguous IDs cannot preserve recovery or resurrect it at acknowledgement.
completed finished-before-compaction completed
foreach follow {0 1} {
    auto_begin 0 $follow
    set previous [list $automatic::current $retry::current $timers]
    compacted $autoTurn other-thread
    compacted finished-before-compaction
    check {[list $automatic::current $retry::current $timers] eq $previous} "unrelated compaction changed current ownership"
    completed $autoTurn
    fire
    check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
        [huddle get $autoRequest params]]} "unrelated compaction prevented an otherwise safe original-input retry"
    foreach ordering {before-start before-ack running} {
        auto_begin 0 $follow 0
        if {$ordering ne "before-start"} { started $autoTurn }
        if {$ordering eq "running"} { reply $autoId $autoTurn }
        compacted live-foreign-compaction
        if {$ordering eq "before-start"} { started $autoTurn }
        if {$ordering ne "running"} { reply $autoId $autoTurn }
        completed $autoTurn
        check {$automatic::current eq "" && $retry::current eq "" && \
            [dict size $timers] == 0 && $sent eq ""} "foreign compaction allowed recovery"
    }
    foreach {duplicate params} {
        0 {"turnId":"@TURN@"}
        0 {"threadId":null,"turnId":"@TURN@"}
        0 {"threadId":"","turnId":"@TURN@"}
        0 {"threadId":["t1"],"turnId":"@TURN@"}
        0 {"threadId":"t1"}
        0 {"threadId":"t1","turnId":null}
        0 {"threadId":"t1","turnId":""}
        0 {"threadId":"t1","turnId":1}
        0 {"threadId":"t1","turnId":["@TURN@"]}
        1 {"threadId":"other","threadId":"t1","turnId":"@TURN@"}
        1 {"threadId":"t1","turnId":"foreign","turnId":"@TURN@"}
    } {
        auto_begin 0 $follow
        set event [format {{"method":"thread/compacted","params":{%s}}} \
            [string map [list @TURN@ $autoTurn] $params]]
        if {$duplicate} { reject_duplicate {retry::server $event} } else { retry::server $event }
        completed $autoTurn
        check {$automatic::current eq "" && $retry::current eq "" && \
            [dict size $timers] == 0 && $sent eq ""} "ambiguous compaction allowed recovery"
    }
}

# Manual compaction and progress arriving after failure still cancel recovery.
foreach stage {running backoff} {
    auto_begin 1 1
    compacted $autoTurn
    if {$stage eq "backoff"} { completed $autoTurn }
    retry::client {{"id":"manual-compact","method":"thread/compact/start","params":{"threadId":"t1"}}}
    completed $autoTurn
    check {$automatic::current eq "" && $retry::current eq "" && $retry::delay == 5000 && \
        [dict size $timers] == 0 && $sent eq ""} "manual compaction retained recovery or backoff"
}
foreach follow {0 1} {
    auto_begin 0 $follow
    if {$follow} { compacted $autoTurn }
    completed $autoTurn
    check {[dict size $timers] == 1} "expected queued overload recovery before late compaction"
    compacted $autoTurn
    completed $autoTurn
    check {[dict size $timers] == 0 && $sent eq ""} "late compaction left queued recovery armed"
}

# Substantial work and repeated compacted follow-ups retain shared backoff;
# success and new manual work reset it as usual.
foreach ending {success manual} {
    auto_begin 1 1
    set turn $autoTurn
    foreach delay {5000 10000} {
        user_event item/completed {{"type":"commandExecution","id":"applied-tool"}} $turn
        compacted $turn
        completed $turn
        check {[dict size $timers] == 1 && [lindex $delays end] == $delay} "compaction lost shared overload backoff"
        fire
        set id [auto_followup]
        completed $turn
        compacted $turn
        check {[dict size $timers] == 0} "a stale compacted failure repeated recovery"
        set turn compacted-followup-$autoSequence-$delay
        reply $id $turn
        started $turn
    }
    if {$ending eq "success"} {
        compacted $turn
        completed $turn completed
    } else {
        compacted $turn
        completed $turn
        huddle set autoRequest id [huddle string manual-after-compaction-$autoSequence]
        retry::client [json_dump $autoRequest]
    }
    check {$retry::delay == 5000 && [dict size $timers] == 0} "success or manual work did not reset compaction backoff"
}

# Original-input retries and new follow-ups share one exponential sequence.
auto_begin 0 1
set turn $autoTurn
set index 0
foreach delay {5000 10000 20000 40000 80000 160000 320000 640000 1280000 1800000 1800000} {
    set items {[]}
    if {$index % 2 == 0} { set items {[{"type":"agentMessage","id":"partial","text":"partial response"}]} }
    completed $turn failed serverOverloaded $items
    completed $turn failed serverOverloaded $items
    check {[dict size $timers] == 1 && [lindex $delays end] == $delay} "mixed overload recovery lost backoff or duplicated its timer"
    set previous [list $automatic::current $retry::current $retry::delay $timers]
    foreach thread {t1 metadata-other-thread} { retry::client [metadata_read thread/readState/update $thread] }
    check {[list $automatic::current $retry::current $retry::delay $timers] eq $previous} \
        "inbox metadata changed accumulated overload backoff"
    fire
    set id [auto_followup]
    completed $turn failed serverOverloaded $items
    check {[dict size $timers] == 0} "a stale overload re-armed recovery"
    incr index
    set turn overload-followup-$autoSequence-$index
    reply $id $turn
    started $turn
}
completed $turn completed
check {$retry::delay == 5000 && [dict size $timers] == 0} "success did not reset mixed overload backoff"

# Manual changes, foreign work and late progress invalidate a pending follow-up.
foreach {side event} {
    client {{"method":"turn/interrupt","params":{"threadId":"t1","turnId":"ignored"}}}
    client {{"method":"account/logout","params":{}}}
    client {{"method":"thread/settings/update","params":{"threadId":"t1","model":"different"}}}
    server {{"method":"account/updated","params":{}}}
    server {{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"foreign-capacity-turn","status":"inProgress","items":[]}}}}
    server {{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"@TURN@","delta":"late progress"}}}
} {
    auto_begin 0 1
    completed $autoTurn failed serverOverloaded {[{"type":"commandExecution","id":"already-applied"}]}
    check {[dict size $timers] == 1} "partial overload did not queue before cancellation"
    set event [string map [list @TURN@ $autoTurn] $event]
    retry::$side $event
    completed $autoTurn failed serverOverloaded
    check {$automatic::current eq "" && [dict size $timers] == 0 && $sent eq ""} "invalidated capacity follow-up remained armed"
}
auto_begin 0 1
completed $autoTurn failed serverOverloaded {[{"type":"commandExecution","id":"already-applied"}]}
retry::client [metadata_read thread/read metadata-other-thread]
fire
auto_followup
check {$retry::delay == 10000} "read-only metadata reset capacity follow-up backoff"

# Early terminal snapshots still require the matching start acknowledgement.
auto_begin 0 1 0
started $autoTurn t1 {[{"type":"commandExecution","id":"already-applied"}]}
completed $autoTurn failed serverOverloaded
check {[dict size $timers] == 0} "unacknowledged partial overload continued"
reply $autoId $autoTurn
check {[dict size $timers] == 1 && [lindex $delays end] == 5000} "early partial overload lost its acknowledged recovery"
fire
auto_followup

# Late progress in duplicate start replies or notifications has the same effect
# as progress in a repeated completion, without replacing a valid timer.
foreach snapshot {reply started} {
    foreach change {same late} {
        auto_begin 0 1
        set items {[{"type":"commandExecution","id":"applied-tool"}]}
        completed $autoTurn failed serverOverloaded $items
        set pending $timers
        if {$change eq "late"} { set items {[{"type":"agentMessage","id":"late-response","text":"late"}]} }
        if {$snapshot eq "reply"} { reply $autoId $autoTurn $items } else { started $autoTurn t1 $items }
        if {$change eq "same"} {
            check {$timers eq $pending} "duplicate start snapshot replaced overload backoff"
            fire
            auto_followup
        } else {
            check {$automatic::current eq "" && [dict size $timers] == 0 && $sent eq ""} "late start snapshot progress left recovery armed"
        }
    }
}

# Metadata stays neutral before acknowledgement and during original-input backoff,
# independently of the optional flags and ownership of an automatic continuation.
foreach reset {0 1} {
    foreach follow {0 1} {
        foreach stage {awaiting running backoff} {
            auto_begin $reset $follow 0
            if {$stage ne "awaiting"} { reply $autoId $autoTurn; started $autoTurn }
            if {$stage eq "backoff"} { completed $autoTurn failed serverOverloaded }
            set previous [list $automatic::current $retry::current $retry::delay $timers]
            foreach method {thread/turns/list thread/readState/update} {
                foreach thread {t1 metadata-other-thread} { retry::client [metadata_read $method $thread] }
            }
            check {[list $automatic::current $retry::current $retry::delay $timers] eq $previous} "metadata read canceled original work or reset its backoff"
            if {$stage eq "awaiting"} { reply $autoId $autoTurn; started $autoTurn }
            if {$stage ne "backoff"} { completed $autoTurn failed serverOverloaded }
            fire
            check {[llength $sent] == 1 && [huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
                [huddle get $autoRequest params]]} "metadata read changed original-input replay"
        }
    }
}

# Repeated terminal snapshots can repeat known progress, but new or changed
# work cancels recovery, including when acknowledgement has not arrived yet.
foreach mode {stop limit replay followup} {
    foreach acknowledge {0 1} {
        foreach change {same sparse additional updated} {
            auto_begin 1 1 $acknowledge
            if {!$acknowledge} { started $autoTurn }
            set code [dict get {stop cyberPolicy limit usageLimitExceeded replay serverOverloaded followup serverOverloaded} $mode]
            set items {[{"type":"commandExecution","id":"applied-tool","status":"completed"}]}
            if {$mode eq "replay"} { set items {[]} }
            completed $autoTurn failed $code $items
            set pending $timers
            set duplicate $items
            if {$change eq "same" && $mode ne "replay"} {
                set duplicate {[{"status":"completed","id":"applied-tool","type":"commandExecution"}]}
            } elseif {$change eq "sparse"} {
                set duplicate {[]}
            } elseif {$change eq "additional"} {
                set duplicate [string replace $items end end {,{"type":"agentMessage","id":"late-response","text":"late"}]}]
                if {$mode eq "replay"} { set duplicate {[{"type":"agentMessage","id":"late-response","text":"late"}]} }
            } elseif {$change eq "updated"} {
                set duplicate {[{"type":"commandExecution","id":"applied-tool","status":"completed","aggregatedOutput":"late output"}]}
            }
            completed $autoTurn failed $code $duplicate
            if {$change eq "sparse"} { completed $autoTurn failed $code $items }
            if {$change in {same sparse}} { check {$timers eq $pending} "repeated progress snapshot replaced recovery's timer" }
            if {!$acknowledge} { reply $autoId $autoTurn }
            if {$change in {same sparse}} {
                check {[dict size $timers] == 1} "identical progress snapshot canceled recovery"
                fire
                check {[llength $sent] == 1} "identical progress snapshot duplicated dispatch"
            } else {
                check {$automatic::current eq "" && [dict size $timers] == 0 && $sent eq ""} "late snapshot progress left recovery armed ($mode/$acknowledge/$change)"
            }
        }
    }
}
auto_begin 0 1 0
started $autoTurn
completed $autoTurn failed serverOverloaded {[{"type":"commandExecution","id":"applied-tool"}]}
retry::server [format {{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"%s","delta":"late output"}}} $autoTurn]
reply $autoId $autoTurn
check {$automatic::current eq "" && [dict size $timers] == 0 && $sent eq ""} "late progress before acknowledgement re-armed recovery"

automatic::cancel
retry::reset
set automatic::flags {auto_reset_limit 0 auto_continue_after_stop 0}
set automatic::selection {}
set automatic::live {}
set automatic::ids {}
set recovery::target ""
set recovery::pending {}
set recovery::seen {}
set retry::usedIds {}
set retry::internal {}
set retry::finished {}
set retry::sequence 0
set sent {}
set delays {}
rename automatic::notify {}
rename automatic::native_notify automatic::notify

set unitPhase 11
# Large startup catalogs must not stall keyboard forwarding in the event loop.
set catalogItem {{"name":"fixture","id":"fixture","nested":{"description":"sample \"text\" {} []","method":"fixture/request","enabled":true,"values":[1,2,3]}}}
set catalog "{\"id\":99,\"result\":{\"items\":\[[join [lrepeat 30000 $catalogItem] ,]\]}}"
foreach active {0 1 2 3} {
    retry::reset
    if {$active == 1} { begin 0 }
    if {$active == 2} {
        set resume::armed 1
        resume::client {{"id":31,"method":"thread/resume","params":{"threadId":"t1"}}}
    }
    if {$active == 3} { set recovery::pending {rpcId 32 expected t1} }
    set previous $retry::current
    set previousResume $resume::pending
    set previousRecovery $recovery::pending
    set before [clock milliseconds]
    check {[retry::server $catalog] == 1} "an unrelated startup catalog was hidden"
    check {[clock milliseconds] - $before < 1000} "startup catalog processing stalled terminal input"
    if {$active} {
        check {$retry::current eq $previous && $resume::pending eq $previousResume && [dict size $timers] == 0} "an unrelated response changed the tracked request"
        check {$recovery::pending eq $previousRecovery} "an unrelated response changed recovery correlation"
    }
    resume::reset
    set recovery::pending {}
}
unset catalog catalogItem
foreach invalid {{{"id":99,"result":{"nested":[{"a":1,"\u0061":2}]}}} {{"id":99,"result":{}} trailing} {{"id":99,"result":{/* comment */}}}} {
    check {[catch {retry::server $invalid}]} "unrelated response bypassed strict JSON validation"
}

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

foreach number {503.0 5.03e2 9007199254740993123456789} {
    retry::reset
    retry::client [format {{"id":%s,"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"neutral"}]}}} $number]
    set lexicalTurn lexical-id-$number
    completed $lexicalTurn
    reply [json::write string $number] $lexicalTurn
    check {[dict size $timers] == 0} "a string acknowledged a numeric request ID"
    reply $number $lexicalTurn
    check {[dict size $timers] == 1} "numeric ID spelling lost its matching acknowledgement"
}

# A later ID must be interpreted by the full parser, even if the header matches.
begin 0
completed turn1
reject_duplicate {retry::server {{"id":7,"result":{"turn":{"id":"turn1","items":[]}},"id":99}}}
check {$retry::current eq "" && [dict size $timers] == 0} "an ambiguous header acknowledged the wrong request"
begin 0
completed turn1
reply 7 turn1
check {[dict size $timers] == 1} "an ambiguous header consumed the matching acknowledgement"

# A catalog-like prefix cannot hide later connection-scoped control activity.
foreach payload {{{}} {[]} {{"nested":[{"text":"[]{}"}]}} {[{"nested":{"text":"{}[]"}}]}} {
    begin
    completed turn1
    retry::server [format {{"id":99,"result":%s,"method":"account/updated"}} $payload]
    check {$retry::current eq "" && [dict size $timers] == 0} "a response prefix hid an account change"
}

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
foreach layout {{"id":%s,"result":{},"id":99} {"id":99,"result":{},"id":%s}} {
    reject_duplicate {retry::server [format "\{$layout\}" $id]}
    check {[dict exists $retry::internal $id]} "a duplicate header ID consumed the internal reply marker"
}
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
    {"method":"thread/settings/update","params":{"threadId":"t2","model":"changed-model"}}
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
set pending [list $retry::current $retry::timer $retry::delay $timers]
retry::client {{"id":"metadata-default","method":"thread/read","params":{"threadId":"t2"}}}
check {[list $retry::current $retry::timer $retry::delay $timers] eq $pending} "read-only metadata canceled default replay or changed its backoff"
fire
check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] \
    [huddle get [::huddle::json2huddle $request] params]]} "read-only metadata changed default replay input or settings"
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

# Shared notifications may describe another client's work in our selected thread.
foreach event {
    {"method":"thread/settings/updated","params":{"threadId":"t1"}}
    {"method":"thread/queue/changed","params":{"threadId":"t1"}}
    {"method":"thread/goal/updated","params":{"threadId":"t1"}}
    {"method":"thread/goal/cleared","params":{"threadId":"t1"}}
    {"method":"item/started","params":{"threadId":"t1","turnId":"foreign","item":{"type":"userMessage"}}}
    {"method":"hook/started","params":{"threadId":"t1","turnId":"foreign"}}
} {
    begin
    completed turn1
    retry::server "\{$event\}"
    check {$retry::current eq "" && [dict size $timers] == 0} "shared-client activity left replay armed"
}
begin 0
started foreign
completed foreign
reply 99 foreign
reply {"7"} foreign
check {[dict size $timers] == 0} "foreign traffic authorized replay without our typed acknowledgement"
retry::reset

# A foreign live turn must remain visible to correlation before our reply,
# even when our start and overload completion have already been observed.
foreach event {
    {"method":"item/started","params":{"threadId":"t1","turnId":"foreign","item":{"type":"userMessage"}}}
    {"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"foreign","delta":"sample"}}
    {"method":"hook/started","params":{"threadId":"t1","turnId":"foreign"}}
} {
    foreach timing {before-start before-ack after-completion} {
        begin 0
        if {$timing ne "before-start"} { started turn1 }
        if {$timing eq "after-completion"} { completed turn1 }
        retry::server "\{$event\}"
        if {$timing eq "before-start"} { started turn1 }
        if {$timing ne "after-completion"} { completed turn1 }
        reply {"7"} turn1
        check {[dict size $timers] == 0} "foreign activity or a differently typed reply authorized replay"
        reply 7 turn1
        check {$retry::current eq "" && [dict size $timers] == 0} "early foreign activity was discarded at acknowledgement"
    }
}
begin 0
retry::server {{"method":"hook/started","params":{"threadId":"t1","turnId":"finished-foreign"}}}
completed finished-foreign completed
started turn1
completed turn1
reply 7 turn1
check {[dict size $timers] == 1} "a finished foreign turn was treated as conflicting live work"
begin 0
user_event item/started
started turn1
completed turn1
reply 7 turn1
check {[dict size $timers] == 1} "our early user item was treated as foreign activity"

# Same-turn shared input must match the original content and one item identity.
foreach timing {before-start before-ack after-completion} {
    begin 0
    if {$timing ne "before-start"} { started turn1 }
    if {$timing eq "after-completion"} { reply 7 turn1; completed turn1 }
    foreach method {item/started item/completed} {
        user_event $method
        user_event $method
    }
    reply 7 turn1 $userItems
    started turn1 t1 $userItems
    completed turn1 failed serverOverloaded $userItems
    completed turn1 failed serverOverloaded $userItems
    check {[dict size $timers] == 1} "original input echoes or duplicate snapshots blocked retry"
}
set changedUser [::huddle::json2huddle $userItem]
huddle set changedUser content 0 text [huddle string {foreign steering}]
set additionalUser [::huddle::json2huddle $userItem]
huddle set additionalUser id [huddle string additional-user]
set malformedUser [::huddle::json2huddle $userItem]
huddle set malformedUser type [huddle list [huddle string userMessage]]
foreach foreign [list [json_dump $changedUser] [json_dump $additionalUser] \
    [json_dump $malformedUser] {{"type":"userMessage","id":"unidentified-input"}}] {
    foreach method {item/started item/completed} {
        foreach timing {before-start before-ack after-completion} {
            begin 0
            if {$timing ne "before-start"} { started turn1 }
            user_event item/started
            if {$timing eq "after-completion"} { reply 7 turn1; completed turn1 }
            user_event $method $foreign
            user_event $method $foreign
            if {$timing eq "after-completion"} {
                check {[dict size $timers] == 0} "same-turn steering left an already scheduled retry active"
            }
            user_event item/completed
            started turn1
            completed turn1
            reply 7 turn1 $userItems
            check {[dict size $timers] == 0} "same-turn steering or ambiguous input allowed replay"
        }
    }
    foreach items [list [json::write array $userItem $foreign] [json::write array $foreign $userItem]] {
        foreach snapshot {reply started completed duplicate-completion} {
            begin 0
            switch $snapshot {
                reply { reply 7 turn1 $items; started turn1; completed turn1 }
                started { started turn1 t1 $items; completed turn1; reply 7 turn1 }
                completed { completed turn1 failed serverOverloaded $items; reply 7 turn1 }
                duplicate-completion {
                    reply 7 turn1 $userItems
                    completed turn1
                    completed turn1 failed serverOverloaded $items
                }
            }
            check {[dict size $timers] == 0} "additional or conflicting user input in a turn snapshot allowed replay"
        }
    }
}
begin
user_event item/started
completed turn1
user_event item/started [json_dump $changedUser] turn1 other-thread
check {[dict size $timers] == 1} "foreign-thread input canceled our retry"
fire
set replay [::huddle::json2huddle [lindex $sent end]]
check {[huddle equal [huddle get $replay params] [huddle get [::huddle::json2huddle $request] params]]} "user input correlation changed replay parameters"
set id [json_dump [huddle get $replay id]]
reply $id turn2 [json::write array [json_dump $additionalUser]]
completed turn2
check {[dict size $timers] == 1} "a retry turn inherited the previous user item identity"

# Use the native client's input ID when it supplied one; do not infer ownership
# from matching content if the echoed client identity disagrees or is ambiguous.
set identifiedRequest [::huddle::json2huddle $request]
huddle set identifiedRequest params clientUserMessageId [huddle string client-original]
foreach clientId {{"client-original"} {"client-foreign"} null {["client-original"]}} {
    retry::reset
    set retry::finished {}
    retry::client [json_dump $identifiedRequest]
    set identifiedUser [::huddle::json2huddle $userItem]
    huddle set identifiedUser clientId [::huddle::json2huddle $clientId]
    user_event item/started [json_dump $identifiedUser]
    started turn1
    completed turn1
    reply 7 turn1
    check {[dict size $timers] == ($clientId eq {"client-original"})} "user input correlation ignored typed client provenance"
}
retry::reset

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
# Standalone MCP requests stay visible. A different unfinished turn in the
# same thread conflicts with our request, including before acknowledgement.
foreach {turn thread eligible} {{"turn1"} t1 0 null t1 0 {"other-turn"} t1 1 {"turn1"} t2 1 null t2 1} {
    foreach timing {before-start before-ack after-completion} {
        begin 0
        if {$timing eq "before-ack"} { completed turn1 }
        if {$timing eq "after-completion"} { reply 7 turn1; completed turn1 }
        check {[elicitation $turn $thread] == 1} "MCP elicitation was hidden from the TUI"
        if {$timing eq "before-start"} { reply 7 turn1; started turn1; completed turn1 }
        if {$timing eq "before-ack"} { reply 7 turn1 }
        set expected $eligible
        if {$turn eq {"other-turn"} && $thread eq "t1"} { set expected 0 }
        check {[dict size $timers] == $expected} "MCP elicitation did not respect replay progress or shared-client scope"
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
completed old-turn completed
retry::server {{"method":"hook/completed","params":{"threadId":"t1","turnId":"old-turn","run":{}}}}
reply 7 turn1
started turn1
user_event item/started
completed turn1 failed serverOverloaded $userItems
check {[dict size $timers] == 1} "a finished turn's hook or our user item blocked retry"
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

set unitPhase 12
set options [list -c {model="fixture with spaces"} --enable feature --disable=other {-ceffort="high"}]
check {[backend_options [concat {resume --last} $options {-- --remote=prompt -c prompt}]] eq $options} "config extraction crossed the argument boundary or changed values"
foreach arguments {{--remote ws://invalid} {--remote-auth-token-env=OTHER} {-c} {--enable} {-c |} {--enable >file}} {
    check {[catch {backend_options $arguments}]} "invalid wrapper options were accepted"
}

# Only explicit interactive launch flags are consumed; values and prompts stay native-owned.
foreach {arguments expected expectedActivation} {
    {resume session --yolo} {resume session} thread/resume
    {--yolo resume --last} {resume --last} thread/resume
    {resume --last --dangerously-bypass-approvals-and-sandbox} {resume --last} thread/resume
    {--dangerously-bypass-approvals-and-sandbox resume session --yolo} {resume session} thread/resume
    {resume session {quoted prompt é} --yolo -c {model="with spaces"}}
        {resume session {quoted prompt é} -c {model="with spaces"}} thread/resume
    {resume session --yolo -- --yolo resume} {resume session -- --yolo resume} thread/resume
    {-m fixture --yolo resume --last} {-m fixture resume --last} thread/resume
    {resume --last} {resume --last} {}
    {--yolo} {} thread/start
    {--yolo {new prompt}} {{new prompt}} thread/start
    {--dangerously-bypass-approvals-and-sandbox {quoted prompt é}} {{quoted prompt é}} thread/start
    {-m fixture --yolo -c {model="with spaces"} {quoted prompt é}}
        {-m fixture -c {model="with spaces"} {quoted prompt é}} thread/start
    {--yolo -m resume {new prompt}} {-m resume {new prompt}} thread/start
    {--yolo -- --yolo resume} {-- --yolo resume} thread/start
    {exec --yolo resume} {exec --yolo resume} {}
    {{prompt} resume --yolo} {prompt resume} thread/start
    {-- resume --yolo} {-- resume --yolo} {}
    {--yolo -- resume} {-- resume} thread/start
    {resume session -- --yolo} {resume session -- --yolo} {}
    {{a prompt containing --yolo and resume}} {{a prompt containing --yolo and resume}} {}
    {resume session {a prompt containing --yolo and resume}}
        {resume session {a prompt containing --yolo and resume}} {}
    {resume --last --config=--yolo -mresume -C--yolo}
        {resume --last --config=--yolo -mresume -C--yolo} {}
    {resume --last -c -- --yolo} {resume --last -c --} thread/resume
} {
    lassign [resume_arguments $arguments] actual enabled activation
    check {$actual eq $expected && $enabled == ($expectedActivation ne "") && \
        $activation eq $expectedActivation} "launch flag ownership changed arguments or activation: $arguments"
}
foreach command {agents exec e review fork login logout mcp mcp-server plugin app-server
    remote-control completion update doctor sandbox debug apply a cloud queue archive
    delete unarchive migrate-rollouts migrate-nfs-db exec-server features help} {
    set arguments [list --yolo $command]
    check {[resume_arguments $arguments] eq [list $arguments 0]} "an unsupported command consumed YOLO: $command"
}
foreach option {-c --config --enable --disable -m --model --local-provider -p --profile
    -s --sandbox -a --ask-for-approval -C --cd --add-dir -i --image} {
    foreach value {resume --yolo --dangerously-bypass-approvals-and-sandbox} {
        set arguments [list $option $value resume --last]
        check {[resume_arguments $arguments] eq [list $arguments 0]} "an option value enabled YOLO: $option $value"
    }
}
foreach arguments {
    {resume --yolo -a never}
    {--ask-for-approval=never --yolo resume --last}
    {resume --last --dangerously-bypass-approvals-and-sandbox -anever}
    {--approve-for-me resume --last --yolo}
    {resume session --yolo --not-so-yolo}
    {--yolo -a never}
    {--dangerously-bypass-approvals-and-sandbox --ask-for-approval=never {new prompt}}
    {--yolo --approve-for-me}
    {--not-so-yolo --yolo {new prompt}}
} {
    check {[catch {resume_arguments $arguments} message] && [string match *conflicts* $message]} "consumption hid a native permission conflict"
}
check {[resume_arguments {resume --last -s read-only --yolo}] eq {{resume --last -s read-only} 1 thread/resume}} "an unrelated sandbox flag gained a speculative conflict"
check {[resume_arguments {resume --last -c --approve-for-me --yolo}] eq {{resume --last -c --approve-for-me} 1 thread/resume}} "a value was mistaken for a conflicting flag"
check {[backend_options {resume --last -m --remote -p --config -i -c --cd --enable -- --config=prompt}] eq {}} "backend extraction interpreted another option's value"

# A launch default must respect native values, prompts, errors and saved roots.
foreach {arguments inject} {
    {} 1
    {--yolo {a prompt containing resume, fork and --cd}} 1
    {-m resume -p fork --config=--cd} 1
    {-m-Celsewhere -ifork.png --profile=resume} 1
    {-- resume --cd /prompt/path} 1
    {{a prompt} resume fork} 1
    {--model} 1
    {--unknown-option} 1
    {--cd} 0
    {-C} 0
    {--cd {explicit directory with spaces}} 0
    {-C {explicit directory with spaces}} 0
    {{--cd=explicit directory}} 0
    {{-Cexplicit directory}} 0
    {{-C=explicit directory}} 0
    {--cd=} 0
    {--cd one -C two} 0
    {{a prompt} --cd elsewhere} 0
    {resume} 0
    {resume --last} 0
    {resume --all} 0
    {--yolo resume session} 0
    {-m fixture resume --last --all} 0
    {fork} 0
    {fork session} 0
    {fork --last --all} 0
} {
    set expected $arguments
    set expectedCwd ""
    if {$inject} {
        set expected [linsert $arguments 0 --cd [pwd]]
        set expectedCwd [pwd]
    }
    check {[cwd_arguments $arguments] eq $expected} "launch cwd changed native argument boundaries: $arguments"
    check {$implicitCwd eq $expectedCwd} "launch cwd marker claimed an explicit or saved-session override: $arguments"
}
foreach option {-c --config --enable --disable -m --model --local-provider -p --profile
    -s --sandbox -a --ask-for-approval --add-dir -i --image} {
    foreach value {resume fork --cd -C --cd=elsewhere -Celsewhere --} {
        set arguments [list $option $value]
        check {[cwd_arguments $arguments] eq [linsert $arguments 0 --cd [pwd]]} "launch cwd interpreted an option value: $option $value"
    }
}
set launchDirectory [pwd]
set launchScript [file normalize [file join [file dirname [info script]] .. codex-retry]]
set physicalLaunch [file join $configScratch {physical launch}]
file mkdir $physicalLaunch
file link -symbolic [file join $configScratch launch-link] $physicalLaunch
try {
    cd [file join $configScratch launch-link]
    # A new wrapper process observes getcwd, rather than Tcl's cached cd path.
    set probe "set argv0 cwd-launch\n[list source $launchScript]\nputs \[cwd_arguments {}\]"
    check {[exec [info nameofexecutable] << $probe] eq [list --cd $physicalLaunch]} "launch cwd retained a logical symlink path"
} finally { cd $launchDirectory }

# Only the wrapper's default may be removed from later session activations.
foreach arguments [list {} [list --cd [pwd]] [list -C [pwd]] \
    [list --cd=[pwd]] [list -C[pwd]] {resume --last} {fork --last}] {
    cwd_arguments $arguments
    foreach method {thread/resume thread/fork} id {{"cwd-request"} 31} {
        set json [string map [list @METHOD@ [json::write string $method] @ID@ $id \
            @CWD@ [json::write string [pwd]]] {
            { "id":@ID@,"method":@METHOD@,"params":{"threadId":"saved-session",
              "cwd":@CWD@,"model":"fixture","permissions":null,
              "settings":{"flag":true,"disabled":false,"count":3,"text":"quoted \" é\n",
                          "emptyObject":{},"emptyArray":[],"items":[null,1,"one"]}},
              "metadata":{"cwd":@CWD@} }
        }]
        set adapted [cwd_client $json]
        if {$arguments eq {}} {
            set object [::huddle::json2huddle $adapted]
            check {[huddle type $object params cwd] eq "null"} "synthetic cwd leaked into $method"
            huddle set object params cwd [huddle string [pwd]]
            check {[huddle equal $object [::huddle::json2huddle $json]]} "cwd filtering changed other fields or JSON types"
        } else {
            check {$adapted eq $json} "cwd filtering changed an explicit override or startup resume/fork"
        }
    }
}
cwd_arguments {}
foreach params [list {{"threadId":"saved-session"}} {{"cwd":null}} {{"cwd":""}} \
    {{"cwd":false}} {{"cwd":3}} {{"cwd":{}}} \
    [json::write object cwd [json::write string "$implicitCwd/elsewhere"]] \
    [json::write object cwd [json::write string "$implicitCwd/"]] \
    [json::write object cwd [json::write array [json::write string $implicitCwd]]]] {
    foreach method {thread/resume thread/fork} {
        set json [json::write object id 32 method [json::write string $method] params $params]
        check {[cwd_client $json] eq $json} "cwd filtering changed missing, null, different or non-string cwd"
    }
}
foreach method {thread/start thread/read thread/settings/update turn/start} {
    set json [json::write object id 33 method [json::write string $method] \
        params [json::write object cwd [json::write string $implicitCwd]]]
    check {[cwd_client $json] eq $json} "cwd filtering changed an unrelated request"
}
foreach envelope {{{"id":34,"result":{"cwd":@CWD@}}} \
    {{"id":35,"method":["thread/resume"],"params":{"cwd":@CWD@}}}} {
    set json [string map [list @CWD@ [json::write string $implicitCwd]] $envelope]
    check {[cwd_client $json] eq $json} "cwd filtering interpreted a response or untyped method"
}
cwd_arguments {resume}

# Recovery requires the newest typed activation reply, independently of retries.
set transport::reattaching 0
set transport::unavailable 0
proc activate {id method {thread t1}} {
    recovery::client [format {{"id":%s,"method":"%s","params":{"threadId":"%s"}}} $id $method $thread]
}
proc activated {id thread} {
    retry::server [format {{"id":%s,"result":{"thread":{"id":%s},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}}}} $id [json::write string $thread]]
}
set recovery::deleted {}
set recovery::seen {}
activate 71 thread/start
activated {"71"} unrelated
retry::server {{"method":"thread/started","params":{"thread":{"id":"subagent"}}}}
check {$recovery::target eq ""} "an uncorrelated activation selected a recovery target"
activated 71 first
check {$recovery::target eq "first"} "a confirmed start was lost"
retry::reset
resume::reset
check {$recovery::target eq "first"} "retry or permission cleanup discarded recovery"
activate {"switch"} thread/resume second
check {$recovery::target eq ""} "pending activation retained a stale selection"
activate 72 thread/fork
activated {"switch"} second
check {$recovery::target eq ""} "a stale activation selected recovery"
activated 72 forked
check {$recovery::target eq "forked"} "a confirmed fork was lost"
recovery::client {{"method":"thread/read","params":{"threadId":"other"}}}
check {$recovery::target eq "forked"} "a background read changed selected recovery"
recovery::client {{"id":70,"method":"turn/start","params":{"threadId":"other","input":[]}}}
check {$recovery::target eq ""} "unconfirmed thread work retained a stale selection"
activate 90 thread/start
check {[retry::server {{"id":90,"result":{"thread":{"id":"empty-metadata","extra":{"empty":{},"items":[]}},"approvalPolicy":"on-request","sandbox":{"type":"readOnly"}}}}] == 1} "empty activation metadata changed response forwarding"
check {$recovery::target eq "empty-metadata"} "empty JSON objects prevented confirmed recovery"
set activationId 80
foreach result {
    {"error":{"code":-1,"message":"fixture"}}
    {"result":{}}
    {"result":{"thread":{"id":null}}}
    {"result":{"thread":{"id":73}}}
    {"result":{"thread":{"id":""}}}
    {"result":{"thread":{"id":"wrong-thread"}}}
    {"result":{"thread":{"id":"t1","ephemeral":true}}}
} {
    activate [incr activationId] thread/resume
    retry::server "\{\"id\":$activationId,$result\}"
    check {$recovery::target eq ""} "an unsafe activation fabricated recovery"
}
activate 74 thread/resume
retry::server {{"id":74,"method":"hook/started","params":{}}}
check {$recovery::pending ne ""} "a server request consumed recovery correlation"
activated 74 t1
retry::server {{"method":"thread/deleted","params":{"threadId":"unrelated"}}}
check {$recovery::target eq "t1"} "unrelated deletion removed recovery"
retry::server {{"method":"thread/deleted","params":{"threadId":"t1"}}}
check {$recovery::target eq ""} "deleted thread remained resumable"
activate 75 thread/resume t1
activated 75 t1
check {$recovery::target eq ""} "a delayed reply revived deleted recovery"
activate 76 thread/start
recovery::client {{"id":77,"method":"thread/delete","params":{"threadId":"removed"}}}
activated 76 removed
check {$recovery::target eq ""} "deletion during activation revived recovery"
set recovery::deleted {}
activate 76 thread/start
activated 76 removed
check {$recovery::target eq ""} "a reused request ID accepted a stale reply"
recovery::client {{"id":91,"method":["thread/start"],"params":{}}}
activated 91 invalid-method
check {$recovery::target eq ""} "an untyped method selected recovery"
activate 92 thread/start
recovery::client {{"id":93,"method":"turn/start","params":{"threadId":"other","input":[]}}}
activated 92 stale-after-turn
check {$recovery::target eq ""} "unconfirmed thread work accepted a stale activation"

foreach arguments {{--yolo} {--dangerously-bypass-approvals-and-sandbox} {--config=--yolo} {-m --yolo} {-- --yolo}} expected {1 1 0 0 0} {
    resume_arguments $arguments
    check {$recovery::yolo == $expected} "launch YOLO intent ignored argument boundaries"
}
resume_arguments {--yolo}
activate 78 thread/start
activated 78 actual-session
check {[string match {*resume actual-session --yolo*} [recovery::advice]]} "new-session YOLO was missing from recovery"
recovery::client {{"id":79,"method":"thread/settings/update","params":{"threadId":"actual-session","model":"fixture"}}}
check {$recovery::yolo} "a model-only change removed applicable YOLO"
recovery::client {{"id":80,"method":"turn/start","params":{"threadId":"actual-session","approvalPolicy":"on-request","sandboxPolicy":{"type":"readOnly"}}}}
check {![string match {*--yolo*} [recovery::advice]]} "manual permissions were escalated again"
resume_arguments {--yolo}
activate 1200 thread/start
activated 1200 shared-session
retry::server {{"method":"thread/settings/updated","params":{"threadId":"other"}}}
check {$recovery::yolo} "foreign-thread settings removed applicable YOLO"
retry::server {{"method":"thread/settings/updated","params":{"threadId":"shared-session","threadSettings":{"model":"fixture","approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}}}}
check {$recovery::yolo} "confirmed unchanged permissions removed applicable YOLO"
retry::server {{"method":"thread/settings/updated","params":{"threadId":"shared-session"}}}
check {$recovery::target eq "shared-session" && !$recovery::yolo} "shared-client settings retained launch escalation"
set activationId 94
foreach permissions {
    {"approvalPolicy":["never"],"sandbox":{"type":"dangerFullAccess"}}
    {"approvalPolicy":"never","sandbox":{"type":["dangerFullAccess"]}}
} {
    resume_arguments {--yolo}
    activate [incr activationId] thread/start
    retry::server "\{\"id\":$activationId,\"result\":\{\"thread\":\{\"id\":\"typed-session\"\},$permissions\}\}"
    check {$recovery::target eq "typed-session" && !$recovery::yolo} "untyped permissions retained YOLO"
}
set activationId 100
foreach extra {
    {"history":[]}
    {"path":"null"}
    {"history":null,"path":""}
} selected {history-session path-session source-thread} {
    recovery::client [format {{"id":%d,"method":"thread/resume","params":{"threadId":"source-thread",%s}}} [incr activationId] $extra]
    activated $activationId $selected
    check {$recovery::target eq $selected} "resume history/path precedence lost confirmed recovery"
}

# Execute only the shell parser, never a product command, to prove exact quoting.
set recovery::target {session 'quoted' $value; with spaces}
set advice [recovery::advice]
set command [string trim [lindex [split $advice \n] 1]]
set words [exec sh -c "set -- $command; printf '%s\\n' \"\$@\""]
check {[split $words \n] eq [list [recovery::invocation] resume $recovery::target]} "recovery command changed shell arguments"
set recovery::target ""
check {[string first "To choose a saved session, run:" [recovery::advice]] == 0 && \
    [string first SESSION_ID [recovery::advice]] < 0} "unknown recovery did not offer a truthful picker"

# A temporary release, incomplete epilogue and an oversized tail are lossless.
rename presentation::write presentation::native_write
proc presentation::write {bytes} { append ::presented $bytes }
set marker $presentation::boundary
foreach content [list "plain\x00utf8:é" "live${marker}temporary\033\[?2004hstill live" \
    "live${marker}unrecognized exit" "live${marker}[string repeat x 17000]" \
    "live${marker}\033\]0;incomplete" "live${marker}\033\]7501;state=clear\033" \
    "live${marker}\033\]0;[string repeat x 17000]"] {
    set presented ""
    set presentation::buffer ""
    set presentation::held 0
    set presentation::replaced 0
    foreach byte [split $content ""] { presentation::feed $byte }
    presentation::finish
    check {$presented eq $content && !$presentation::replaced} "unsupported exit presentation lost bytes"
}
# A read can end at restoration or anywhere inside CSI/OSC, including OSC's ST.
set presentation::endpoint ws://127.0.0.1:12345/
set prefix "codex --remote $presentation::endpoint --remote-auth-token-env CODEX_RETRY_TOKEN"
set recovery::target confirmed-session
foreach controls [list "" "\033\]0;\007" "\033\]7501;state=clear\033\\" \
    "\033\]0;\007\033\]7501;state=clear\033\\"] {
    foreach stop [list "To stop this task, run $prefix agents" \
        "To stop this task, run $prefix agents, select this task, and press x." \
        "To stop this task, run:\r\n  $prefix agents"] {
        set unrelated "codex agents documentation stays\r\nagents server diagnostic\r\n"
        set content "live${marker}\r\n${controls}\033\[?25h\033\[32mDisconnected from this task. Work may still be running.\033\[0m\r\nTo reconnect, run:\r\n  $prefix resume untrusted\r\n${unrelated}$stop\r\nToken usage so far: total=17 input=11 output=6\r\n"
        set expected "live${marker}\r\n${controls}\033\[?25h\033\[32m\033\[0m[encoding convertto utf-8 [string map [list \n \r\n] [recovery::advice]]]${unrelated}Token usage so far: total=17 input=11 output=6\r\n"
        foreach width [list 1 7 [string length $content]] {
            set presented ""
            set presentation::buffer ""
            set presentation::held 0
            set presentation::replaced 0
            for {set i 0} {$i < [string length $content]} {incr i $width} {
                presentation::feed [string range $content $i [expr {$i + $width - 1}]]
            }
            presentation::finish
            check {$presentation::replaced && $presented eq $expected} "split native epilogue changed replacement or retained bytes"
        }
    }
}
# Forward completed controls and an editor prompt before any input or TUI re-entry.
set presented ""
set presentation::buffer ""
set presentation::held 0
presentation::feed "${marker}\033\]7501;state="
check {$presented eq $marker && $presentation::held} "incomplete leading OSC was flushed early"
presentation::feed "clear\033"
check {$presented eq $marker && $presentation::held} "split OSC terminator was flushed early"
presentation::feed "\\\033\[6nEDITOR_PROMPT> "
check {$presented eq "${marker}\033\]7501;state=clear\033\\\033\[6nEDITOR_PROMPT> " && \
    !$presentation::held && $presentation::buffer eq ""} "OSC handling hid editor output or cursor queries"
rename presentation::write {}
rename presentation::native_write presentation::write

set resumeRequest {{"id":31,"method":"thread/resume","params":{"threadId":"t1","approvalPolicy":"on-request","sandbox":"read-only","permissions":null,"config":{"sample":true},"initialTurnsPage":{"limit":3},"optional":null,"empty":[]}}}
set resumeReply {{"id":31,"result":{"thread":{"id":"t1","turns":[]},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"},"activePermissionProfile":{"id":"fixture","extends":null}}}}
proc arm_resume {{activation thread/resume}} {
    set ::transport::reattaching 0
    set ::transport::unavailable 0
    retry::reset
    set ::retry::finished {}
    resume::reset
    set ::resume::armed 1
    set ::resume::activation $activation
    set ::recovery::target ""
    set ::recovery::pending {}
    set ::recovery::seen {}
    set ::recovery::deleted {}
    set ::recovery::yolo 1
}
# Fresh startup has no requested thread ID: only the correlated server reply
# can establish its identity, and its effective permissions must still match.
set startRequest [huddle remove [::huddle::json2huddle $resumeRequest] params threadId]
huddle set startRequest method [huddle string thread/start]
set startRequest [json_dump $startRequest]
set startReply [string map {t1 server-created-thread} $resumeReply]
arm_resume thread/start
set translated [::huddle::json2huddle [resume::client $startRequest]]
set startExpected [::huddle::json2huddle $startRequest]
huddle set startExpected params approvalPolicy [huddle string never]
huddle set startExpected params sandbox [huddle string danger-full-access]
check {[huddle equal $translated $startExpected]} "fresh YOLO changed input/settings or fabricated a requested identity"
recovery::client [json_dump $translated]
check {[retry::server [string map {31 {"31"}} $startReply]] == 1 && $resume::pending ne ""} "a foreign typed ID confirmed fresh startup"
check {[retry::server {{"id":31,"method":"fixture/request","params":{}}}] == 1 && $resume::pending ne ""} "a server request confirmed fresh startup"
check {[retry::server $startReply] == 1 && $resume::pending eq "" && \
    $recovery::target eq "server-created-thread" && $recovery::yolo} "fresh YOLO did not verify actual identity and effective rights"
foreach action [list $startRequest $resumeRequest \
    {{"id":32,"method":"thread/settings/update","params":{"threadId":"server-created-thread","approvalPolicy":"on-request","sandboxPolicy":{"type":"readOnly"}}}}] {
    check {[resume::client $action] eq $action} "confirmed startup escalated later native settings or activations"
}
foreach response [list \
    [string map {{"id":"server-created-thread"} {"id":""}} $startReply] \
    [string map {{"id":"server-created-thread"} {"id":null}} $startReply] \
    [string map {{"id":"server-created-thread"} {"id":["server-created-thread"]}} $startReply] \
    [string map {never on-request} $startReply] \
    [string map {dangerFullAccess readOnly} $startReply] \
    {{"id":31,"result":{}}} \
    [string map {{,"result":} {,"method":null,"result":}} $startReply]] {
    arm_resume thread/start
    recovery::client [resume::client $startRequest]
    check {[retry::server $response] == 0 && $resume::failure ne "" && \
        $recovery::target eq ""} "an invalid fresh acknowledgement confirmed permissions or recovery advice"
    check {[catch {resume::client $request}]} "an invalid fresh acknowledgement permitted work"
}
foreach activation {
    {"method":"thread/start","params":{}}
    {"id":null,"method":"thread/start","params":{}}
    {"id":31,"method":"thread/start","params":[]}
    {"id":31,"method":"thread/start","params":{"permissions":"named"}}
    {"id":31,"method":"thread/start","params":{"permissions":""}}
} {
    arm_resume thread/start
    check {[catch {resume::client "\{$activation\}"}]} "an unidentified or conflicting fresh activation was forwarded"
    check {[catch {resume::client $request}]} "a rejected fresh activation permitted work"
}
arm_resume
set translated [::huddle::json2huddle [resume::client $resumeRequest]]
set expected [::huddle::json2huddle $resumeRequest]
huddle set expected params approvalPolicy [huddle string never]
huddle set expected params sandbox [huddle string danger-full-access]
check {[huddle equal $translated $expected]} "resume translation changed other parameters or JSON types"
check {[retry::server [string map {31 {"31"}} $resumeReply]] == 1 && $resume::pending ne ""} "string and numeric resume IDs were conflated"
check {[retry::server {{"id":"31","method":null,"result":{}}}] == 1 && $resume::pending ne "" && $resume::failure eq ""} "an invalid method on another typed ID failed resume verification"
check {[retry::server {{"id":31,"method":"fixture/request","params":{}}}] == 1 && $resume::pending ne ""} "a server request consumed resume verification"
foreach methodKey {{"method"} {"\u006dethod"}} {
    foreach method {fixture/request null} {
        set event [format {{"id":31,"result":{},%s:"%s","params":{}}} $methodKey $method]
        check {[retry::server $event] == 1 && $resume::pending ne "" && $resume::failure eq ""} "a valid server request with a colliding resume ID was rejected"
    }
}
reject_duplicate {retry::server {{"id":31,"result":{"thread":{"id":"t1"},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}},"id":99}}}
check {$resume::pending ne "" && $resume::failure eq ""} "a duplicate header ID confirmed the wrong resume"
check {[resume::client {{"id":32,"method":"thread/read","params":{"threadId":"other"}}}] eq {{"id":32,"method":"thread/read","params":{"threadId":"other"}}}} "unrelated read traffic was intercepted"
check {[retry::server $resumeReply] == 1 && $resume::pending eq ""} "effective YOLO permissions were not confirmed"
check {[resume::client $resumeRequest] eq $resumeRequest} "YOLO was reapplied on a later resume"

foreach id {31 {"31"} {"quoted\u0022id"}} {
    foreach layout {
        {{"id":%s,"result":{"thread":{"id":"t1"},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}}}}
        {{"result":{"thread":{"id":"t1"},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}},"id":%s}}
    } {
        arm_resume
        resume::client [format {{"id":%s,"method":"thread/resume","params":{"threadId":"t1"}}} $id]
        check {[retry::server [format $layout $id]] == 1 && $resume::pending eq ""} "a typed resume ID or response layout lost verification"
    }
}
foreach result {
    {"thread":{"id":"other"},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}}
    {"thread":{"id":"t1"},"approvalPolicy":"on-request","sandbox":{"type":"dangerFullAccess"}}
    {"thread":{"id":"t1"},"approvalPolicy":"never","sandbox":{"type":"readOnly"}}
    {"thread":{"id":"t1"},"approvalPolicy":"never"}
    {"thread":{"id":["t1"]},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}}
    {"thread":{"id":"t1"},"approvalPolicy":["never"],"sandbox":{"type":"dangerFullAccess"}}
    {"thread":{"id":"t1"},"approvalPolicy":"never","sandbox":{"type":["dangerFullAccess"]}}
} {
    arm_resume
    resume::client $resumeRequest
    check {[retry::server "\{\"id\":31,\"result\":\{$result\}\}"] == 0 && $resume::failure ne ""} "an invalid permission acknowledgement continued as success"
    check {[catch {resume::client $request}]} "a failed permission acknowledgement allowed work"
}
foreach payload {{{}} null {"malformed"} {[]}} {
    arm_resume
    resume::client $resumeRequest
    check {[retry::server [format {{"id":31,"result":%s}} $payload]] == 0 && $resume::failure ne ""} "a malformed resume result was accepted"
}
foreach response {
    {"id":31}
    {"id":31,"method":"","result":{}}
} {
    arm_resume
    resume::client $resumeRequest
    check {[retry::server "\{$response\}"] == 0 && $resume::failure ne ""} "a malformed reply envelope left verification active"
}
foreach methodKey {{"method"} {"\u006dethod"}} {
    foreach invalidMethod {null true false 0 {[]} {["fixture/request"]} {{}} {{"nested":"fixture/request"}} {""}} {
        arm_resume
        resume::client $resumeRequest
        set response [string map [list {,"result":} ",${methodKey}:${invalidMethod},\"result\":"] $resumeReply]
        check {[retry::server $response] == 0 && $resume::failure ne ""} "a non-request method exposed an unverified resume result"
        check {[catch {resume::client $request}]} "a malformed acknowledgement allowed subsequent work"
    }
}
foreach parameters {
    {"threadId":"t1","permissions":"named"}
    {"threadId":"t1","permissions":""}
    {"threadId":null}
} {
    arm_resume
    check {[catch {resume::client "\{\"id\":31,\"method\":\"thread/resume\",\"params\":\{$parameters\}\}"}]} "a conflicting or unidentified resume was forwarded"
    check {[catch {resume::client $request}]} "a rejected resume allowed subsequent work"
}

# Dispatch must record the actual forwarded turn, and never leak guarded work.
rename bgerror native_bgerror
proc bgerror {message} { lappend ::proxyFailures $message; retry::reset }
set proxyFailures {}
set prediction {{"id":42,"method":"thread/prediction/request","params":{"threadId":"t1","sourceTurnId":"fixture-turn"}}}
foreach activation {thread/resume thread/start} {
    set activationRequest [expr {$activation eq "thread/start" ? $startRequest : $resumeRequest}]
    foreach stage {armed waiting rejected} {
        foreach method {turn/start review/start thread/shellCommand thread/queue/start thread/realtime/start
            command/exec process/spawn mcpServer/tool/call thread/goal/set thread/prediction/request} {
            arm_resume $activation
            if {$stage ne "armed"} { connection fixture text $activationRequest }
            if {$stage eq "rejected"} {
                set rejection {{"id":31,"error":{"code":-32000,"message":"fixture rejection","data":{"detail":"original"}}}}
                check {[retry::server $rejection] == 1} "native resume rejection was hidden"
            }
            set before [llength $sent]
            set work [format {{"id":40,"method":"%s","params":{"threadId":"t1","input":[]}}} $method]
            if {$method eq "thread/prediction/request"} { set work $prediction }
            connection fixture text $work
            check {[llength $sent] == $before && $retry::current eq ""} "unconfirmed permissions leaked work or a retry snapshot"
        }
    }
}
check {[llength $proxyFailures] == 60} "guarded work did not fail visibly"
resume::reset
foreach invalid {{[]} {{"id":99,"method":"thread/list","params":{"a":1,"\u0061":2}}} {{"id":99,"result":{"nested":[{"a":1,"a":2}]}}} {{"id":99,"result":{}} trailing}} {
    set before [llength $sent]
    set failures [llength $proxyFailures]
    connection fixture text $invalid
    check {[llength $sent] == $before && [llength $proxyFailures] == $failures + 1} "invalid primary JSON was forwarded"
}
foreach activation {thread/resume thread/start} {
    set activationRequest [expr {$activation eq "thread/start" ? $startRequest : $resumeRequest}]
    set otherActivation [expr {$activation eq "thread/start" ? $resumeRequest : $startRequest}]
    foreach action [list $otherActivation \
        {{"id":32,"method":"thread/start","params":{}}} \
        {{"id":32,"method":"thread/fork","params":{"threadId":"other"}}} \
        {{"id":32,"method":"thread/settings/update","params":{"threadId":"t1","approvalPolicy":"on-request"}}}] {
        # The first matching activation is the intended startup; every activation
        # after it (including another start) is a manual change during verification.
        if {[field [json::json2dict $action] method] ne $activation} {
            arm_resume $activation
            check {[resume::client $action] eq $action && !$resume::armed} "a manual change did not disarm launch YOLO"
            check {[resume::client $activationRequest] eq $activationRequest} "a later thread inherited a canceled launch override"
        }
        arm_resume $activation
        connection fixture text $activationRequest
        set before [llength $sent]
        connection fixture text $action
        connection fixture text $request
        check {[llength $sent] == $before} "a change during verification leaked unconfirmed work"
    }
    foreach stage {armed waiting} {
        arm_resume $activation
        if {$stage eq "waiting"} { connection fixture text $activationRequest }
        connection fixture disconnect ""
        check {!$resume::armed && [string match {*before launch --yolo permissions were confirmed} $resume::failure]} \
            "disconnect silently discarded unresolved launch YOLO verification"
    }
}
resume::reset

arm_resume
connection fixture text $resumeRequest
check {[huddle equal [::huddle::json2huddle [lindex $sent end]] $expected]} "real dispatch did not translate the resume request"
retry::server $resumeReply
set before [llength $sent]
connection fixture text $prediction
check {[llength $sent] == $before + 1 && [lindex $sent end] eq $prediction} "confirmed resume blocked or changed a prediction request"
set yoloTurn [::huddle::json2huddle $request]
huddle set yoloTurn params approvalPolicy [huddle string never]
huddle set yoloTurn params sandboxPolicy type [huddle string dangerFullAccess]
set yoloTurn [json_dump $yoloTurn]
connection fixture text $yoloTurn
reply 7 turn1
completed turn1
fire
check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] [huddle get [::huddle::json2huddle $yoloTurn] params]]} "YOLO overload replay changed effective permissions or input"
connection fixture text {{"id":41,"method":"thread/settings/update","params":{"threadId":"t1","approvalPolicy":"on-request","sandboxPolicy":{"type":"readOnly"}}}}
check {[dict size $timers] == 0} "manual permission changes retained an overload retry"
connection fixture text $request
check {[lindex $sent end] eq $request} "launch YOLO replaced subsequent manual turn permissions"
reply 7 manual-turn
completed manual-turn
fire
check {[huddle equal [huddle get [::huddle::json2huddle [lindex $sent end]] params] [huddle get [::huddle::json2huddle $request] params]]} "manual permissions changed on overload replay"
retry::reset
resume::reset
rename bgerror {}
rename native_bgerror bgerror

package require websocket

set unitPhase 13
# A send can remove both channels before Tcllib dispatches another frame.
rename websocket::send websocket::native_send
proc websocket::send {socket type message} {
    lappend ::forwarded $message
    if {$::sendMode eq "record"} { return 1 }
    if {$::sendMode ne "failed"} { connection $socket $::sendMode "" }
    return [expr {$::sendMode eq "close" ? 1 : -1}]
}
foreach sendMode {failed close disconnect} {
    begin
    completed turn1
    set backend [file tempfile scratch]
    set backendChannel $backend
    set client fixture
    set forwarded {}
    set failed [catch {
        backend_event $backendChannel text {{"id":91,"result":{}}}
        backend_event $backendChannel text {{"id":92,"result":{}}}
    } message]
    set stopped [expr {![info exists backend] && ![info exists client]}]
    cleanup
    file delete $scratch
    check {!$failed} "forwarding after disconnect accessed a removed channel: $message"
    check {$stopped && [llength $forwarded] == 1 && [dict size $timers] == 0} "failed forwarding left a connection or retry active"
}
rename bgerror native_bgerror
proc bgerror {message} { lappend ::proxyFailures $message; cleanup }
foreach outcome {confirmed rejected mismatch disconnected-rejection closed-rejection null-method} {
    arm_resume
    recovery::client [resume::client $resumeRequest]
    set sendMode record
    switch $outcome {
        confirmed { set response $resumeReply }
        rejected { set response $rejection }
        mismatch { set response [string map {dangerFullAccess readOnly} $resumeReply] }
        disconnected-rejection { set response $rejection; set sendMode disconnect }
        closed-rejection { set response $rejection; set sendMode close }
        null-method { set response [string map {{,"result":} {,"method":null,"result":}} $resumeReply] }
    }
    set backend [file tempfile scratch]
    set client fixture
    set forwarded {}
    set proxyFailures {}
    backend_event $backend text $response
    cleanup
    file delete $scratch
    set expectedForwarded {}
    if {$outcome ni {mismatch null-method}} { set expectedForwarded [list $response] }
    check {$forwarded eq $expectedForwarded} "resume routing altered an authoritative response or exposed unconfirmed success"
    check {[llength $proxyFailures] == ($outcome ne "confirmed")} "resume verification failure did not halt visibly"
    if {$outcome in {rejected disconnected-rejection closed-rejection}} {
        check {$proxyFailures eq [list "server rejected launch --yolo: fixture rejection"]} \
            "frontend closure replaced the authoritative resume rejection"
    }
    check {$recovery::target eq ($outcome eq "confirmed" ? "t1" : "")} "resume recovery bypassed permission verification or cleanup lost confirmation"
}
rename bgerror {}
rename native_bgerror bgerror
rename websocket::send {}
rename websocket::native_send websocket::send

# Metadata RPCs and failures cannot touch a queued primary recovery, even when
# IDs, thread IDs and permissions overlap. Stale channel callbacks are harmless.
rename websocket::send websocket::native_send
rename close_backend native_close_backend
proc websocket::send {socket type message} { lappend ::routed [list $socket $message]; return 1 }
proc close_backend {channel} { lappend ::closedBridges $channel }
auto_begin 0 1
completed $autoTurn failed serverOverloaded {[{"type":"fileChange","id":"progress"}]}
resume::reset
set resume::armed 1
set recovery::target primary-session
set protected [list $timers $retry::current $retry::delay $automatic::current \
    $automatic::selection $automatic::live $resume::armed $resume::pending $recovery::target $recovery::yolo]
set routed {}
set closedBridges {}
set client primary-fixture
set backend primary-bridge
foreach socket {picker1 picker2 picker3 picker4} channel {bridge1 bridge2 bridge3 bridge4} {
    set auxiliary::clients($socket) $channel
    set auxiliary::backends($channel) $socket
    set ticket [incr transport::sequence]
    set auxiliary::tickets($socket) $ticket
    foreach message [list $resumeRequest $request \
        { {"id":7,"method":"thread/list","params":{"searchTerm":"synthetic"}} }] {
        auxiliary::event $ticket $socket text $message
        check {[lindex [lindex $routed end] 1] eq $message} "picker request JSON was rewritten"
    }
    foreach message [list $resumeReply \
        { {"id":7,"error":{"code":-1,"message":"metadata failure"}} } \
        { {"method":"thread/closed","params":{"threadId":"t1"}} }] {
        auxiliary::backend $ticket $channel text $message
        check {[lindex [lindex $routed end] 1] eq $message} "picker reply JSON was rewritten"
    }
    check {[lindex [lindex $routed end] 0] eq $socket} "auxiliary backend reply used another client"
    switch -- $socket {
        picker1 { auxiliary::backend $ticket $channel timeout "" }
        picker2 { auxiliary::event $ticket $socket text "invalid JSON" }
        picker3 { auxiliary::backend $ticket $channel text {{"id":99,"result":{"a":1,"\u0061":2}}} }
        picker4 { auxiliary::event $ticket $socket text {{"id":99,"method":"thread/list","params":{"a":1,"a":2}}} }
    }
    set before $routed
    auxiliary::backend $ticket $channel text $resumeReply
    auxiliary::event $ticket $socket text $request
    check {$routed eq $before} "retired auxiliary callback forwarded data"
}
check {[llength $routed] == 24 && $closedBridges eq {bridge1 bridge2 bridge3 bridge4}} "auxiliary routing or local failure cleanup changed"
check {[list $timers $retry::current $retry::delay $automatic::current \
    $automatic::selection $automatic::live $resume::armed $resume::pending $recovery::target $recovery::yolo] eq $protected} \
    "picker metadata, failure or closure changed primary ownership"
fire
check {[huddle get_stripped [::huddle::json2huddle [lindex $sent end]] params input 0 text] eq "continue"} \
    "picker traffic prevented the queued primary continuation"
unset client backend
automatic::cancel
retry::reset
resume::reset
set automatic::flags {auto_reset_limit 0 auto_continue_after_stop 0}
rename close_backend {}
rename native_close_backend close_backend
rename websocket::send {}
rename websocket::native_send websocket::send

# Physical loss retires the protocol lifetime, preserving only verified advice.
rename websocket::send websocket::native_send
rename close_backend native_close_backend
proc websocket::send {socket type message} { lappend ::routed [list $socket $message]; return 1 }
proc close_backend {channel} { lappend ::closedBridges $channel }
set availability [list $transport::reattaching $transport::unavailable]
foreach progressed {0 1} {
    auto_begin 0 $progressed
    stream_completed $autoTurn $streamError [expr {$progressed ? $streamProgress : {[]}}]
    set streamCallback [lindex [dict values $timers] 0]
    transport::lost {shared app-server proxy disconnected}
    uplevel #0 $streamCallback
    check {[dict size $timers] == 0 && $sent eq "" && $retry::current eq "" && $automatic::current eq ""} \
        "proxy loss retained pending stream recovery"
    auto_begin 0 $progressed
    stream_completed $autoTurn $websocketError [expr {$progressed ? $streamProgress : {[]}}]
    set freshTimers $timers
    uplevel #0 $streamCallback
    check {$timers eq $freshTimers && $sent eq ""} "old generation consumed a fresh stream timer"
    fire
    check {[llength $sent] == 1} "fresh stream work failed after proxy retirement"
    if {$progressed} { auto_followup }
    automatic::cancel
    retry::reset
}
lassign $availability transport::reattaching transport::unavailable
set listener [file tempfile listenerPath]
set client old-client
set backend old-bridge
set recovery::target t1
set recovery::yolo 0
set oldGeneration $transport::generation
auto_begin 1 1
completed $autoTurn failed usageLimitExceeded
fire
set staleActions [dict values $timers]
set staleId [field $automatic::current opId]
set retry::finished [dict create [list t1 reused-turn] 1]
set retry::internal [dict create $staleId 1]
set recovery::seen [dict create 31 1]
set before [llength $sent]
capacity_title [huddle string disconnect-title] disconnect-title-thread
transport::lost {shared app-server proxy disconnected}
check {[info exists listener] && $recovery::target eq "t1" && !$recovery::yolo} \
    "transport loss destroyed the endpoint or verified session advice"
check {![info exists client] && ![info exists backend] && [dict size $timers] == 0 && \
    $retry::current eq "" && $automatic::current eq "" && $retry::finished eq "" && \
    $retry::internal eq "" && $retry::usedIds eq "" && $automatic::ids eq "" && \
    $automatic::live eq "" && $automatic::selection eq "" && $recovery::seen eq "" && \
    $recovery::pending eq "" && $recovery::helpers eq "" && $recovery::helperRequests eq ""} \
    "transport retirement retained connection ownership"

# A metadata-only picker can arrive before the new main client. Its replies and
# even an old callback with a reused channel name cannot select the session.
set routed {}
set ticket [incr transport::sequence]
set auxiliary::clients(picker) picker-bridge
set auxiliary::backends(picker-bridge) picker
set auxiliary::tickets(picker) $ticket
auxiliary::event $ticket picker text {{"id":"initialize","method":"initialize","params":{}}}
auxiliary::event $ticket picker text {{"id":31,"method":"thread/list","params":{}}}
check {![info exists client] && $recovery::target eq "t1" && [llength $routed] == 2} \
    "reconnecting picker became the primary client"
set mainTicket [incr transport::sequence]
set auxiliary::clients(new-client) old-bridge
set auxiliary::backends(old-bridge) new-client
set auxiliary::tickets(new-client) $mainTicket
auxiliary::event $mainTicket new-client text $resumeRequest
check {$client eq "new-client" && $backend eq "old-bridge" && $recovery::target eq "t1"} \
    "activation did not promote the new bridge or lost verified advice before acknowledgement"
check {[lindex $sent end] eq $resumeRequest} "reattachment reapplied launch permissions"
set pending $recovery::pending
set routedBefore $routed
backend_event old-bridge text $resumeReply $oldGeneration
connection new-client text $request $oldGeneration
foreach action $staleActions { uplevel #0 $action }
check {$pending eq $recovery::pending && $routed eq $routedBefore && [dict size $timers] == 0} \
    "old bridge replies or timers crossed protocol lifetimes"
set nativeReply [string map {never on-request dangerFullAccess readOnly} $resumeReply]
auxiliary::backend $mainTicket old-bridge text $nativeReply
check {$recovery::target eq "t1" && !$transport::reattaching && !$transport::unavailable && \
    !$recovery::yolo && [lindex [lindex $routed end] 0] eq "new-client"} \
    "reused activation ID failed or native permission changes were overridden"
check {[llength $sent] == $before + 1} "transport restoration submitted unsolicited work"
auxiliary::close picker

# Newly submitted work may recover, even when turn and RPC IDs repeat. A stale
# timer must not operate on that fresh chain, or consume its current timer.
connection new-client text $request $mainTicket
reply 7 reused-turn
completed reused-turn
set freshTimers $timers
foreach action $staleActions { uplevel #0 $action }
transport::dispatch $oldGeneration retry::fire
check {$timers eq $freshTimers && [dict size $timers] == 1} "stale callback touched fresh recovery"
fire
check {[llength $sent] == $before + 3} "fresh post-reconnect overload recovery failed"
set generated [huddle get_stripped [::huddle::json2huddle [lindex $sent end]] id]
transport::retire
connection fresh-client text $request
reply 7 reused-turn
completed reused-turn
fire
check {[huddle get_stripped [::huddle::json2huddle [lindex $sent end]] id] ne $generated} \
    "generated request IDs repeated across reconnects"
transport::retire
set transport::reattaching 1
set automatic::flags {auto_reset_limit 0 auto_continue_after_stop 0}
connection fresh-client text $resumeRequest
set activeReply [string map [list {"turns":[]} {"turns":[{"id":"foreign-live","status":"inProgress","items":[]}]}] $nativeReply]
retry::server $activeReply
connection fresh-client text $request
reply 7 foreign-live
completed foreign-live
check {[dict size $timers] == 0} "reattachment adopted a pre-existing running turn"
transport::retire

# Promoted picker activations and later primary reconnects share the cwd filter.
cwd_arguments {}
set cwdResume [::huddle::json2huddle $resumeRequest]
huddle set cwdResume params cwd [huddle string $implicitCwd]
set cwdResume [json_dump $cwdResume]
set ticket [incr transport::sequence]
set auxiliary::clients(cwd-client) cwd-bridge
set auxiliary::backends(cwd-bridge) cwd-client
set auxiliary::tickets(cwd-client) $ticket
auxiliary::event $ticket cwd-client text $cwdResume
check {$client eq "cwd-client" && \
    [huddle type [::huddle::json2huddle [lindex $sent end]] params cwd] eq "null"} \
    "picker promotion bypassed the synthetic cwd filter"
transport::retire
check {$implicitCwd eq [pwd]} "transport retirement lost the launch cwd marker"
connection fresh-client text $cwdResume
check {[huddle type [::huddle::json2huddle [lindex $sent end]] params cwd] eq "null"} \
    "primary reconnection bypassed the synthetic cwd filter"
transport::retire
cwd_arguments {resume}

# Already queued upgrade/handshake callbacks must not close a reused channel.
set channel [file tempfile callbackPath]
set ticket [incr transport::sequence]
set handshakes($channel) [dict create ticket $ticket timer "" lines {} size 0]
handshake $channel [expr {$ticket - 1}]
drop_handshake $channel [expr {$ticket - 1}]
check {![catch {fconfigure $channel}] && [info exists handshakes($channel)]} \
    "stale frontend handshake closed a new connection"
drop_handshake $channel
file delete $callbackPath
set channel [file tempfile callbackPath]
set upgrades($channel) [dict create ticket $ticket timer ""]
backend_upgrade_read $channel [expr {$ticket - 1}]
backend_upgraded $channel 0 [expr {$ticket - 1}]
check {![catch {fconfigure $channel}] && [info exists upgrades($channel)]} \
    "stale backend upgrade touched a new connection"
unset upgrades($channel)
close $channel
file delete $callbackPath
close $listener
unset listener
file delete $listenerPath
rename close_backend {}
rename native_close_backend close_backend
rename websocket::send {}
rename websocket::native_send websocket::send
set transport::reattaching 0
set transport::unavailable 0
set automatic::flags {auto_reset_limit 0 auto_continue_after_stop 0}

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
    catch {close $channel}
    file delete $scratch
    if {$failed} { error $message }
    return $::upgraded
}
set backend handshake-fixture
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
unset backend

set unitPhase 14
# Keep CPU-heavy checks out of the transport cases' fixed deadlines, while
# overlapping independent four-case batches with the remaining IO/shutdown waits.
set transportJob [open [list | tclsh [file join [file dirname [info script]] transport.test.tcl] 2>@1] r]
fconfigure $transportJob -blocking 0
fileevent $transportJob readable [list transport_output $transportJob]

# A fake backend echoes one frame and ignores graceful termination.
rename after {}
rename real_after after
set echoFixture {
    trap SIG_IGN SIGTERM
    proc echo {socket type message} {
        if {$type eq "text"} { websocket::send $socket text $message }
    }
    fixture::start echo
    vwait forever
}
set backend [open [list | expect -c "[list source $proxyFixture]\n$echoFixture"] r+]
set ready 0
set frameReady 0
set frame ""
rename backend_event native_backend_event
proc backend_event {socket type message} {
    if {$type eq "text"} {
        set ::frame $message
        set ::frameReady 1
    }
}
set child [lindex [pid $backend] 0]
set startup ""
set deadline ""
set failed [catch {
    backend_attach 3000
    set ready 1
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
rename backend_event {}
rename native_backend_event backend_event
if {$failed} { error $message }
check {$ready == 1} "fake backend startup timed out"
check {$frameReady == 1} "fake backend frame timed out"
check {[huddle equal [::huddle::json2huddle $frame] [::huddle::json2huddle $request]]} "proxy WebSocket framing changed JSON data or types"
check {$frame eq "\n$request\n"} "unchanged proxy JSON lost its original whitespace"
check {[clock milliseconds] - $before < 3000} "backend cleanup was not bounded"
check {[catch {exec kill -0 $child}]} "backend survived cleanup"
cleanup

# Cleanup also owns both stderr pipe ends when launching the backend fails.
set ::diagnostics::tail ""
set ::diagnostics::truncated 0
set channels [lsort [chan names]]
lassign [chan pipe] ::diagnostics::channel ::diagnostics::writer
fconfigure $::diagnostics::channel -blocking 0 -encoding binary -translation binary
puts -nonewline $::diagnostics::writer STARTUP_PARTIAL
flush $::diagnostics::writer
cleanup
cleanup
check {[lsort [chan names]] eq $channels} "repeated cleanup leaked a diagnostic pipe end"
check {$::diagnostics::tail eq "STARTUP_PARTIAL"} "cleanup lost partial startup diagnostics"
set ::diagnostics::tail ""

set unitPhase 15
# Independent native picker transports, exercised through the real wrapper/PTY.
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set channel [open [file join $scratch codex] w]
puts $channel {#!/usr/bin/env expect}
puts $channel [list source $proxyFixture]
puts $channel {
    package require json
    package require json::write
    package require huddle::json
    json::write indented 0
    proc check {condition message} {
        if {![uplevel 1 [list expr $condition]]} { error $message }
    }
    proc bgerror {message} { puts stderr $message; exit 91 }
    after 12000 {error "picker fixture timed out"}
    if {[lrange $argv 0 2] eq {app-server daemon start}} { exit 0 }
    if {[lrange $argv 0 1] eq {app-server proxy}} {
        check {![info exists env(CODEX_RETRY_TOKEN)]} "tunnel inherited the TUI credential"
        set identity [open [file join $env(PICKER_SCRATCH) children] a]
        puts $identity [pid]
        close $identity
        proc respond {socket type text} {
            if {$type ne "text"} { return }
            set request [json::json2dict $text]
            set method [dict get $request method]
            set encoded [huddle jsondump [huddle get [::huddle::json2huddle $text] id] "" ""]
            switch $method {
                initialize {
                    check {![info exists ::role]} "transport initialized twice"
                    set ::role [dict get $request params role]
                    websocket::send $socket text [format { {"id":%s,"result":{"pid":%s}} } $encoded [pid]]
                }
                thread/resume {
                    check {[info exists ::role]} "transport did not initialize"
                    set approval [expr {$::role eq "main" ? "never" : "on-request"}]
                    set sandbox [expr {$::role eq "main" ? "danger-full-access" : "read-only"}]
                    check {[dict get $request params approvalPolicy] eq $approval && \
                        [dict get $request params sandbox] eq $sandbox} "picker consumed or inherited launch YOLO"
                    set thread [dict get $request params threadId]
                    set sandbox [expr {$::role eq "main" ? "dangerFullAccess" : "readOnly"}]
                    websocket::send $socket text [format { {"id":%s,"result":{"thread":{"id":"%s"},"model":"fixture","modelProvider":"openai","approvalPolicy":"%s","sandbox":{"type":"%s"}}} } $encoded $thread $approval $sandbox]
                }
                thread/list {
                    websocket::send $socket text [format { {"id":%s,"result":{"data":[{"id":"auxiliary-session"}],"pid":%s}} } $encoded [pid]]
                    if {[dict exists $request params searchTerm]} {
                        # These must never reach the primary recovery engine.
                        foreach event {
                            {"method":"thread/settings/updated","params":{"threadId":"primary-session","threadSettings":{"approvalPolicy":"on-request","sandboxPolicy":{"type":"readOnly"}}}}
                            {"method":"thread/closed","params":{"threadId":"primary-session"}}
                            {"id":7,"error":{"code":-1,"message":"auxiliary failure"}}
                        } { websocket::send $socket text "\{$event\}" }
                    }
                }
                turn/start {
                    if {![info exists ::turned]} {
                        set ::turned 1
                        websocket::send $socket text { {"id":7,"result":{"turn":{"id":"failed","status":"inProgress","items":[]}}} }
                        websocket::send $socket text { {"method":"turn/completed","params":{"threadId":"primary-session","turn":{"id":"failed","status":"failed","items":[{"type":"fileChange","id":"progress"}],"error":{"message":"fixture overload","codexErrorInfo":"serverOverloaded"}}}} }
                    } else {
                        set params [dict get $request params]
                        check {[llength [dict get $params input]] == 1 && \
                            [dict get [lindex [dict get $params input] 0] text] eq "continue" && \
                            [dict get $params threadId] eq "primary-session"} "queued primary recovery changed"
                        websocket::send $socket text [format { {"id":%s,"result":{"turn":{"id":"recovered","status":"inProgress","items":[]}}} } $encoded]
                        websocket::send $socket text { {"method":"turn/completed","params":{"threadId":"primary-session","turn":{"id":"recovered","status":"completed","items":[]}}} }
                    }
                }
                fixture/fail { exit 0 }
                default { error "unexpected picker fixture method" }
            }
        }
        fixture::start respond
        vwait forever
    }
    set url [lindex $argv 1]
    set token $env([lindex $argv 3])
    set identity [open [file join $env(PICKER_SCRATCH) children] a]
    puts $identity [pid]
    close $identity
    if {$env(PICKER_MODE) eq "input-eof"} {
        trap {puts PICKER_EOF_DRAINED; flush stdout; exit 19} SIGTERM
    }
    set terminalMode [exec stty -g <@stdin]
    exec stty raw -echo <@stdin
    fconfigure stdin -blocking 0 -encoding utf-8 -translation lf
    proc receive {socket type text} {
        if {$type eq "connect"} { set ::connected $socket; unset -nocomplain ::closed($socket) }
        if {$type eq "text"} { lappend ::messages($socket) [json::json2dict $text] }
        if {$type in {close disconnect error timeout}} { set ::closed($socket) 1 }
        incr ::changed
    }
    set changed 0
    proc until {condition} {
        set timer [after 7000 {error "picker protocol wait timed out"}]
        try { while {![uplevel 1 [list expr $condition]]} { vwait ::changed } } finally { after cancel $timer }
    }
    proc open_client {role} {
        set ::connected ""
        set socket [websocket::open $::url receive -headers [list Authorization "Bearer $::token"] -timeout 2000]
        until {$::connected eq $socket}
        set reply [rpc $socket [format { {"id":1,"method":"initialize","params":{"role":"%s"}} } $role]]
        return [list $socket [dict get $reply result pid]]
    }
    proc rpc {socket text} {
        set ::messages($socket) {}
        websocket::send $socket text $text
        until {[llength $::messages($socket)] > 0}
        return [lindex $::messages($socket) 0]
    }
    lassign [open_client main] main mainPid
    lassign [open_client picker] picker pickerPid
    check {$pickerPid != $mainPid} "picker reused the main backend"
    rpc $picker { {"id":31,"method":"thread/resume","params":{"threadId":"auxiliary-session","approvalPolicy":"on-request","sandbox":"read-only"}} }
    rpc $main { {"id":31,"method":"thread/resume","params":{"threadId":"primary-session","approvalPolicy":"on-request","sandbox":"read-only"}} }
    rpc $main { {"id":7,"method":"turn/start","params":{"threadId":"primary-session","input":[{"type":"text","text":"original"}],"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}} }
    until {[string first serverOverloaded $::messages($main)] >= 0}
    # Equal IDs and conflicting replies must stay visible only on their channel.
    rpc $picker { {"id":7,"method":"thread/list","params":{"searchTerm":"synthetic"}} }
    until {[llength $::messages($picker)] == 4}
    check {[string first {auxiliary failure} $::messages($main)] < 0} "auxiliary reply leaked onto primary"
    websocket::close $picker
    lassign [open_client picker] picker reopenedPid
    check {$reopenedPid != $mainPid} "reopened picker reused the main backend"
    rpc $picker { {"id":7,"method":"thread/list","params":{}} }
    websocket::send $picker text { {"id":8,"method":"fixture/fail","params":{}} }
    until {[info exists ::closed($picker)]}
    # Fail-closed attempts while an authenticated main client is already live.
    proc denied {socket type text} {
        if {$type eq "connect"} { error "invalid auxiliary handshake was accepted" }
        if {$type in {close disconnect error timeout}} { set ::rejected 1; incr ::changed }
    }
    foreach headers [list {Authorization {Bearer invalid}} \
        [list Authorization "Bearer $token" Origin https://example.invalid] \
        [list Authorization "Bearer $token" authorization "Bearer $token"]] {
        set rejected 0
        websocket::open $url denied -headers $headers -timeout 1000
        until {$::rejected}
    }
    set port [lindex [split [string trimright $url /] :] end]
    set malformed [socket 127.0.0.1 $port]
    fconfigure $malformed -blocking 0 -buffering none -translation crlf
    fileevent $malformed readable [list apply {{socket} {
        read $socket
        if {[eof $socket]} { set ::rawClosed 1; incr ::changed }
    }} $malformed]
    puts $malformed "GET / HTTP/1.1\nBad header\n\n"
    until {[info exists ::rawClosed]}
    close $malformed
    # Leave both an authenticated client and an incomplete handshake for teardown.
    lassign [open_client picker] picker finalPid
    set pending [socket 127.0.0.1 $port]
    puts -nonewline $pending "GET / HTTP/1.1\r\n"
    flush $pending
    puts PICKER_INPUT_READY
    flush stdout
    fileevent stdin readable {
        if {[read stdin 1] eq "q"} { puts PICKER_INPUT_OK; flush stdout; set ::typed 1; incr ::changed }
    }
    until {[info exists ::typed]}
    if {$env(PICKER_MODE) eq "normal"} {
        until {[string first recovered $::messages($main)] >= 0}
        puts PICKER_RECOVERY_OK
        flush stdout
        exec stty $terminalMode <@stdin
        exit 7
    }
    if {$env(PICKER_MODE) eq "primary-close"} { websocket::close $main; after 100 {exit 7} }
    vwait forever
}
close $channel
file attributes [file join $scratch codex] -permissions 0755
set wrapper [file normalize [file join [file dirname [info script]] .. codex-retry]]
file mkdir [file join $scratch codex-retry]
set channel [open [file join $scratch codex-retry config.json] w]
puts $channel { {"auto_continue_after_stop":true} }
close $channel
set pickerEnvironment [concat [array get env PATH] [array get env XDG_CONFIG_HOME]]
set env(PATH) "$scratch:$env(PATH)"
set env(XDG_CONFIG_HOME) $scratch
set env(PICKER_SCRATCH) $scratch
set pickerDriver {
    set wrapperPid [exp_pid]
    set wrapperSpawn $spawn_id
    if {$env(PICKER_MODE) eq "input-eof"} {
        close_on_eof -i $wrapperSpawn 0
        set input [open [file join $env(PICKER_SCRATCH) input.fifo] r+]
    }
    set failed [catch {
        expect {
            -exact PICKER_INPUT_READY {}
            eof {error "picker transport failed before keyboard forwarding"}
            timeout {error "picker transport timed out"}
        }
        if {[info exists input]} { puts -nonewline $input q; flush $input } else { send -- q }
        expect {
            -exact PICKER_INPUT_OK {}
            eof {error "picker closure disconnected primary input"}
            timeout {error "primary keyboard forwarding stopped"}
        }
        switch $env(PICKER_MODE) {
            normal {
                expect {
                    -exact PICKER_RECOVERY_OK {}
                    eof {error "picker cancelled primary recovery"}
                    timeout {error "queued primary recovery timed out"}
                }
            }
            input-eof { close $input; unset input }
            term { exec kill -TERM $wrapperPid }
            hup { exec kill -HUP $wrapperPid }
        }
        if {$env(PICKER_MODE) eq "input-eof"} {
            expect {
                -exact PICKER_EOF_DRAINED {}
                eof {error "wrapper EOF lost final TUI output"}
                timeout {error "wrapper EOF did not drain TUI"}
            }
        }
        expect {
            -re {To resume this session, run:\r*\n[^\r\n]*primary-session --yolo} {}
            eof {error "picker changed primary exit advice"}
            timeout {error "primary exit advice timed out"}
        }
        expect {
            eof {}
            timeout {error "picker shutdown did not finish"}
        }
        set result [wait -i $wrapperSpawn]
        set expected [dict get {normal 7 primary-close 7 term 143 hup 129 input-eof 19} $env(PICKER_MODE)]
        if {[lindex $result 2] != 0 || [lindex $result 3] != $expected} { error "picker shutdown changed native status: $result" }
    } message]
    if {[info exists input]} { close $input }
    if {$failed} {
        catch {exec kill -TERM $wrapperPid}
        catch {expect -timeout 2 eof}
        catch {exec kill -KILL $wrapperPid}
        puts stderr $message
        exit 1
    }
    exit 0
}
set pickerRuns {}
foreach mode {normal primary-close term hup input-eof} {
    set modeScratch [file join $scratch $mode]
    file mkdir $modeScratch
    set channel [open [file join $modeScratch children] w]
    close $channel
    set launch [list $wrapper resume --last --yolo]
    if {$mode eq "normal"} { set launch [list $wrapper resume --yolo] }
    if {$mode eq "input-eof"} {
        exec mkfifo [file join $modeScratch input.fifo]
        set launch [concat [list sh -c {input=$1; shift; exec "$@" <"$input"} sh \
            [file join $modeScratch input.fifo]] $launch]
    }
    set configuredDriver "set timeout 10\n[list spawn -noecho {*}$launch]\n$pickerDriver"
    set driver [open [list | env PICKER_MODE=$mode PICKER_SCRATCH=$modeScratch \
        expect -c $configuredDriver 2>@1] r]
    lappend pickerRuns [list $driver $modeScratch]
}
# Each driver owns its PTY and children; overlap independent shutdown waits.
set failed 0
set message ""
foreach run $pickerRuns {
    lassign $run driver modeScratch
    set output [read $driver]
    if {[catch {close $driver} result]} {
        set failed 1
        append message "\n[file tail $modeScratch]: $output$result"
    }
    set channel [open [file join $modeScratch children] r]
    set children [read $channel]
    close $channel
    foreach child $children {
        if {![catch {exec kill -0 $child}]} {
            catch {exec kill -TERM $child}
            set failed 1
            append message "\nowned picker bridge survived cleanup"
        }
    }
}
array set env $pickerEnvironment
unset env(PICKER_SCRATCH)
file delete -force $scratch
check {!$failed} "native picker fake-process regression failed: $message"

set unitPhase 16
# Exercise the real main/PTY lifecycle with synchronous forwarding teardown.
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set channel [open [file join $scratch codex] w]
puts $channel {#!/usr/bin/env expect}
puts $channel [list source $proxyFixture]
puts $channel {
    fconfigure stdout -buffering full -encoding utf-8 -translation lf
    if {[lrange $argv 0 2] eq {app-server daemon start}} { exit 0 }
    if {[lindex $argv 0] eq "app-server"} {
        if {[lindex $argv 1] ne "proxy"} { exit 90 }
        proc respond {socket type message} {
            if {$type eq "text"} {
                websocket::send $socket text {{"id":91,"result":{}}}
                websocket::send $socket text {{"id":92,"result":{}}}
            }
        }
        fixture::start respond
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
set pipeFixture "set argv0 pipe-fixture\n[list source $wrapper]\n"
append pipeFixture {
    if {[catch {
        trap {exit 99} SIGINT
        set handler [trap SIGINT]
        set arguments [list PIPE_SURVIVED --config {model="fixture capacity";$literal} --disable fixture_feature]
        set channel [terminal::pipe [list | sh -c {kill -INT $$; printf '%s\n' "$@"} fixture {*}$arguments] r]
        set output [read $channel]
        close $channel
        if {$output ne "[join $arguments \n]\n" || [trap SIGINT] ne $handler} {
            error "pipe SIGINT inheritance, argv boundaries or wrapper handler restoration failed"
        }
        set channel [terminal::pipe [list | sh -c {exit 23}] r]
        if {![catch {close $channel} message options] || \
            [lindex [dict get $options -errorcode] 0] ne "CHILDSTATUS" || \
            [lindex [dict get $options -errorcode] 2] != 23 || [trap SIGINT] ne $handler} {
            error "failed pipe child lost the wrapper SIGINT handler"
        }
        rename send native_send
        proc send {args} { lappend ::interrupts $args; error "TUI already exited" }
        rename shutdown native_shutdown
        proc shutdown {status} { set ::interruptedStartup $status }
        set interrupts {}
        set ::tuiSpawn closed-tui
        terminal::interrupt
        if {$interrupts ne [list [list -i closed-tui -- "\003"]] || [info exists ::interruptedStartup]} {
            error "SIGINT overrode an exiting native TUI's status"
        }
        unset ::tuiSpawn
        terminal::interrupt
        if {$::interruptedStartup != 130} { error "SIGINT did not cancel startup" }
    } message]} { puts stderr $message; exit 1 }
}
set failed [catch {exec expect -c $pipeFixture 2>@1} message]
check {!$failed} "owned pipe interrupt handling failed: $message"
set fixture "set argv0 disconnect-fixture\n[list source $wrapper]\n"
append fixture {
    package require websocket
    # Initial resizing must replace the TUI's deliberately different dimensions.
    set stty_init {rows 1 columns 1}
    set forwarded 0
    rename websocket::send websocket::native_send
    proc websocket::send {socket type message} {
        if {$socket ne "fixture"} { return [websocket::native_send $socket $type $message] }
        incr ::forwarded
        connection $socket disconnect ""
        puts stderr FORWARDING_DISCONNECTED
        flush stderr
        return -1
    }
    rename spawn native_spawn
    proc spawn {args} {
        set result [uplevel 1 [list native_spawn {*}$args]]
        set ::client fixture
        backend_send {{"id":90,"method":"fixture/ready"}}
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

# Bound line reads from the external shared fixture, including startup and probes.
proc fixture_line {channel} {
    fconfigure $channel -blocking 0
    set ::fixtureReady 0
    fileevent $channel readable [list apply {{channel} {
        if {[gets $channel ::fixtureLine] >= 0} { set ::fixtureReady 1 } elseif {[eof $channel]} { set ::fixtureReady -1 }
    }} $channel]
    set timer [after 2000 {set ::fixtureReady -1}]
    vwait ::fixtureReady
    after cancel $timer
    fileevent $channel readable ""
    if {$::fixtureReady != 1} { error "shared fixture line read failed or timed out" }
    return $::fixtureLine
}

set unitPhase 17
# Exercise launch flag consumption and permission verification over the real proxy.
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set channel [open [file join $scratch codex] w]
puts $channel {#!/usr/bin/env expect}
puts $channel [list source $proxyFixture]
puts $channel {
    package require json
    package require websocket
    fconfigure stdin -encoding utf-8 -translation lf
    fconfigure stdout -encoding utf-8 -translation lf
    set mode $env(YOLO_FIXTURE_MODE)
    set fresh [expr {$mode in {fresh fresh-alias}}]
    set effective $env(YOLO_FIXTURE_ENABLED)
    set confirmation {{"id":31,"result":{"thread":{"id":"t1","turns":[{"id":"saved","items":[{"type":"agentMessage","text":"synthetic history é"}]}]},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"},"activePermissionProfile":{"id":"server-profile","extends":"fixture-parent"}}}}
    if {!$effective} { set confirmation [string map {never on-request dangerFullAccess readOnly} $confirmation] }
    set turn {{"id":7,"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"quoted \"input\" é"}],"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}}}
    if {!$effective} { set turn [string map {never on-request dangerFullAccess readOnly} $turn] }
    if {$argv eq {--shared-server}} {
        set loaded [expr {$mode ne "cold"}]
        set starts 0
        set attachments 0
        proc accept_shared {transport address port} {
            fconfigure $transport -buffering line -encoding utf-8 -translation lf
            set action [gets $transport]
            if {$action eq "inspect"} {
                puts $transport [format {{"loaded":%s,"starts":%s,"attachments":%s,"session":%s}} \
                    $::loaded $::starts $::attachments $::confirmation]
                close $transport
                return
            }
            if {$action eq "start"} {
                incr ::starts
                if {$::mode eq "startup-rejection"} { puts $transport rejected } else {
                    set ::loaded 1
                    puts $transport ready
                }
                close $transport
                return
            }
            incr ::attachments
            if {$action ne "attach" || !$::loaded || $::mode eq "attachment-rejection"} {
                puts $transport rejected
                close $transport
                return
            }
            puts $transport ready
            if {$::mode eq "upgrade-rejection"} {
                puts $transport "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
                close $transport
                return
            }
            fixture::accept serve $transport
        }
        proc serve {transport type line} {
            global mode fresh effective confirmation turn env
            if {$type eq "connect"} { set ::log [open $env(YOLO_FIXTURE_LOG) w] }
            if {$type in {close disconnect}} { catch {close $::log}; return }
            if {$type eq "text"} {
                set log $::log
                puts $log $line
                flush $log
                set message [json::json2dict $line]
                switch [dict get $message method] {
                    thread/start - thread/resume {
                        set starting [expr {[dict get $message method] eq "thread/start"}]
                        if {$starting || [dict get $message params threadId] eq "t1"} {
                            if {$starting != $fresh} { exit 3 }
                            set approval [expr {$effective ? "never" : "on-request"}]
                            set sandbox [expr {$effective ? "danger-full-access" : "read-only"}]
                            if {[dict get $message params approvalPolicy] ne $approval || \
                                [dict get $message params sandbox] ne $sandbox || \
                                [dict get $message params config] ne {sample true}} { exit 3 }
                            switch $mode {
                                rejection { websocket::send $transport text {{"id":31,"error":{"code":-32000,"message":"fixture rejection","data":{"detail":"unchanged"}}}} }
                                mismatch { websocket::send $transport text [string map {dangerFullAccess readOnly} $confirmation] }
                                malformed { websocket::send $transport text {{"id":31,"result":{}}} }
                                premature { return }
                                default { websocket::send $transport text $confirmation }
                            }
                        } else {
                            if {[dict get $message params approvalPolicy] ne "on-request" || \
                                [dict get $message params sandbox] ne "read-only"} { exit 4 }
                            websocket::send $transport text {{"id":35,"result":{"thread":{"id":"other"},"approvalPolicy":"on-request","sandbox":{"type":"readOnly"}}}}
                        }
                    }
                    turn/start {
                        if {$line ne $turn} { exit 5 }
                        websocket::send $transport text {{"id":7,"result":{"turn":{"id":"fixture-turn","items":[]}}}}
                    }
                    thread/settings/update {
                        if {[dict get $message params approvalPolicy] ne "on-request"} { exit 6 }
                        websocket::send $transport text {{"id":34,"result":{}}}
                    }
                    default { exit 8 }
                }
                flush $transport
            }
        }
        set listener [socket -server accept_shared -myaddr 127.0.0.1 0]
        puts [lindex [fconfigure $listener -sockname] 2]
        flush stdout
        vwait forever
    }
    if {[lindex $argv 0] eq "app-server"} {
        set starting [expr {[lrange $argv 0 2] eq {app-server daemon start}}]
        set command [expr {$starting ? [lrange $argv 0 2] : [lrange $argv 0 1]}]
        set options [lrange $argv [expr {$starting ? 3 : 2}] end]
        if {(!$starting && $command ne {app-server proxy}) || \
            $options ne {-c {fixture="with spaces"} --enable fixture}} { exit 2 }
        set transport [socket 127.0.0.1 $env(YOLO_FIXTURE_PORT)]
        fconfigure $transport -buffering line -encoding utf-8 -translation lf
        puts $transport [expr {$starting ? "start" : "attach"}]
        if {[gets $transport] ne "ready"} {
            puts stderr "fixture shared [expr {$starting ? "startup" : "attachment"}] rejection"
            exit 12
        }
        if {$starting} { close $transport; exit 0 }
        set identity [open $env(YOLO_FIXTURE_PID) w]
        puts $identity [pid]
        close $identity
        fconfigure stdin -blocking 0 -encoding binary -translation binary
        fconfigure stdout -buffering none -encoding binary -translation binary
        fconfigure $transport -blocking 0 -buffering none -encoding binary -translation binary
        proc forward {from to} {
            puts -nonewline $to [read $from 16384]
            flush $to
            if {[eof $from]} { exit 0 }
        }
        fileevent stdin readable [list forward stdin $transport]
        fileevent $transport readable [list forward $transport stdout]
        vwait forever
    }
    if {[lrange $argv 4 end] ne $env(YOLO_FIXTURE_ARGUMENTS)} { exit 9 }
    set ready 0
    proc receive {socket type message} {
        if {$type eq "connect"} {
            if {$::fresh} {
                websocket::send $socket text {{"id":31,"method":"thread/start","params":{"approvalPolicy":"on-request","sandbox":"read-only","config":{"sample":true},"permissions":null}}}
            } else {
                websocket::send $socket text {{"id":31,"method":"thread/resume","params":{"threadId":"t1","approvalPolicy":"on-request","sandbox":"read-only","config":{"sample":true},"permissions":null}}}
            }
            if {$::mode eq "premature"} { websocket::send $socket text $::turn }
        }
        if {$type ne "text"} { return }
        set response [json::json2dict $message]
        switch [dict get $response id] {
            31 {
                if {$::mode in {rejection mismatch malformed premature}} {
                    # A rejected launch must not proceed even if the TUI tries recovery.
                    websocket::send $socket text $::turn
                    return
                }
                if {$message ne $::confirmation} { exit 10 }
                websocket::send $socket text $::turn
            }
            7 {
                websocket::send $socket text {{"id":34,"method":"thread/settings/update","params":{"threadId":"t1","approvalPolicy":"on-request","sandboxPolicy":{"type":"readOnly"}}}}
                websocket::send $socket text {{"id":35,"method":"thread/resume","params":{"threadId":"other","approvalPolicy":"on-request","sandbox":"read-only"}}}
            }
            35 { set ::ready 1 }
        }
    }
    websocket::open [lindex $argv 1] receive \
        -headers [list Authorization "Bearer $env([lindex $argv 3])"] -timeout 2000
    if {!$ready} { vwait ready }
    if {$mode eq "input-eof"} {
        set terminalMode [exec stty -g <@stdin]
        exec stty raw -echo <@stdin
        fconfigure stderr -encoding utf-8 -translation lf
        trap {
            # More than a PTY buffer must be drained while this handler writes.
            puts -nonewline stderr "EOF_EXIT_BEGIN[string repeat x 32768]\x00utf8:é λEOF_EXIT_DATA_END"
            flush stderr
            exec stty $::terminalMode <@stdin
            puts stderr "\033\[?2004lEOF_EXIT_END"
            flush stderr
            exit 19
        } SIGTERM
        puts -nonewline stdout "\033\[?1003h\033\[?1006h\033\[?2004h"
    }
    if {$mode eq "signal-int"} { exec stty raw -echo <@stdin }
    puts YOLO_PROXY_OK
    flush stdout
    if {$mode eq "input-eof"} { vwait forever }
    if {$mode eq "signal-int"} {
        fconfigure stdin -blocking 0 -encoding binary -translation binary
        fileevent stdin readable {
            if {[read stdin 1] eq "\003"} { exit 19 }
            exit 20
        }
        vwait forever
    }
    if {[gets stdin line] < 0 || $line ne "forwarded"} { exit 11 }
    puts YOLO_INPUT_OK
    flush stdout
    exit 7
}
close $channel
file attributes [file join $scratch codex] -permissions 0755
set resumeDriver {
    set wrapperSpawn $spawn_id
    set wrapper [exp_pid]
    set failed [catch {
        if {$env(YOLO_FIXTURE_MODE) eq "input-eof"} {
            log_user 0
            close_on_eof -i $wrapperSpawn 0
            fconfigure $wrapperSpawn -encoding binary -translation binary
            remove_nulls -i $wrapperSpawn 0
            match_max 65536
            set terminalPath $spawn_out(slave,name)
            # The shell opens this FIFO as wrapper stdin; stdout stays on its PTY.
            # RDWR avoids blocking this driver if the child fails before opening it.
            set input [open $env(YOLO_FIXTURE_FIFO) r+]
        }
        set deadline [expr {[clock milliseconds] + 2000}]
        while {$env(YOLO_FIXTURE_MODE) ni {startup-rejection attachment-rejection} && (![file exists $env(YOLO_FIXTURE_PID)] || [file size $env(YOLO_FIXTURE_PID)] == 0)} {
            if {[clock milliseconds] >= $deadline} { error "resume backend startup timed out" }
            after 10
        }
        if {[file exists $env(YOLO_FIXTURE_PID)]} {
            set identity [open $env(YOLO_FIXTURE_PID) r]
            set backend [string trim [read $identity]]
            close $identity
            if {![string is integer -strict $backend] || $backend <= 0} { error "invalid resume backend PID" }
        }
        if {$::failureText eq ""} {
            expect {
                -exact YOLO_PROXY_OK {}
                eof { error "resume permission exchange failed" }
                timeout { error "resume permission exchange timed out" }
            }
            set expectedStatus 7
            if {$env(YOLO_FIXTURE_MODE) eq "input-eof"} {
                set output $expect_out(buffer)
                set channel [open $env(YOLO_FIXTURE_TERMIOS) r]
                set originalMode [string trim [read $channel]]
                close $channel
                close $input
                unset input
                set expectedStatus 19
            } elseif {[string match signal-* $env(YOLO_FIXTURE_MODE)]} {
                set signame [string toupper [string range $env(YOLO_FIXTURE_MODE) 7 end]]
                set expectedStatus [dict get {TERM 143 HUP 129 INT 130} $signame]
                if {$signame eq "INT"} { set expectedStatus 19 }
                exec kill -$signame $wrapper
            } elseif {$env(YOLO_FIXTURE_MODE) eq "eof"} {
                send -- "\004"
                set expectedStatus 11
            } else {
                send -- "forwarded\r"
                expect {
                    -exact YOLO_INPUT_OK {}
                    eof { error "resume terminal forwarding failed" }
                    timeout { error "resume terminal forwarding timed out" }
                }
            }
        } else {
            expect {
                -exact $::failureText {}
                eof { error "guarded resume failed without visible guidance" }
                timeout { error "guarded resume failure timed out" }
            }
            set expectedStatus 1
        }
        if {$env(YOLO_FIXTURE_MODE) eq "input-eof"} {
            expect {
                -re {(?s).+} {
                    append output $expect_out(0,string)
                    if {[string length $output] > 65536} { error "unbounded input-EOF output" }
                    exp_continue -continue_timer
                }
                eof {}
                timeout { error "input EOF did not drain and exit" }
            }
            set payload [encoding convertto utf-8 "EOF_EXIT_BEGIN[string repeat x 32768]\x00utf8:é λEOF_EXIT_DATA_END"]
            if {[string first $payload $output] < 0 || \
                [regexp -all EOF_EXIT_BEGIN $output] != 1 || \
                [string first EOF_EXIT_END $output] < 0} { error "input EOF lost or duplicated final TUI output" }
            set restored [string first "\033\[?1006l" $output]
            set advice [string first "To resume this session, run:" $output]
            if {$restored < [string first EOF_EXIT_END $output] || $advice < $restored} {
                error "input EOF lost mouse restoration or exit advice ordering"
            }
            if {[exec stty -g < $terminalPath] ne $originalMode} { error "input EOF did not restore terminal attributes" }
        } else {
            expect {
                eof {}
                timeout { error "resume wrapper exit timed out" }
            }
        }
        set result [wait -i $wrapperSpawn]
        if {$env(YOLO_FIXTURE_MODE) eq "input-eof"} { close -i $wrapperSpawn }
        if {[lindex $result 2] != 0 || [lindex $result 3] != $expectedStatus} {
            error "resume exit status changed: $result"
        }
        if {[info exists backend] && ![catch {exec kill -0 $backend}]} { error "resume backend survived cleanup" }
        exec kill -0 $env(YOLO_FIXTURE_SHARED_PID)
    } message]
    if {$failed} {
        if {[info exists input]} { catch {close $input} }
        catch {exec kill -TERM $wrapper}
        if {[info exists backend]} { catch {exec kill -TERM $backend} }
        catch {expect -timeout 2 eof}
        catch {exec kill -KILL $wrapper}
        catch {close -i $wrapperSpawn}
        puts stderr $message
        exit 1
    }
    exit 0
}
# Each case owns its shared fixture, port, PTY, and request log. Collect eight
# drivers per batch to leave room for stream cases within the 55-second limit.
proc resume_batch {cases} {
    set failures {}
    foreach case $cases {
        dict with case {}
        set failed [catch {
            try {
                set runFailed [catch {read $driver} detail]
                if {[catch {close $driver} closeError]} { set runFailed 1; append detail "\n$closeError" }
                set driver ""
                set probe [socket 127.0.0.1 $port]
                try {
                    fconfigure $probe -buffering line -encoding utf-8 -translation lf
                    puts $probe inspect
                    set after [fixture_line $probe]
                } finally { close $probe }
                exec kill -0 $sharedPid
                if {$runFailed} { error $detail }
                set state [json::json2dict $after]
                check {[field $state loaded] == 1} "shared session unloaded on disconnect"
                check {[field $state starts] == 1 && [field $state attachments] == ($mode ne "startup-rejection")} "startup/attachment was skipped or repeated"
                check {[field $state session] eq [field [json::json2dict $before] session]} "shared session history or settings changed on disconnect"
                check {[field $state session result thread id] eq "t1" && \
                    [field $state session result thread turns] ne ""} "shared session identity or history was lost"
                set messages {}
                if {[file exists $logPath]} {
                    set channel [open $logPath r]
                    try { set messages [split [string trim [read $channel]] \n] } finally { close $channel }
                } else {
                    check {$mode in {startup-rejection attachment-rejection upgrade-rejection}} "shared fixture lost its request log"
                }
                set turns 0
                foreach json $messages {
                    if {$json eq ""} { continue }
                    set message [json::json2dict $json]
                    if {[field $message method] eq "turn/start"} { incr turns }
                }
                check {$turns == ($failureText eq "")} "a guarded launch leaked work or an ordinary launch lost its turn"
            } finally {
                catch {close $driver}
                catch {exec kill -TERM {*}[pid $sharedServer]}
                catch {fconfigure $sharedServer -blocking 1}
                catch {close $sharedServer}
            }
        } message]
        if {$failed} { lappend failures "$mode: $message" }
    }
    if {[llength $failures]} { error [join $failures \n] }
}
set env(PATH) "$scratch:$savedPath"
set jobs {}
set failed [catch {
    foreach mode {session cold last alias fresh fresh-alias ordinary rejection mismatch malformed premature startup-rejection attachment-rejection upgrade-rejection signal-term signal-hup signal-int eof input-eof} {
        set env(YOLO_FIXTURE_MODE) $mode
        set env(YOLO_FIXTURE_ENABLED) [expr {$mode ne "ordinary"}]
        set env(YOLO_FIXTURE_LOG) [file join $scratch $mode.jsonl]
        set env(YOLO_FIXTURE_PID) [file join $scratch $mode.pid]
        set launch {resume t1 --yolo}
        set remaining {resume t1}
        switch $mode {
            last { set launch {--yolo resume --last}; set remaining {resume --last} }
            alias { set launch {resume t1 --dangerously-bypass-approvals-and-sandbox} }
            fresh - fresh-alias {
                set flag --yolo
                if {$mode eq "fresh-alias"} { set flag --dangerously-bypass-approvals-and-sandbox }
                set launch [list $flag {quoted launch prompt é}]
                set remaining [list --cd [pwd] {quoted launch prompt é}]
            }
            ordinary { set launch $remaining }
        }
        set shared [list -c {fixture="with spaces"} --enable fixture]
        set env(YOLO_FIXTURE_ARGUMENTS) [concat $remaining $shared]
        set failureText ""
        switch $mode {
            startup-rejection { set failureText "fixture shared startup rejection" }
            attachment-rejection { set failureText "fixture shared attachment rejection" }
            upgrade-rejection { set failureText "shared app-server WebSocket attachment failed" }
            rejection { set failureText "fixture rejection" }
            mismatch - malformed { set failureText "did not confirm launch --yolo permissions" }
            premature { set failureText "work requested before launch --yolo permissions were confirmed" }
        }
        set spawnLaunch [concat [list $wrapper] $launch $shared]
        if {$mode eq "input-eof"} {
            set env(YOLO_FIXTURE_FIFO) [file join $scratch input.fifo]
            set env(YOLO_FIXTURE_TERMIOS) [file join $scratch input.termios]
            exec mkfifo $env(YOLO_FIXTURE_FIFO)
            set spawnLaunch [concat [list sh -c {
                input=$1; mode=$2; shift 2
                stty -g >"$mode"
                exec "$@" <"$input"
            } sh $env(YOLO_FIXTURE_FIFO) $env(YOLO_FIXTURE_TERMIOS)] $spawnLaunch]
        }
        set configuredDriver "set timeout 8\n[list set failureText $failureText]\n"
        append configuredDriver "[list spawn -noecho {*}$spawnLaunch]\n$resumeDriver"
        set sharedServer [open [list | tclsh [file join $scratch codex] --shared-server] r+]
        set env(YOLO_FIXTURE_SHARED_PID) [lindex [pid $sharedServer] 0]
        set env(YOLO_FIXTURE_PORT) [fixture_line $sharedServer]
        set probe [socket 127.0.0.1 $env(YOLO_FIXTURE_PORT)]
        fconfigure $probe -buffering line -encoding utf-8 -translation lf
        puts $probe inspect
        set before [fixture_line $probe]
        close $probe
        check {[field [json::json2dict $before] loaded] == ($mode ne "cold")} "fixture initial loaded state changed"
        set driver [open [list | expect -c $configuredDriver 2>@1] r]
        lappend jobs [dict create mode $mode driver $driver sharedServer $sharedServer \
            port $env(YOLO_FIXTURE_PORT) sharedPid $env(YOLO_FIXTURE_SHARED_PID) \
            logPath $env(YOLO_FIXTURE_LOG) before $before failureText $failureText]
        unset sharedServer
        if {[llength $jobs] == 8} {
            set batch $jobs
            set jobs {}
            resume_batch $batch
        }
    }
    set batch $jobs
    set jobs {}
    resume_batch $batch
} message]
if {[llength $jobs]} { catch {resume_batch $jobs} }
set env(PATH) $savedPath
if {[info exists sharedServer]} {
    catch {exec kill -TERM {*}[pid $sharedServer]}
    catch {fconfigure $sharedServer -blocking 1}
    catch {close $sharedServer}
}
unset -nocomplain env(YOLO_FIXTURE_MODE) env(YOLO_FIXTURE_ENABLED) env(YOLO_FIXTURE_LOG) env(YOLO_FIXTURE_PID) env(YOLO_FIXTURE_ARGUMENTS) env(YOLO_FIXTURE_PORT) env(YOLO_FIXTURE_SHARED_PID) env(YOLO_FIXTURE_FIFO) env(YOLO_FIXTURE_TERMIOS)
file delete -force $scratch
check {!$failed} "fake resume launch/proxy check failed: $message"

set unitPhase 18
# Backend diagnostics must never cross the live TUI, including unterminated
# messages and bursts larger than both a pipe and the retained diagnostic tail.
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set channel [open [file join $scratch codex] w]
puts $channel {#!/usr/bin/env expect}
puts $channel [list source $proxyFixture]
puts $channel {
    package require json
    package require json::write
    package require websocket
    set mode $env(DIAGNOSTIC_MODE)
    fconfigure stdout -buffering line -encoding utf-8 -translation lf
    fconfigure stderr -encoding utf-8 -translation lf
    if {[lrange $argv 0 2] eq {app-server daemon start}} { exit 0 }
    if {[lindex $argv 0] eq "app-server"} {
        if {[lindex $argv 1] ne "proxy"} { exit 90 }
        puts stderr BACKEND_START
        flush stderr
        trap SIG_IGN SIGTERM
        # Expect installs its own SIGINT trap, overriding the inherited ignore.
        if {$mode eq "ctrl-c-isig"} { trap SIG_IGN SIGINT }
        if {$mode eq "shutdown"} {
            trap {puts -nonewline stderr BACKEND_SHUTDOWN; flush stderr; exit 23} SIGTERM
        }
        set identity [open $env(DIAGNOSTIC_PID) w]
        puts $identity [pid]
        close $identity
        proc request {socket type line} {
            if {$type ne "text"} { return }
            set request [json::json2dict $line]
            set id [dict get $request id]
            if {$id == 9 && ([dict get $request method] ne "turn/interrupt" || \
                [dict get $request params] ne {threadId confirmed-session turnId fixture-turn})} { exit 83 }
            if {[dict get $request method] eq "account/rateLimits/read" && $::mode eq "recovery-no-credit"} {
                websocket::send $socket text [format {{"id":%s,"result":{"accountId":"fixture-account","ordinaryUsageAllowed":false,"rateLimits":{"limitId":"codex","spendControlReached":false,"rateLimitReachedType":"rate_limit_reached"},"rateLimitResetCredits":{"availableCount":0,"credits":null}}}} [json::write string $id]]
                return
            }
            if {[dict get $request method] eq "turn/start" && [string match recovery-* $::mode]} {
                if {![info exists ::recoveryTurns]} { set ::recoveryTurns 0 }
                incr ::recoveryTurns
                set encoded [json::write string $id]
                if {$::recoveryTurns == 1} {
                    if {$id ne "7"} { exit 80 }
                    set encoded 7
                } else {
                    set params [dict get $request params]
                    if {$::mode ne "recovery-stop" || $::recoveryTurns > 4 || \
                        [llength [dict get $params input]] != 1 || \
                        [dict get [lindex [dict get $params input] 0] text] ne "continue" || \
                        [dict get $params threadId] ne "confirmed-session" || \
                        [dict get $params effort] ne "high" || \
                        [dict get $params sandboxPolicy type] ne "dangerFullAccess" || \
                        [dict get $params clientUserMessageId] eq ""} { exit 81 }
                    websocket::send $socket text {{"method":"fixture/recoveryExact","params":{}}}
                }
                set turn recovery-$::recoveryTurns
                set code [expr {$::mode eq "recovery-stop" ? "cyberPolicy" : "usageLimitExceeded"}]
                websocket::send $socket text [format {{"id":%s,"result":{"turn":{"id":"%s","status":"inProgress","items":[]}}}} $encoded $turn]
                # End the synthetic episode successfully after three stops.
                if {$::mode eq "recovery-stop" && $::recoveryTurns == 4} {
                    websocket::send $socket text [format {{"method":"turn/completed","params":{"threadId":"confirmed-session","turn":{"id":"%s","status":"completed","items":[]}}}} $turn]
                } else {
                    websocket::send $socket text [format {{"method":"turn/completed","params":{"threadId":"confirmed-session","turn":{"id":"%s","status":"failed","items":[{"type":"fileChange","id":"already-applied"}],"error":{"message":"neutral fixture failure","codexErrorInfo":"%s"}}}}} $turn $code]
                }
                return
            }
            if {$id == 6} {
                websocket::send $socket text {{"id":6,"error":{"code":-1,"message":"fixture activation rejection"}}}
                return
            }
            if {$id in {4 5}} {
                set selected [expr {$id == 4 ? "confirmed-session" : "switched-session"}]
                set approval [expr {$id == 4 ? "never" : "on-request"}]
                set sandbox [expr {$id == 4 ? "dangerFullAccess" : "readOnly"}]
                websocket::send $socket text [format {{"id":%d,"result":{"thread":{"id":"%s"},"model":"fixture-model","modelProvider":"openai","approvalPolicy":"%s","sandbox":{"type":"%s"}}}} $id $selected $approval $sandbox]
                return
            }
            if {$id == 2} {
                if {$::mode eq "burst"} {
                    websocket::send $socket text {{"method":"fixture/burst","params":{}}}
                    puts -nonewline stderr "BACKEND_DROPPED\n[string repeat x 2097152]\nBACKEND_TAIL"
                } else { puts -nonewline stderr BACKEND_PARTIAL }
                flush stderr
            }
            websocket::send $socket text [format {{"id":%d,"result":{}}} $id]
            if {$id == 2 && $::mode eq "backend-eof"} {
                # Fixture exit drains and reaps the independently running relay.
                exit 0
            }
        }
        fixture::start request
        vwait forever
    }
    set identity [open $env(DIAGNOSTIC_TUI_PID) w]
    puts $identity [pid]
    close $identity
    if {[string match signal-* $mode]} { trap SIG_IGN SIGTERM }
    set terminalMode [exec stty -g <@stdin]
    exec stty raw -echo <@stdin
    puts "\033\[?1003h\033\[?1006h\033\[?2004hLIVE_BEGIN\nDisconnected from this task. Any running work continues.\nTo reconnect, run:\nLIVE_LOOKALIKE\nLIVE_END"
    flush stdout
    fconfigure stdin -blocking 0 -encoding utf-8 -translation lf
    set editorActive 0
    proc receive {socket type message} {
        if {$type eq "connect"} {
            set ::socket $socket
            if {$::mode ne "no-thread"} {
                websocket::send $socket text {{"id":4,"method":"thread/start","params":{"approvalPolicy":"never","sandbox":"danger-full-access"}}}
            } else {
                websocket::send $socket text {{"id":1,"method":"fixture/ready","params":{}}}
            }
        } elseif {$type eq "text"} {
            set response [json::json2dict $message]
            if {[dict exists $response method]} {
                switch -- [dict get $response method] {
                    warning {
                        if {$::mode ne "recovery-no-credit" || \
                            [string first "work remains stopped" [dict get $response params message]] < 0} { exit 82 }
                        puts "RECOVERY_WARNING:[dict get $response params message]"
                        websocket::send $socket text {{"id":2,"method":"fixture/ping","params":{}}}
                    }
                    turn/completed {
                        if {[dict get $response params turn status] eq "failed"} {
                            puts NATIVE_FAILURE
                        } else {
                            puts RECOVERY_SUCCESS
                            websocket::send $socket text {{"id":2,"method":"fixture/ping","params":{}}}
                        }
                    }
                    fixture/recoveryExact { puts RECOVERY_EXACT }
                    default { puts BURST_READY }
                }
            } else {
                set id [dict get $response id]
                if {$id == 4} {
                    # Native selection changes follow the startup acknowledgement.
                    if {$::mode eq "switched"} {
                        websocket::send $socket text {{"id":5,"method":"thread/resume","params":{"threadId":"switched-session","approvalPolicy":"on-request","sandbox":"read-only"}}}
                    }
                    if {$::mode eq "activation-error"} {
                        websocket::send $socket text {{"id":6,"method":"thread/resume","params":{"threadId":"not-confirmed"}}}
                    }
                    websocket::send $socket text {{"id":1,"method":"fixture/ready","params":{}}}
                }
                if {$id in {4 5 6 7}} { return }
                if {$id == 9} {
                    puts TURN_INTERRUPTED
                    flush stdout
                    return
                }
                puts [dict get {1 INPUT_READY 2 PROTOCOL_OK 3 BURST_PROTOCOL_OK} $id]
            }
            flush stdout
        } elseif {$type in {close disconnect}} {
            puts TUI_DISCONNECTED
            flush stdout
        }
    }
    proc input {{character ""}} {
        if {$::editorActive} {
            if {[gets stdin line] < 0} { return }
            if {$line ne "edited"} { exit 12 }
            set ::editorActive 0
            exec stty raw -echo <@stdin
            puts "\033\[?2004hEDITOR_INPUT_OK"
            flush stdout
            websocket::send $::socket text {{"id":2,"method":"fixture/ping","params":{}}}
            return
        }
        if {$character eq ""} { set character [read stdin 1] }
        if {$character eq "\003" && $::mode in {ctrl-c ctrl-c-isig signal-int}} {
            if {![info exists ::interrupted]} {
                set ::interrupted 1
                websocket::send $::socket text {{"id":9,"method":"turn/interrupt","params":{"threadId":"confirmed-session","turnId":"fixture-turn"}}}
                return
            }
            set character x
        }
        if {$character eq "q"} {
            puts CHAR_FORWARDED
            flush stdout
            if {[string match recovery-* $::mode]} {
                websocket::send $::socket text {{"id":7,"method":"turn/start","params":{"threadId":"confirmed-session","input":[{"type":"text","text":"apply fixture"}],"effort":"high","sandboxPolicy":{"type":"dangerFullAccess"}}}}
                return
            }
            if {$::mode eq "external-editor"} {
                set ::editorActive 1
                exec stty $::terminalMode <@stdin
                puts -nonewline stdout "\033\[?2004l\033\[?25hEDITOR_PROMPT> "
                flush stdout
                return
            }
            websocket::send $::socket text {{"id":2,"method":"fixture/ping","params":{}}}
        } elseif {$character eq "r"} {
            puts BURST_INPUT_OK
            flush stdout
            websocket::send $::socket text {{"id":3,"method":"fixture/ping","params":{}}}
        } elseif {$character eq "x"} {
            exec stty $::terminalMode <@stdin
            set prefix "codex --remote [lindex $::argv 1] --remote-auth-token-env CODEX_RETRY_TOKEN"
            set reconnect "$prefix resume native-untrusted"
            if {$::mode eq "no-thread"} { set reconnect $prefix }
            set stop "To stop this task, run $prefix agents, select this task, and press x."
            if {$::mode eq "switched"} { set stop "To stop this task, run:\r\n  $prefix agents" }
            set footer "\033\[?2004l\r\n\033\]0;\007\033\]7501;state=clear\033\\\033\[?25h\033\[32mDisconnected from this task. Work may still be running.\033\[0m\r\nTo reconnect, run:\r\n  $reconnect\r\nUNRELATED_EXIT_TEXT\r\ncodex agents documentation stays\r\nagents server diagnostic\r\n$stop\r\nToken usage so far: total=17 input=11 output=6\r\n"
            # Include split writes and both PTY streams, with native-style ANSI.
            for {set i 0} {$i < [string length $footer]} {incr i 7} {
                puts -nonewline stderr [string range $footer $i $i+6]
                flush stderr
                after 1
            }
            # EOF must not close the PTY and hang up this still-running child.
            close stdin
            close stdout
            close stderr
            after 100
            exit [expr {$::mode eq "normal" ? 0 : 7}]
        }
    }
    websocket::open [lindex $argv 1] receive \
        -headers [list Authorization "Bearer $env([lindex $argv 3])"] -timeout 2000
    # A disconnected client retains its normal keyboard-controlled exit.
    fileevent stdin readable input
    vwait forever
}
close $channel
file attributes [file join $scratch codex] -permissions 0755
set diagnosticFixture {
    # Expect -c runs before normal script argument initialization.
    set argv {--yolo}
    # Advice without an activation is an ordinary launch, not unverified YOLO.
    if {$env(DIAGNOSTIC_MODE) eq "no-thread"} { set argv {} }
    if {[string match recovery-* $env(DIAGNOSTIC_MODE)]} {
        set env(XDG_CONFIG_HOME) [file join [file dirname $env(DIAGNOSTIC_PID)] $env(DIAGNOSTIC_MODE).config]
        file mkdir [file join $env(XDG_CONFIG_HOME) codex-retry]
        set channel [open [file join $env(XDG_CONFIG_HOME) codex-retry config.json] w]
        puts $channel {{"auto_reset_limit":true,"auto_continue_after_stop":true}}
        close $channel
    }
    set terminalMode [exec stty -g <@stdin]
    rename wait native_wait
    proc wait {args} {
        set result [uplevel 1 [list native_wait {*}$args]]
        if {[exec stty -g <@stdin] ne $::terminalMode} { error "terminal mode was not restored" }
        puts NATIVE_WAIT_COMPLETE
        flush stdout
        if {$::env(DIAGNOSTIC_MODE) eq "closed"} { close stderr }
        return $result
    }
    if {[string match launchfail* $env(DIAGNOSTIC_MODE)]} {
        rename spawn native_spawn
        proc spawn {args} {
            set deadline [expr {[clock milliseconds] + 2000}]
            while {![file exists $::env(DIAGNOSTIC_PID)] || [file size $::env(DIAGNOSTIC_PID)] == 0} {
                if {[clock milliseconds] >= $deadline} { error "backend startup timed out" }
                after 10
            }
            if {$::env(DIAGNOSTIC_MODE) eq "launchfail-closed"} { close stderr }
            exec stty raw -echo <@stdin
            puts -nonewline stdout "\033\[?1003h\033\[?1006h"
            flush stdout
            error "fixture TUI launch failure"
        }
    }
    if {$env(DIAGNOSTIC_MODE) eq "missing"} { set env(PATH) $env(DIAGNOSTIC_EMPTY_PATH) }
}
set diagnosticDriver {
    set wrapperSpawn $spawn_id
    set wrapper [exp_pid]
    close_on_eof -i $wrapperSpawn 0
    set terminalPath $spawn_out(slave,name)
    log_user 0
    match_max 131072
    set output ""
    set sentInput 0
    set sentEditorInput 0
    set sentBurstInput 0
    set sentInterrupt 0
    set sentExit 0
    set mode $env(DIAGNOSTIC_MODE)
    set active [expr {$mode ni {launchfail launchfail-closed missing}}]
    set failed [catch {
        expect {
            -re {(?s).+} {
                append output $expect_out(0,string)
                if {[string length $output] > 80000} { error "unbounded backend diagnostics reached the terminal" }
                set released [string first NATIVE_WAIT_COMPLETE $output]
                if {$::actualLaunch} { set released [string first "To resume this session, run:" $output] }
                if {$active} {
                    set live $output
                    if {$released >= 0} { set live [string range $output 0 $released-1] }
                    if {[string first BACKEND_ $live] >= 0 || \
                        [string first "background app-server diagnostics" $live] >= 0} {
                        error "backend diagnostics crossed the live TUI"
                    }
                }
                if {!$sentInput && [string first INPUT_READY $output] >= 0} {
                    set identity [open $env(DIAGNOSTIC_PID) r]
                    set backend [string trim [read $identity]]
                    close $identity
                    set identity [open $env(DIAGNOSTIC_TUI_PID) r]
                    set tui [string trim [read $identity]]
                    close $identity
                    foreach child [list $backend $tui] {
                        if {![string is integer -strict $child] || $child <= 0} { error "invalid diagnostic fixture PID" }
                        exec kill -0 $child
                    }
                    send -- q
                    set sentInput 1
                }
                if {$mode eq "external-editor" && !$sentEditorInput && \
                    [string first "EDITOR_PROMPT> " $output] >= 0} {
                    set release [string last "\033\[?2004l" $output]
                    if {$release < 0 || [string first "\033\[?2004h" $output $release] >= 0} {
                        error "editor prompt was not visible before TUI re-entry"
                    }
                    send -- "edited\r"
                    set sentEditorInput 1
                }
                if {!$sentBurstInput && ([string first BURST_READY $output] >= 0 || \
                    ($mode eq "recovery-stop" && [string first RECOVERY_EXACT $output] >= 0) || \
                    ($mode in {ctrl-c ctrl-c-isig signal-int} && [string first TURN_INTERRUPTED $output] >= 0))} {
                    send -- r
                    set sentBurstInput 1
                }
                if {!$sentExit && [regexp {(^|\n)PROTOCOL_OK\r*\n} $output] && \
                    ($mode ni {burst recovery-stop} || ([string first BURST_INPUT_OK $output] >= 0 && \
                        [string first BURST_PROTOCOL_OK $output] >= 0)) && \
                    ($mode ne "backend-eof" || [string first TUI_DISCONNECTED $output] >= 0) && \
                    ($mode ni {ctrl-c ctrl-c-isig signal-int} || !$sentInterrupt || \
                        [string first BURST_PROTOCOL_OK $output] >= 0)} {
                    if {[string first CHAR_FORWARDED $output] < 0} { error "protocol response preceded input" }
                    if {$mode eq "recovery-no-credit" && \
                        ([string first RECOVERY_WARNING $output] < 0 || [string first NATIVE_FAILURE $output] < 0)} {
                        error "unavailable recovery hid native failure or lost its warning"
                    }
                    if {$mode eq "recovery-stop" && \
                        ([regexp -all {NATIVE_FAILURE} $output] != 3 || \
                         [regexp -all {RECOVERY_EXACT} $output] != 3 || \
                         [regexp -all {RECOVERY_SUCCESS} $output] != 1 || \
                         [string first RECOVERY_WARNING $output] >= 0)} {
                        error "repeated recovery hid native failures, changed input, or failed to end successfully"
                    }
                    if {$mode in {ctrl-c ctrl-c-isig signal-int}} {
                        foreach child [list $wrapper $backend $tui] { exec kill -0 $child }
                        if {$mode eq "ctrl-c-isig"} { exec stty isig < $terminalPath }
                        if {$mode eq "signal-int"} {
                            exec kill -INT $wrapper
                        } else { send -- "\003" }
                        if {!$sentInterrupt} {
                            set sentInterrupt 1
                            exp_continue -continue_timer
                        }
                    } elseif {$mode eq "child-death"} {
                        exec kill -KILL $tui
                    } elseif {[string match signal-* $mode]} {
                        exec kill -[string toupper [string range $mode 7 end]] $wrapper
                    } else { send -- x }
                    set sentExit 1
                }
                exp_continue -continue_timer
            }
            eof {}
            timeout {
                if {$mode eq "external-editor" && !$sentEditorInput} {
                    error "temporary terminal release hid the editor prompt"
                }
                error "diagnostic capture blocked keyboard, protocol, or shutdown"
            }
        }
        set result [wait -i $wrapperSpawn]
        close -i $wrapperSpawn
        set expected 7
        switch $mode {
            normal { set expected 0 }
            backend-eof { set expected 7 }
            child-death { set expected 137 }
            launchfail - launchfail-closed - missing { set expected 1 }
            signal-term { set expected 143 }
            signal-hup { set expected 129 }
        }
        if {[lindex $result 2] != 0 || [lindex $result 3] != $expected} {
            error "diagnostic reporting changed exit status: $result; output: $output"
        }
        if {$active && (!$sentExit || (!$::actualLaunch && [string first NATIVE_WAIT_COMPLETE $output] < 0))} {
            error "native input, wait, or terminal restoration was lost: $output"
        }
        if {$mode in {ctrl-c ctrl-c-isig signal-int} && \
            (!$sentInterrupt || [regexp -all {TURN_INTERRUPTED} $output] != 1 || \
             [string first BURST_INPUT_OK $output] < 0 || [string first BURST_PROTOCOL_OK $output] < 0)} {
            error "first interrupt closed the TUI or broke input/protocol forwarding: $output"
        }
        if {$mode ne "missing"} {
            set enabled [string first "\033\[?1006h" $output]
            set restored [string first "\033\[?1006l" $output]
            if {$enabled < 0 || $restored < $enabled} { error "mouse reporting survived TUI exit" }
            foreach text {{To resume this session, run:} {To choose a saved session, run:} {background app-server diagnostics} {codex-retry: fixture TUI launch failure}} {
                set index [string first $text $output]
                if {$index >= 0 && $index < $restored} { error "exit text preceded mouse restoration" }
            }
        }
        if {$active && [string first "client disconnected; shared server and background work may continue" $output] < 0 && $mode ne "closed"} {
            error "shared-server lifetime advice was missing"
        }
        if {$mode eq "external-editor" && (!$sentEditorInput || [string first EDITOR_INPUT_OK $output] < 0)} {
            error "external editor did not receive input before TUI re-entry"
        }
        if {$active && ![string match signal-* $mode] && $mode ne "child-death"} {
            set boundary [string last "\033\[?2004l" $output]
            if {$boundary < 0} { error "native exit boundary was lost" }
            set live [string range $output 0 $boundary-1]
            set footer [string range $output $boundary end]
            foreach text {LIVE_BEGIN {Disconnected from this task.} {To reconnect, run:} LIVE_LOOKALIKE LIVE_END} {
                if {[string first $text $live] < 0} { error "live lookalike was filtered" }
            }
            foreach obsolete {{Disconnected from this task.} {To reconnect, run:} {To stop this task} --remote CODEX_RETRY_TOKEN native-untrusted} {
                if {[string first $obsolete $footer] >= 0} { error "unusable native advice survived exit" }
            }
            foreach text {UNRELATED_EXIT_TEXT {codex agents documentation stays} {agents server diagnostic} {Token usage so far: total=17 input=11 output=6}} {
                if {[string first $text $footer] < 0} { error "unrelated epilogue output was lost" }
            }
            if {[string first "\033\[?25h" $footer] < 0} { error "native terminal restoration bytes were lost" }
            foreach control [list "\033\]0;\007" "\033\]7501;state=clear\033\\"] {
                if {[string first $control $footer] < 0} { error "native OSC bytes were lost" }
            }
            if {[regexp -all {To (?:resume this|choose a saved) session, run:} $footer] != 1} {
                error "wrapper recovery was missing or duplicated in the epilogue"
            }
        }
        if {$active} {
            if {[regexp -all {To (?:resume this|choose a saved) session, run:} $output] != 1} {
                error "wrapper recovery was missing or duplicated"
            }
            set selected confirmed-session
            if {$mode eq "switched"} { set selected switched-session }
            if {![regexp {To (?:resume this|choose a saved) session, run:\r*\n[ \t]*([^\r\n]+)} $output -> command]} {
                error "recovery command was not copyable"
            }
            set actual [split [exec sh -c "set -- $command; printf '%s\\n' \"\$@\""] \n]
            set expected [list $::expectedLauncher resume]
            if {$mode ni {no-thread activation-error}} { lappend expected $selected }
            if {$mode ni {no-thread activation-error switched}} { lappend expected --yolo }
            if {$actual ne $expected} { error "recovery command changed arguments" }
            set resolved [exec sh -c {command -v "$1"} sh [lindex $actual 0]]
            file stat $resolved actualIdentity
            file stat $::launcherPath expectedIdentity
            if {$actualIdentity(dev) != $expectedIdentity(dev) || $actualIdentity(ino) != $expectedIdentity(ino)} {
                error "recovery command resolved to another launcher"
            }
        }
        if {$mode ni {closed launchfail-closed missing}} {
            if {[regexp -all {background app-server diagnostics} $output] != 1} {
                error "missing or duplicate diagnostic guidance: $output"
            }
            if {$mode eq "burst"} {
                if {[string first BACKEND_TAIL $output] < 0 || \
                    [string first BACKEND_DROPPED $output] >= 0 || \
                    [string first "output truncated" $output] < 0} { error "diagnostic tail or truncation was lost" }
                set start [string first "\n" $output [string first "output truncated" $output]]
                set end [string first "codex-retry: client disconnected" $output]
                set retained [string range $output $start+1 $end-1]
                # Strip terminal-added CRs: 64 KiB of data plus puts' final LF.
                set retained [string map [list "\r" ""] $retained]
                if {[string length $retained] != 65537} {
                    error "diagnostic retention bound changed"
                }
            } else {
                if {[string first BACKEND_START $output] < 0 || \
                    [string first "output truncated" $output] >= 0} { error "short startup diagnostics changed" }
                if {$active && [string first BACKEND_PARTIAL $output] < 0} { error "partial diagnostic was lost" }
                if {$mode eq "shutdown" && [string first BACKEND_SHUTDOWN $output] < 0} {
                    error "shutdown diagnostic was lost"
                }
            }
        }
        if {$mode eq "launchfail" && [string first "fixture TUI launch failure" $output] < 0} {
            error "TUI launch failure was masked"
        }
        if {$mode eq "missing" && [string first "codex-retry:" $output] < 0} { error "backend launch failure was masked" }
        if {$mode in {closed launchfail-closed} && [string first BACKEND_ $output] >= 0} {
            error "closed stderr was bypassed"
        }
        foreach identity [list $env(DIAGNOSTIC_PID) $env(DIAGNOSTIC_TUI_PID)] {
            if {![file exists $identity]} { continue }
            set channel [open $identity r]
            set child [string trim [read $channel]]
            close $channel
            if {![string is integer -strict $child] || $child <= 0} { error "invalid diagnostic fixture PID" }
            if {![catch {exec kill -0 $child}]} { error "diagnostic fixture child survived cleanup" }
        }
    } message]
    if {$failed} {
        catch {exec kill -TERM $wrapper}
        catch {expect -timeout 2 eof}
        catch {exec kill -KILL $wrapper}
        foreach identity [list $env(DIAGNOSTIC_PID) $env(DIAGNOSTIC_TUI_PID)] {
            catch {
                set channel [open $identity r]
                set child [string trim [read $channel]]
                close $channel
                if {[string is integer -strict $child] && $child > 0} { exec kill -KILL $child }
            }
        }
        catch {wait -i $wrapperSpawn}
        catch {close -i $wrapperSpawn}
        set detail [string map [list "\r" {\r} "\n" {\n}] [string range $message 0 1023]]
        puts stderr "diagnostic fixture $mode: $detail"
        exit 1
    }
    exit 0
}
set env(PATH) "$scratch:$savedPath"
# Own launcher discovery instead of inheriting a developer's installation.
file link -symbolic [file join $scratch codex-retry] $wrapper
set env(DIAGNOSTIC_EMPTY_PATH) [file join $scratch empty]
file mkdir $env(DIAGNOSTIC_EMPTY_PATH)
set quotedWrapper [file join $scratch {launcher 'with spaces} codex-retry]
file mkdir [file dirname $quotedWrapper]
file copy $wrapper $quotedWrapper
# Every driver owns a distinct PTY and PID files. Run eight independent cases at
# a time so repeated forced-shutdown coverage fits the frozen suite deadline.
proc diagnostic_batch {channels} {
    set failures {}
    foreach channel $channels {
        set failed [catch {read $channel} output]
        if {[catch {close $channel} message] || $failed} { lappend failures "$message: $output" }
    }
    if {[llength $failures]} { error [join $failures \n] }
}
set jobs {}
set failed [catch {
    foreach mode {normal error burst shutdown closed backend-eof signal-term signal-hup signal-int ctrl-c ctrl-c-isig child-death launchfail launchfail-closed missing no-thread activation-error switched installed quoted external-editor recovery-no-credit recovery-stop} {
        set env(DIAGNOSTIC_MODE) $mode
        set env(DIAGNOSTIC_PID) [file join $scratch $mode.backend.pid]
        set env(DIAGNOSTIC_TUI_PID) [file join $scratch $mode.tui.pid]
        set launchedWrapper $wrapper
        set expectedLauncher codex-retry
        if {$mode eq "quoted"} { set launchedWrapper $quotedWrapper; set expectedLauncher $quotedWrapper }
        set configuredFixture "$diagnosticFixture\n[list set argv0 $launchedWrapper]\n[list source $launchedWrapper]\n"
        set actualLaunch [expr {$mode in {installed quoted}}]
        set launch [list expect -c $configuredFixture]
        if {$actualLaunch} { set launch [list $expectedLauncher --yolo] }
        set configuredDriver "set timeout 6\n[list set expectedLauncher $expectedLauncher]\n[list set launcherPath $launchedWrapper]\n[list set actualLaunch $actualLaunch]\n[list cd $scratch]\n[list spawn -noecho {*}$launch]\n$diagnosticDriver"
        lappend jobs [open [list | expect -c $configuredDriver 2>@1] r]
        if {[llength $jobs] == 8} {
            set batch $jobs
            set jobs {}
            diagnostic_batch $batch
        }
    }
    set batch $jobs
    set jobs {}
    diagnostic_batch $batch
} message]
if {[llength $jobs]} { catch {diagnostic_batch $jobs} }
set env(PATH) $savedPath
unset -nocomplain env(DIAGNOSTIC_MODE) env(DIAGNOSTIC_PID) env(DIAGNOSTIC_TUI_PID) env(DIAGNOSTIC_EMPTY_PATH)
file delete -force $scratch
check {!$failed} "fake backend diagnostic isolation failed: $message"

} on error {message options} {
    # Preserve failure details and cleanup while exposing the failing group to
    # launchers that can retain only the process exit status.
    puts stderr [dict get $options -errorinfo]
    set unitFailure $unitPhase
} finally {
    if {$transportJob ne ""} {
        # Drain and reap even after a parent assertion fails, before removing
        # the child's scratch root. Blocking close preserves its exit status.
        set failed [catch {
            fileevent $transportJob readable ""
            fconfigure $transportJob -blocking 1
            puts -nonewline [read $transportJob]
        } message]
        if {$failed} {
            puts stderr "transport output: $message"
            if {!$unitFailure} { set unitFailure 19 }
        }
        if {[catch {close $transportJob} message options]} {
            puts stderr "transport regressions: $message"
            if {!$unitFailure} {
                set unitFailure 19
                set code [dict get $options -errorcode]
                if {[lindex $code 0] eq "CHILDSTATUS" && [lindex $code 2] >= 48 && [lindex $code 2] <= 62} {
                    set unitFailure [lindex $code 2]
                }
            }
        }
    }
    unset -nocomplain env(XDG_CONFIG_HOME) env(TMPDIR)
    array set env $configEnvironment
    file delete -force $configScratch
}
if {$unitFailure} { exit $unitFailure }
puts "PASS: structured retries, opt-in recovery, input/settings, backoff, cancellation, progress, IDs, arguments, resume permissions, proxy/PTY forwarding, authentication, and cleanup"
