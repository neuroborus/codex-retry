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

# Recovery requires the newest typed activation reply, independently of retries.
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
check {!$resume::armed && $resume::pending eq ""} "disconnect retained launch YOLO"

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

# A send can remove both channels before buffered backend reads finish.
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
rename bgerror native_bgerror
proc bgerror {message} { lappend ::proxyFailures $message; cleanup }
foreach outcome {confirmed rejected mismatch disconnected-rejection null-method} {
    arm_resume
    recovery::client [resume::client $resumeRequest]
    set sendMode record
    switch $outcome {
        confirmed { set response $resumeReply }
        rejected { set response $rejection }
        mismatch { set response [string map {dangerFullAccess readOnly} $resumeReply] }
        disconnected-rejection { set response $rejection; set sendMode disconnect }
        null-method { set response [string map {{,"result":} {,"method":null,"result":}} $resumeReply] }
    }
    set backend [file tempfile scratch]
    puts $backend $response
    seek $backend 0
    set client fixture
    set forwarded {}
    set proxyFailures {}
    backend_read
    cleanup
    file delete $scratch
    set expectedForwarded {}
    if {$outcome ni {mismatch null-method}} { set expectedForwarded [list $response] }
    check {$forwarded eq $expectedForwarded} "resume routing altered an authoritative response or exposed unconfirmed success"
    check {[llength $proxyFailures] == ($outcome ne "confirmed")} "resume verification failure did not halt visibly"
    check {$recovery::target eq ($outcome eq "confirmed" ? "t1" : "")} "resume recovery bypassed permission verification or cleanup lost confirmation"
}
rename bgerror {}
rename native_bgerror bgerror
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

# Cleanup also owns both stderr pipe ends when launching the backend fails.
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

