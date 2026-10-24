#!/usr/bin/env tclsh

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
proc auto_begin {{reset 0} {follow 1} {acknowledge 1}} {
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
retry::server [format {{"id":"unrelated","result":{"turn":{"id":"%s","status":"inProgress","items":[]}},"id":%s}} $autoTurn $autoId]
completed $autoTurn failed cyberPolicy
check {[dict size $timers] == 0} "an ambiguous duplicate envelope acknowledged work"
auto_until read
auto_reply [string map [list {"availableCount":1} {"availableCount":0,"availableCount":1}] $exhausted]
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
            auto_activation {"modelProvider":"other-provider","modelProvider":"openai"} 1
        } else {
            auto_activation {"modelProvider":"openai"}
            retry::server {{"method":"thread/settings/updated","params":{"threadId":"t1","threadSettings":{"modelProvider":"other-provider","modelProvider":"openai"}}}}
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
    }
    return [json_dump [huddle create id [huddle string metadata-[incr ::metadataSequence]] \
        method [huddle string $method] params $params]]
}
foreach method {thread/queue/list thread/backgroundTerminals/list thread/items/read thread/timeline/list
    thread/read thread/readState/update thread/list thread/loaded/list thread/search thread/searchOccurrences thread/turns/list
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
    foreach params {
        {"turnId":"@TURN@"}
        {"threadId":null,"turnId":"@TURN@"}
        {"threadId":"","turnId":"@TURN@"}
        {"threadId":["t1"],"turnId":"@TURN@"}
        {"threadId":"t1"}
        {"threadId":"t1","turnId":null}
        {"threadId":"t1","turnId":""}
        {"threadId":"t1","turnId":1}
        {"threadId":"t1","turnId":["@TURN@"]}
        {"threadId":"other","threadId":"t1","turnId":"@TURN@"}
        {"threadId":"t1","turnId":"foreign","turnId":"@TURN@"}
    } {
        auto_begin 0 $follow
        retry::server [format {{"method":"thread/compacted","params":{%s}}} \
            [string map [list @TURN@ $autoTurn] $params]]
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

# Only actual resume flags are consumed; values and prompts remain native-owned.
foreach {arguments expected yolo} {
    {resume session --yolo} {resume session} 1
    {--yolo resume --last} {resume --last} 1
    {resume --last --dangerously-bypass-approvals-and-sandbox} {resume --last} 1
    {--dangerously-bypass-approvals-and-sandbox resume session --yolo} {resume session} 1
    {resume session {quoted prompt é} --yolo -c {model="with spaces"}}
        {resume session {quoted prompt é} -c {model="with spaces"}} 1
    {resume session --yolo -- --yolo resume} {resume session -- --yolo resume} 1
    {resume --last} {resume --last} 0
    {--yolo} {--yolo} 0
    {--yolo {new prompt}} {--yolo {new prompt}} 0
    {exec --yolo resume} {exec --yolo resume} 0
    {{prompt} resume --yolo} {{prompt} resume --yolo} 0
    {-- resume --yolo} {-- resume --yolo} 0
    {--yolo -- resume} {--yolo -- resume} 0
    {resume session -- --yolo} {resume session -- --yolo} 0
    {resume session {a prompt containing --yolo and resume}}
        {resume session {a prompt containing --yolo and resume}} 0
    {resume --last --config=--yolo -mresume -C--yolo}
        {resume --last --config=--yolo -mresume -C--yolo} 0
    {resume --last -c -- --yolo} {resume --last -c --} 1
} {
    lassign [resume_arguments $arguments] actual enabled
    check {$actual eq $expected && $enabled == $yolo} "resume flag ownership changed arguments: $arguments"
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
} {
    check {[catch {resume_arguments $arguments} message] && [string match *conflicts* $message]} "consumption hid a native permission conflict"
}
check {[resume_arguments {resume --last -s read-only --yolo}] eq {{resume --last -s read-only} 1}} "an unrelated sandbox flag gained a speculative conflict"
check {[resume_arguments {resume --last -c --approve-for-me --yolo}] eq {{resume --last -c --approve-for-me} 1}} "a value was mistaken for a conflicting flag"
check {[resume_arguments {--yolo -a never}] eq {{--yolo -a never} 0}} "new-session conflicts stopped being native-owned"
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
proc arm_resume {} {
    set ::transport::reattaching 0
    set ::transport::unavailable 0
    retry::reset
    set ::retry::finished {}
    resume::reset
    set ::resume::armed 1
    set ::recovery::target ""
    set ::recovery::pending {}
    set ::recovery::seen {}
    set ::recovery::deleted {}
    set ::recovery::yolo 1
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
check {[retry::server {{"id":31,"result":{"thread":{"id":"t1"},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"}},"id":99}}] == 1 && $resume::pending ne ""} "a duplicate header ID confirmed the wrong resume"
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
foreach stage {armed waiting rejected} {
    foreach method {turn/start review/start thread/shellCommand thread/queue/start thread/realtime/start
        command/exec process/spawn mcpServer/tool/call thread/goal/set thread/prediction/request} {
        arm_resume
        if {$stage ne "armed"} { connection fixture text $resumeRequest }
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
check {[llength $proxyFailures] == 30} "guarded work did not fail visibly"
foreach mutation {
    {"id":32,"method":"thread/start","params":{}}
    {"id":32,"method":"thread/fork","params":{"threadId":"other"}}
    {"id":32,"method":"thread/settings/update","params":{"threadId":"t1","approvalPolicy":"on-request"}}
} {
    arm_resume
    set action "\{$mutation\}"
    check {[resume::client $action] eq $action && !$resume::armed} "a manual change did not disarm launch YOLO"
    check {[resume::client $resumeRequest] eq $resumeRequest} "a later thread inherited a canceled launch override"
    arm_resume
    connection fixture text $resumeRequest
    set before [llength $sent]
    connection fixture text $action
    connection fixture text $request
    check {[llength $sent] == $before} "a change during verification leaked unconfirmed work"
}
arm_resume
connection fixture disconnect ""
check {!$resume::armed && [string match {*before resume --yolo permissions were confirmed} $resume::failure]} \
    "disconnect silently discarded unresolved launch YOLO verification"
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
        check {$proxyFailures eq [list "server rejected resume --yolo: fixture rejection"]} \
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
foreach socket {picker1 picker2} channel {bridge1 bridge2} {
    set auxiliary::clients($socket) $channel
    set auxiliary::backends($channel) $socket
    set ticket [incr transport::sequence]
    set auxiliary::tickets($socket) $ticket
    foreach message [list $resumeRequest $request \
        { {"id":7,"method":"thread/list","params":{"searchTerm":"synthetic"}} }] {
        auxiliary::event $ticket $socket text $message
    }
    foreach message [list $resumeReply \
        { {"id":7,"error":{"code":-1,"message":"metadata failure"}} } \
        { {"method":"thread/closed","params":{"threadId":"t1"}} }] {
        auxiliary::backend $ticket $channel text $message
    }
    check {[lindex [lindex $routed end] 0] eq $socket} "auxiliary backend reply used another client"
    if {$socket eq "picker1"} {
        auxiliary::backend $ticket $channel timeout ""
    } else {
        auxiliary::event $ticket $socket text "invalid JSON"
    }
    set before $routed
    auxiliary::backend $ticket $channel text $resumeReply
    auxiliary::event $ticket $socket text $request
    check {$routed eq $before} "retired auxiliary callback forwarded data"
}
check {[llength $routed] == 12 && $closedBridges eq {bridge1 bridge2}} "auxiliary routing or local failure cleanup changed"
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
transport::lost {shared app-server proxy disconnected}
check {[info exists listener] && $recovery::target eq "t1" && !$recovery::yolo} \
    "transport loss destroyed the endpoint or verified session advice"
check {![info exists client] && ![info exists backend] && [dict size $timers] == 0 && \
    $retry::current eq "" && $automatic::current eq "" && $retry::finished eq "" && \
    $retry::internal eq "" && $retry::usedIds eq "" && $automatic::ids eq "" && \
    $automatic::live eq "" && $automatic::selection eq "" && $recovery::seen eq "" && \
    $recovery::pending eq ""} "transport retirement retained connection ownership"

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
            global mode effective confirmation turn env
            if {$type eq "connect"} { set ::log [open $env(YOLO_FIXTURE_LOG) w] }
            if {$type in {close disconnect}} { catch {close $::log}; return }
            if {$type eq "text"} {
                set log $::log
                puts $log $line
                flush $log
                set message [json::json2dict $line]
                switch [dict get $message method] {
                    thread/resume {
                        if {[dict get $message params threadId] eq "t1"} {
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
            websocket::send $socket text {{"id":31,"method":"thread/resume","params":{"threadId":"t1","approvalPolicy":"on-request","sandbox":"read-only","config":{"sample":true},"permissions":null}}}
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
# Each case owns its shared fixture, port, PTY, and request log. Collect four
# drivers per batch so independent startup/cleanup costs can overlap.
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
    foreach mode {session cold last alias ordinary rejection mismatch malformed premature startup-rejection attachment-rejection upgrade-rejection signal-term signal-hup signal-int eof input-eof} {
        set env(YOLO_FIXTURE_MODE) $mode
        set env(YOLO_FIXTURE_ENABLED) [expr {$mode ne "ordinary"}]
        set env(YOLO_FIXTURE_LOG) [file join $scratch $mode.jsonl]
        set env(YOLO_FIXTURE_PID) [file join $scratch $mode.pid]
        set launch {resume t1 --yolo}
        set remaining {resume t1}
        switch $mode {
            last { set launch {--yolo resume --last}; set remaining {resume --last} }
            alias { set launch {resume t1 --dangerously-bypass-approvals-and-sandbox} }
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
            mismatch - malformed { set failureText "did not confirm resume --yolo permissions" }
            premature { set failureText "work requested before resume --yolo permissions were confirmed" }
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
        if {[llength $jobs] == 4} {
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
                if {$::mode eq "switched"} {
                    websocket::send $socket text {{"id":5,"method":"thread/resume","params":{"threadId":"switched-session","approvalPolicy":"on-request","sandbox":"read-only"}}}
                }
                if {$::mode eq "activation-error"} {
                    websocket::send $socket text {{"id":6,"method":"thread/resume","params":{"threadId":"not-confirmed"}}}
                }
            }
            websocket::send $socket text {{"id":1,"method":"fixture/ready","params":{}}}
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
# Every driver owns a distinct PTY and PID files. Run four independent cases at
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
        if {[llength $jobs] == 4} {
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
                if {[lindex $code 0] eq "CHILDSTATUS" && [lindex $code 2] >= 48 && [lindex $code 2] <= 61} {
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