# Exercise launch flag consumption and permission verification over the real proxy.
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set channel [open [file join $scratch codex] w]
puts $channel {#!/usr/bin/env tclsh}
puts $channel {
    package require json
    package require websocket
    fconfigure stdin -encoding utf-8 -translation lf
    fconfigure stdout -encoding utf-8 -translation lf
    set mode $env(YOLO_FIXTURE_MODE)
    set effective $env(YOLO_FIXTURE_ENABLED)
    set confirmation {{"id":31,"result":{"thread":{"id":"t1","turns":[]},"approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"},"activePermissionProfile":{"id":"server-profile","extends":"fixture-parent"}}}}
    if {!$effective} { set confirmation [string map {never on-request dangerFullAccess readOnly} $confirmation] }
    set turn {{"id":7,"method":"turn/start","params":{"threadId":"t1","input":[{"type":"text","text":"quoted \"input\" é"}],"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}}}
    if {!$effective} { set turn [string map {never on-request dangerFullAccess readOnly} $turn] }
    if {[lindex $argv 0] eq "app-server"} {
        if {$argv ne {app-server --listen stdio:// -c {fixture="with spaces"} --enable fixture}} { exit 2 }
        set log [open $env(YOLO_FIXTURE_LOG) w]
        set identity [open $env(YOLO_FIXTURE_PID) w]
        puts $identity [pid]
        close $identity
        while {[gets stdin line] >= 0} {
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
                            rejection { puts {{"id":31,"error":{"code":-32000,"message":"fixture rejection","data":{"detail":"unchanged"}}}} }
                            mismatch { puts [string map {dangerFullAccess readOnly} $confirmation] }
                            malformed { puts {{"id":31,"result":{}}} }
                            premature { continue }
                            default { puts $confirmation }
                        }
                    } else {
                        if {[dict get $message params approvalPolicy] ne "on-request" || \
                            [dict get $message params sandbox] ne "read-only"} { exit 4 }
                        puts {{"id":35,"result":{"thread":{"id":"other"},"approvalPolicy":"on-request","sandbox":{"type":"readOnly"}}}}
                    }
                }
                turn/start {
                    if {$line ne $turn} { exit 5 }
                    puts {{"id":7,"result":{"turn":{"id":"fixture-turn","items":[]}}}}
                }
                thread/settings/update {
                    if {[dict get $message params approvalPolicy] ne "on-request"} { exit 6 }
                    puts {{"id":34,"result":{}}}
                }
                default { exit 8 }
            }
            flush stdout
        }
        exit
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
    puts YOLO_PROXY_OK
    flush stdout
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
        set deadline [expr {[clock milliseconds] + 2000}]
        while {![file exists $env(YOLO_FIXTURE_PID)] || [file size $env(YOLO_FIXTURE_PID)] == 0} {
            if {[clock milliseconds] >= $deadline} { error "resume backend startup timed out" }
            after 10
        }
        set identity [open $env(YOLO_FIXTURE_PID) r]
        set backend [string trim [read $identity]]
        close $identity
        if {![string is integer -strict $backend] || $backend <= 0} { error "invalid resume backend PID" }
        if {$::failureText eq ""} {
            expect {
                -exact YOLO_PROXY_OK {}
                eof { error "resume permission exchange failed" }
                timeout { error "resume permission exchange timed out" }
            }
            send -- "forwarded\r"
            expect {
                -exact YOLO_INPUT_OK {}
                eof { error "resume terminal forwarding failed" }
                timeout { error "resume terminal forwarding timed out" }
            }
            set expectedStatus 7
        } else {
            expect {
                -exact $::failureText {}
                eof { error "guarded resume failed without visible guidance" }
                timeout { error "guarded resume failure timed out" }
            }
            set expectedStatus 1
        }
        expect {
            eof {}
            timeout { error "resume wrapper exit timed out" }
        }
        set result [wait -i $wrapperSpawn]
        if {[lindex $result 2] != 0 || [lindex $result 3] != $expectedStatus} {
            error "resume exit status changed: $result"
        }
        if {![catch {exec kill -0 $backend}]} { error "resume backend survived cleanup" }
    } message]
    if {$failed} {
        catch {exec kill -TERM $wrapper}
        if {[info exists backend]} { catch {exec kill -TERM $backend} }
        catch {expect -timeout 2 eof}
        catch {exec kill -KILL $wrapper}
        puts stderr $message
        exit 1
    }
    exit 0
}
set env(PATH) "$scratch:$savedPath"
set failed [catch {
    foreach mode {session last alias ordinary rejection mismatch malformed premature} {
        set env(YOLO_FIXTURE_MODE) $mode
        set env(YOLO_FIXTURE_ENABLED) [expr {$mode ne "ordinary"}]
        set env(YOLO_FIXTURE_LOG) [file join $scratch $mode.jsonl]
        set env(YOLO_FIXTURE_PID) [file join $scratch $mode.pid]
        set launch {resume fixture-session --yolo}
        set remaining {resume fixture-session}
        switch $mode {
            last { set launch {--yolo resume --last}; set remaining {resume --last} }
            alias { set launch {resume fixture-session --dangerously-bypass-approvals-and-sandbox} }
            ordinary { set launch $remaining }
        }
        set shared [list -c {fixture="with spaces"} --enable fixture]
        set env(YOLO_FIXTURE_ARGUMENTS) [concat $remaining $shared]
        set failureText ""
        switch $mode {
            rejection { set failureText "fixture rejection" }
            mismatch - malformed { set failureText "did not confirm resume --yolo permissions" }
            premature { set failureText "work requested before resume --yolo permissions were confirmed" }
        }
        set configuredDriver "set timeout 8\n[list set failureText $failureText]\n"
        append configuredDriver "[list spawn -noecho $wrapper {*}$launch {*}$shared]\n$resumeDriver"
        exec expect -c $configuredDriver 2>@1
        set channel [open $env(YOLO_FIXTURE_LOG) r]
        set messages [split [string trim [read $channel]] \n]
        close $channel
        set turns 0
        foreach json $messages {
            if {$json eq ""} { continue }
            set message [json::json2dict $json]
            if {[field $message method] eq "turn/start"} { incr turns }
        }
        check {$turns == ($failureText eq "")} "a guarded launch leaked work or an ordinary launch lost its turn"
    }
} message]
set env(PATH) $savedPath
unset -nocomplain env(YOLO_FIXTURE_MODE) env(YOLO_FIXTURE_ENABLED) env(YOLO_FIXTURE_LOG) env(YOLO_FIXTURE_PID) env(YOLO_FIXTURE_ARGUMENTS)
file delete -force $scratch
check {!$failed} "fake resume launch/proxy check failed: $message"

# Backend diagnostics must never cross the live TUI, including unterminated
# messages and bursts larger than both a pipe and the retained diagnostic tail.
set channel [file tempfile scratch]
close $channel
file delete $scratch
file mkdir $scratch
set channel [open [file join $scratch codex] w]
puts $channel {#!/usr/bin/env expect}
puts $channel {
    package require json
    package require websocket
    set mode $env(DIAGNOSTIC_MODE)
    fconfigure stdout -buffering line -encoding utf-8 -translation lf
    fconfigure stderr -encoding utf-8 -translation lf
    if {[lindex $argv 0] eq "app-server"} {
        puts stderr BACKEND_START
        flush stderr
        trap SIG_IGN SIGTERM
        if {$mode eq "shutdown"} {
            trap {puts -nonewline stderr BACKEND_SHUTDOWN; flush stderr; exit 23} SIGTERM
        }
        set identity [open $env(DIAGNOSTIC_PID) w]
        puts $identity [pid]
        close $identity
        fconfigure stdin -blocking 0 -encoding utf-8 -translation lf
        proc request {} {
            if {[gets stdin line] < 0} { return }
            set id [dict get [json::json2dict $line] id]
            if {$id == 6} {
                puts {{"id":6,"error":{"code":-1,"message":"fixture activation rejection"}}}
                flush stdout
                return
            }
            if {$id in {4 5}} {
                set selected [expr {$id == 4 ? "confirmed-session" : "switched-session"}]
                set approval [expr {$id == 4 ? "never" : "on-request"}]
                set sandbox [expr {$id == 4 ? "dangerFullAccess" : "readOnly"}]
                puts [format {{"id":%d,"result":{"thread":{"id":"%s"},"approvalPolicy":"%s","sandbox":{"type":"%s"}}}} $id $selected $approval $sandbox]
                flush stdout
                return
            }
            if {$id == 2} {
                if {$::mode eq "burst"} {
                    puts {{"method":"fixture/burst","params":{}}}
                    flush stdout
                    puts -nonewline stderr "BACKEND_DROPPED\n[string repeat x 2097152]\nBACKEND_TAIL"
                } else { puts -nonewline stderr BACKEND_PARTIAL }
                flush stderr
            }
            puts [format {{"id":%d,"result":{}}} $id]
            flush stdout
            if {$id == 2 && $::mode eq "backend-eof"} { exit 0 }
        }
        fileevent stdin readable request
        vwait forever
    }
    set identity [open $env(DIAGNOSTIC_TUI_PID) w]
    puts $identity [pid]
    close $identity
    if {[string match signal-* $mode]} { trap SIG_IGN SIGTERM }
    set terminalMode [exec stty -g <@stdin]
    exec stty raw -echo <@stdin
    puts "\033\[?2004hLIVE_BEGIN\nDisconnected from this task. Any running work continues.\nTo reconnect, run:\nLIVE_LOOKALIKE\nLIVE_END"
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
                puts BURST_READY
            } else {
                set id [dict get $response id]
                if {$id in {4 5 6}} { return }
                puts [dict get {1 INPUT_READY 2 PROTOCOL_OK 3 BURST_PROTOCOL_OK} $id]
            }
            flush stdout
        } elseif {$type in {close disconnect}} {
            puts TUI_DISCONNECTED
            flush stdout
        }
    }
    proc input {} {
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
        set character [read stdin 1]
        if {$character eq "q"} {
            puts CHAR_FORWARDED
            flush stdout
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
    fileevent stdin readable input
    vwait forever
}
close $channel
file attributes [file join $scratch codex] -permissions 0755
set diagnosticFixture {
    # Expect -c runs before normal script argument initialization.
    set argv {--yolo}
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
            error "fixture TUI launch failure"
        }
    }
    if {$env(DIAGNOSTIC_MODE) eq "missing"} { set env(PATH) $env(DIAGNOSTIC_EMPTY_PATH) }
}
set diagnosticDriver {
    set wrapperSpawn $spawn_id
    set wrapper [exp_pid]
    log_user 0
    match_max 131072
    set output ""
    set sentInput 0
    set sentEditorInput 0
    set sentBurstInput 0
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
                if {!$sentBurstInput && [string first BURST_READY $output] >= 0} {
                    send -- r
                    set sentBurstInput 1
                }
                if {!$sentExit && [string first PROTOCOL_OK $output] >= 0 && \
                    ($mode ne "burst" || ([string first BURST_INPUT_OK $output] >= 0 && \
                        [string first BURST_PROTOCOL_OK $output] >= 0)) && \
                    ($mode ne "backend-eof" || [string first TUI_DISCONNECTED $output] >= 0)} {
                    if {[string first CHAR_FORWARDED $output] < 0} { error "protocol response preceded input" }
                    if {[string match signal-* $mode]} {
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
        set expected 7
        switch $mode {
            normal { set expected 0 }
            launchfail - launchfail-closed - missing { set expected 1 }
            signal-term { set expected 143 }
            signal-hup { set expected 129 }
            signal-int { set expected 130 }
        }
        if {[lindex $result 2] != 0 || [lindex $result 3] != $expected} {
            error "diagnostic reporting changed exit status: $result; output: $output"
        }
        if {$active && (!$sentExit || (!$::actualLaunch && [string first NATIVE_WAIT_COMPLETE $output] < 0))} {
            error "native input, wait, or terminal restoration was lost: $output"
        }
        if {$mode eq "external-editor" && (!$sentEditorInput || [string first EDITOR_INPUT_OK $output] < 0)} {
            error "external editor did not receive input before TUI re-entry"
        }
        if {$active && ![string match signal-* $mode]} {
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
                set end [string first "codex-retry: private app-server stopped" $output]
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
set failed [catch {
    foreach mode {normal error burst shutdown closed backend-eof signal-term signal-hup signal-int launchfail launchfail-closed missing no-thread activation-error switched installed quoted external-editor} {
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
        exec expect -c $configuredDriver 2>@1
    }
} message]
set env(PATH) $savedPath
unset -nocomplain env(DIAGNOSTIC_MODE) env(DIAGNOSTIC_PID) env(DIAGNOSTIC_TUI_PID) env(DIAGNOSTIC_EMPTY_PATH)
file delete -force $scratch
check {!$failed} "fake backend diagnostic isolation failed: $message"

puts "PASS: structured retries, input/settings, backoff, cancellation, progress, IDs, arguments, resume permissions, proxy/PTY forwarding, authentication, and cleanup"
