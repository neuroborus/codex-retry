#!/usr/bin/env tclsh

# Real App Server, private state, guarded metadata only, and no terminal.
set subject [file normalize [info script]]
set root [file dirname [file dirname $subject]]
set wrapper [file join $root codex-retry]
source $wrapper
package require websocket
foreach level [logger::levels] { ${::websocket::log}::logproc $level message {return} }

namespace eval nativecheck {
    variable channels {}
    variable owned {}
    variable scratch ""
    variable answer ""
    variable sequence 10
    variable expected ""
    variable upstream ""
    variable frontend ""
    variable methods {initialize initialized config/mcpServer/reload}
    variable reloadId ""
    variable phase 11
}
proc nativecheck::check {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}
proc nativecheck::identity {child} {
    owned::identity $child
}
proc nativecheck::live {record} {
    owned::live $record
}
proc nativecheck::own {channel} {
    variable channels; variable owned
    lappend channels $channel
    foreach child [pid $channel] { lappend owned [identity $child] }
    return $channel
}
proc nativecheck::stop {channel} {
    close_backend $channel 1
}
proc nativecheck::cleanup {} {
    variable channels; variable owned; variable scratch
    foreach channel [lreverse $channels] { stop $channel }
    set channels {}
    foreach name {proxy-owned mcp-owned} {
        if {[file exists [file join $scratch $name]]} {
            set input [open [file join $scratch $name] r]
            foreach line [split [string trim [read $input]] \n] { lappend owned $line }
            close $input
        }
    }
    owned::kill $owned
}
proc bgerror {message} {
    puts stderr "private MCP fixture failed in phase $::nativecheck::phase: $message"
    nativecheck::cleanup
    exit $::nativecheck::phase
}
proc nativecheck::record {children} {
    set output [open [file join $::nativecheck::scratch proxy-owned] a]
    foreach record [owned::tree [lmap child $children {identity $child}]] { puts $output $record }
    close $output
}
proc nativecheck::log {value} {
    set output [open [file join $::nativecheck::scratch requests] a]
    puts $output $value
    close $output
}

if {[lindex $argv 0] eq "--mcp"} {
    lassign [lrange $argv 1 end] private version
    foreach name {HOME CODEX_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME} {
        nativecheck::check {[info exists env($name)] && $env($name) eq $private} "fake MCP inherited a non-private home"
    }
    nativecheck::check {$env(RETAIN) eq "private-preserved"} "fake MCP lost its environment"
    set output [open [file join $private mcp-owned] a]; puts $output [owned::identity [pid]]; close $output
    fconfigure stdin -buffering line; fconfigure stdout -buffering line
    while {[gets stdin line] >= 0} {
        set object [automatic::decode $line]
        if {![huddle exists $object id]} { continue }
        switch -- [automatic::text $object method] {
            initialize {
                set result [huddle create protocolVersion [huddle get $object params protocolVersion] \
                    capabilities [huddle create tools [huddle create]] \
                    serverInfo [huddle create name neutral version $version]]
            }
            tools/list {
                set result [huddle create tools [huddle list [huddle create name $version \
                    inputSchema [huddle create type object properties [huddle create]]]]]
            }
            ping { set result [huddle create] }
            default { error "fake MCP blocked unexpected method" }
        }
        puts [json_dump [huddle create jsonrpc [huddle string 2.0] id [huddle get $object id] result $result]]
    }
    exit
}

if {[lindex $argv 0] eq "--proxy"} {
    # PATH redirects only the helper's owned proxy. All protocol replies below
    # come unchanged from the real private server, never from a fake backend.
    lassign [lrange $argv 1 end] ::nativecheck::scratch native socketPath ::nativecheck::force
    set ::nativecheck::writes 0
    set ::nativecheck::configIds {}
    set ::nativecheck::userVersion ""
    if {$::nativecheck::force} { set ::nativecheck::methods {initialize initialized} }
    nativecheck::check {![info exists env(CODEX_RETRY_TOKEN)]} "helper leaked its inherited TUI token"
    source [file join $root tests proxy-fixture.tcl]
    foreach level [logger::levels] { ${::websocket::log}::logproc $level message {return} }
    proc guarded_request {socket type data} {
        if {$type ne "text"} { return }
        if {[catch {
            set object [automatic::decode $data]
            set method [automatic::text $object method]
            if {[llength $::nativecheck::methods]} {
                nativecheck::check {$method ne "" && $method eq [lindex $::nativecheck::methods 0]} "private proxy blocked unexpected request"
                set ::nativecheck::methods [lrange $::nativecheck::methods 1 end]
            } else {
                nativecheck::check {$::nativecheck::force && $method in {
                    thread/loaded/list config/read config/batchWrite config/mcpServer/reload thread/read mcpServerStatus/list
                }} "private force proxy blocked unexpected request"
            }
            if {$method in {thread/read mcpServerStatus/list}} {
                set input [open [file join $::nativecheck::scratch captured-thread] r]
                set captured [string trim [read $input]]; close $input
                nativecheck::check {[automatic::text $object params threadId] eq $captured} "helper inspected another thread"
            }
            if {$method eq "mcpServerStatus/list"} {
                nativecheck::check {[automatic::text $object params serverName] eq "neutral" &&
                    [automatic::text $object params detail] eq "toolsAndAuthOnly"} "helper used standalone or full MCP discovery"
            }
            if {$method eq "thread/read"} {
                nativecheck::check {[automatic::is $object boolean params includeTurns] &&
                    ![huddle get_stripped $object params includeTurns]} "helper attempted history hydration"
            }
            if {$method eq "config/read"} {
                nativecheck::check {[automatic::is $object boolean params includeLayers] &&
                    [huddle get_stripped $object params includeLayers] &&
                    ([automatic::is $object null params cwd] ||
                     [automatic::text $object params cwd] eq $::nativecheck::scratch)} "helper read configuration outside the private scope"
                dict set ::nativecheck::configIds [json_dump [huddle get $object id]] 1
            }
            if {$method eq "config/batchWrite"} {
                incr ::nativecheck::writes
                nativecheck::check {$::nativecheck::writes == 1 && [automatic::is $object list params edits] &&
                    [huddle llength [huddle get $object params edits]] == 1 &&
                    [automatic::text $object params edits 0 keyPath] eq "mcp_servers.neutral.env.CODEX_RETRY_MCP_GENERATION" &&
                    [automatic::text $object params edits 0 mergeStrategy] eq "upsert" &&
                    [regexp {^[0-9a-f]{32}$} [automatic::text $object params edits 0 value]] &&
                    [automatic::text $object params filePath] eq [file join $::nativecheck::scratch config.toml] &&
                    $::nativecheck::userVersion ne "" &&
                    [automatic::text $object params expectedVersion] eq $::nativecheck::userVersion &&
                    [automatic::is $object boolean params reloadUserConfig] && ![huddle get_stripped $object params reloadUserConfig]} \
                    "helper attempted an unsafe or repeated native write"
            }
            set ::nativecheck::frontend $socket
            if {$method eq "initialize"} {
                # Dispatch upstream traffic only after a frontend is available;
                # early native notifications must not abort the HTTP attachment.
                websocket::takeover $::nativecheck::upstream guarded_reply 0
                set input [open /proc/[pid]/status r]
                regexp -line {^PPid:\s+(\d+)} [read $input] -> owner
                close $input
                set input [open /proc/$owner/task/$owner/children r]
                nativecheck::record [read $input]
                close $input
            }
            if {$method eq "config/mcpServer/reload"} {
                nativecheck::check {[automatic::is $object null params]} "reload params were not null"
                nativecheck::check {!$::nativecheck::force || $::nativecheck::writes == 1} "force reloaded before its generation write"
                set ::nativecheck::reloadId [json_dump [huddle get $object id]]
            }
            nativecheck::log $method
            nativecheck::check {[websocket::send $::nativecheck::upstream text $data] >= 0} "private proxy send failed"
        }]} { exit 1 }
    }
    proc guarded_reply {channel type data} {
        if {$type in {connect ping pong}} { return }
        if {$type ne "text"} { exit 1 }
        if {[catch {
            set object [automatic::decode $data]
            if {[huddle exists $object id] && [dict exists $::nativecheck::configIds [json_dump [huddle get $object id]]]} {
                nativecheck::check {[automatic::is $object list result layers]} "native configuration layers were unavailable"
                set layers [huddle get $object result layers]
                for {set i 0} {$i < [huddle llength $layers]} {incr i} {
                    if {[automatic::text $layers $i name type] eq "user" &&
                        [automatic::text $layers $i name file] eq [file join $::nativecheck::scratch config.toml]} {
                        set ::nativecheck::userVersion [automatic::text $layers $i version]
                    }
                }
                dict unset ::nativecheck::configIds [json_dump [huddle get $object id]]
            }
            if {[huddle exists $object id] && $::nativecheck::reloadId ne "" && \
                [json_dump [huddle get $object id]] eq $::nativecheck::reloadId} {
                nativecheck::check {![huddle exists $object error] && [automatic::is $object dict result] && \
                    ![llength [huddle keys [huddle get $object result]]]} "native reload was not acknowledged"
                nativecheck::log ACK
            }
            nativecheck::check {$::nativecheck::frontend ne "" && \
                [websocket::send $::nativecheck::frontend text $data] >= 0} "private proxy reply failed"
        }]} { exit 1 }
    }
    set ::nativecheck::upstream [terminal::pipe [list | $native app-server proxy --sock $socketPath 2>/dev/null] r+]
    nativecheck::record [pid $::nativecheck::upstream]
    # Fixture signal/exit hooks also reap the frontend relay. Close our upstream
    # promptly so the helper's bounded SIGTERM cleanup can finish gracefully.
    exit -onexit {nativecheck::stop $::nativecheck::upstream}
    set ready 0
    backend_upgrade $::nativecheck::upstream {apply {{channel ok} {set ::ready [expr {$ok ? 1 : -1}]}}} 3000
    vwait ready
    if {$ready != 1} { exit 1 }
    close [open [file join $::nativecheck::scratch upstream-ready] w]
    fixture::start guarded_request
    nativecheck::record [concat [list [pid]] [pid $::fixture::relay]]
    close [open [file join $::nativecheck::scratch frontend-ready] w]
    vwait forever
}

proc nativecheck::response {channel type data} {
    variable answer; variable expected
    if {$type in {connect ping pong}} { return }
    if {$type ne "text"} { set answer disconnected; return }
    if {[catch {automatic::decode $data} object]} { set answer invalid-json; return }
    if {[huddle exists $object id] && [json_dump [huddle get $object id]] eq $expected} { set answer $object }
}
proc nativecheck::rpc {channel method params stage} {
    variable sequence; variable answer; variable expected; variable phase
    # Fail before sending any unplanned request, including all inference APIs.
    check {$method in {initialize thread/start thread/read thread/loaded/list config/read mcpServerStatus/list}} "observer blocked unexpected request"
    # RPC stages: 30 initialize, 40 start, 50 baseline read, 70 loaded/list,
    # 80 final read. Offsets survive trusted-output redaction without payloads:
    # 0 send, 1 disconnect, 2 JSON, 3 timeout, 4 RPC, 5 result,
    # 6 unsupported method, 7 invalid params. Invalid-request diagnostics use
    # bases 100/120/140/160/180 for these stages, plus the category below.
    set phase $stage
    set answer ""
    set expected [incr sequence]
    check {[websocket::send $channel text [json_dump [huddle create id [huddle number $expected] \
        method [huddle string $method] params $params]]] >= 0} "observer send failed"
    set timer [after 3000 {set ::nativecheck::answer timeout}]
    if {$answer eq ""} { vwait ::nativecheck::answer }
    after cancel $timer
    foreach {failure offset} {disconnected 1 invalid-json 2 timeout 3} {
        if {$answer eq $failure} { set phase [expr {$stage + $offset}]; error "private metadata $failure" }
    }
    set phase [expr {$stage + 4}]
    if {[huddle exists $answer error]} {
        if {[automatic::is $answer number error code]} {
            switch -- [huddle get_stripped $answer error code] {
                -32601 { set phase [expr {$stage + 6}] }
                -32602 { set phase [expr {$stage + 7}] }
                -32600 {
                    set phase [expr {[dict exists {30 100 40 120 50 140 70 160 80 180} $stage] ?
                        [dict get {30 100 40 120 50 140 70 160 80 180} $stage] : $stage}]
                    set message [string tolower [automatic::text $answer error message]]
                    # Fixed categories retain a safe reason when Runner discards
                    # prose. Never emit the message, paths, settings or payload.
                    # Offsets: initialization, experimental API, capabilities,
                    # history, provider, model, auth, sandbox, permissions,
                    # exec server, config, filesystem, unsupported, missing,
                    # disabled feature, policy, transport, client/version, other.
                    set category 0
                    foreach words {
                        {initializ} {experimental} {capabilit} {paginat history}
                        {provider} {model} {auth credential login}
                        {sandbox namespace bubblewrap} {permission approv}
                        {exec-server exec_server {exec server} environment}
                        {config} {directory cwd path file} {unsupported {not supported}}
                        {{not found} missing} {disabled enable} {policy restrict}
                        {connection transport socket} {version client}
                    } {
                        set matched 0
                        foreach word $words {
                            if {[string first $word $message] >= 0} { set matched 1; break }
                        }
                        if {$matched} { break }
                        incr category
                    }
                    incr phase $category
                }
            }
        }
        error "private metadata RPC rejected"
    }
    set phase [expr {$stage + 5}]
    check {[automatic::is $answer dict result]} "private metadata result was invalid"
    set phase $stage
    return [huddle get $answer result]
}

proc nativecheck::inventory {observer thread version {initial 0}} {
    # Only initial thread startup may await initialization. A helper readiness
    # receipt is checked immediately against the actual same-thread catalog.
    for {set attempt 0} {$attempt < 20} {incr attempt} {
        set result [nativecheck::rpc $observer mcpServerStatus/list [huddle create threadId $thread serverName neutral detail toolsAndAuthOnly] 60]
        if {!$initial || [automatic::text $result data 0 runtimeStatus] ni {"" notStarted starting}} { break }
        after 20 {set ::nativeStartup 1}; vwait ::nativeStartup
    }
    check {[automatic::is $result list data] && [huddle llength [huddle get $result data]] == 1 &&
        [automatic::text $result data 0 name] eq "neutral" &&
        [automatic::text $result data 0 runtimeStatus] eq "connected" &&
        [automatic::text $result data 0 serverInfo version] eq $version &&
        [automatic::is $result dict data 0 tools] &&
        $version in [huddle keys [huddle get $result data 0 tools]] &&
        [mcp_reload::nullable $result data 0 toolsError]} "same-thread native MCP version/catalog was not ready"
}
proc nativecheck::program {path subject private version} {
    set output [open $path w]
    puts $output [list set argv [list --mcp $private $version]]
    puts $output [list source $subject]
    close $output
}
proc nativecheck::helper {wrapper forceMode} {
    variable scratch
    set ::env(FIXTURE_FORCE) $forceMode
    close [open [file join $scratch requests] w]
    set args [list $wrapper reload-mcp]
    if {$forceMode} { lappend args --force }
    set channel [own [terminal::pipe [list | {*}$args < /dev/null 2>@1] r]]
    fconfigure $channel -blocking 0
    set ::helperReceipt ""; set ::helperDone 0
    fileevent $channel readable [list apply {{channel} {
        append ::helperReceipt [read $channel]
        if {[eof $channel]} { fileevent $channel readable ""; set ::helperDone 1 }
    }} $channel]
    vwait ::helperDone
    fconfigure $channel -blocking 1
    set failed [catch {close $channel}]
    set ::nativecheck::channels [lsearch -all -inline -not -exact $::nativecheck::channels $channel]
    check {!$failed} "subsequent native helper failed"
    set expected "MCP configuration reread; refresh queued for loaded threads (server-wide).\n"
    if {$forceMode} { set expected "MCP generation published; refreshed STDIO connections and catalogs verified for captured loaded threads (server-wide refresh).\n" }
    check {$::helperReceipt eq $expected} "subsequent native helper returned an invalid receipt"
    set input [open [file join $scratch requests] r]; set requests [split [string trim [read $input]] \n]; close $input
    if {$forceMode} {
        check {[llength [lsearch -all -exact $requests config/batchWrite]] == 1 && "ACK" in $requests &&
            "mcpServerStatus/list" in $requests && "thread/read" in $requests} "native force proof was not exercised"
    } else {
        check {$requests eq {initialize initialized config/mcpServer/reload ACK}} "ordinary reload accessed configuration or generation state"
    }
}

set environment [array get env]
set originalDirectory [pwd]
set native [lindex [auto_execok codex] 0]
nativecheck::check {$native ne ""} "installed Codex is required"
set base [file join $root LOCAL_ARTIFACTS]
# Match the established native fixture's private TMPDIR selection. Runner's
# general scratch path can be too long for a Unix domain socket pathname.
foreach name {AGENT_RUNNER_SCRATCH TMPDIR} {
    if {[info exists env($name)]} { set base $env($name) }
}
file mkdir $base
set channel [file tempfile scratch [file join $base mcp]]
close $channel
file delete $scratch
file mkdir $scratch
file attributes $scratch -permissions 0700
set ::nativecheck::scratch $scratch
set nativeFailure 0
try {
    set private {}
    foreach name {PATH TCLLIBPATH LD_LIBRARY_PATH TMPDIR TMP TEMP} {
        if {[info exists env($name)]} { lappend private $name $env($name) }
    }
    # Keep Tcl's environment export trace; deleting the array detaches it.
    foreach name [array names env] { unset env($name) }
    array set env $private
    foreach name {HOME CODEX_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME} { set env($name) $scratch }
    set env(LANG) C.UTF-8
    set ::nativecheck::phase 29
    # Verify the child environment before any native process can read config.
    exec sh -c {
        [ "$HOME" = "$1" ] && [ "$CODEX_HOME" = "$1" ] &&
        [ "$XDG_CONFIG_HOME" = "$1" ] && [ "$XDG_CACHE_HOME" = "$1" ] && [ "$XDG_STATE_HOME" = "$1" ]
    } private-mcp-environment $scratch
    cd $scratch
    set output [open config.toml w]
    puts $output {model = "fixture-model"
model_provider = "offline"
[model_providers.offline]
name = "Private fixture"
base_url = "http://127.0.0.1:9"
wire_api = "responses"
requires_openai_auth = false}
    close $output
    set program [file join $scratch mcp-program.tcl]
    nativecheck::program $program $subject $scratch version_one
    set output [open config.toml a]
    puts $output "\n\[mcp_servers.neutral\]\ncommand = [json::write string [info nameofexecutable]]"
    puts $output "args = \[[json::write string $program]\]"
    puts $output {env = { RETAIN = "private-preserved" }
env_vars = ["HOME", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "TCLLIBPATH", "LD_LIBRARY_PATH", "TMPDIR"]
startup_timeout_sec = 5
required = false
default_tools_approval_mode = "prompt"
tool_input_schema_max_bytes = 1024
supports_parallel_tool_calls = true
[mcp_servers.neutral.tools.version_one]
approval_mode = "approve"
output_token_limit = 123
[mcp_servers.neutral.tools.version_two]
approval_mode = "approve"
output_token_limit = 456
[mcp_servers.disabled]
command = "unused-private-command"
enabled = false
[mcp_servers.http]
url = "http://127.0.0.1:9"
enabled = false}
    close $output
    set input [open config.toml r]; set originalConfig [read $input]; close $input
    set ::nativecheck::phase 16
    set versionOutput [exec $native --version 2>/dev/null]
    nativecheck::check {[regexp {^codex-cli ([0-9]+\.[0-9]+\.[0-9]+)(?:\s|$)} $versionOutput -> version]} \
        "private native version was not identifiable"
    puts stderr "private MCP fixture CLI $version"
    set ::nativecheck::phase 11
    set socketPath [file join $scratch c.sock]
    nativecheck::check {[string length [encoding convertto utf-8 $socketPath]] < 108} "private socket pathname is too long"
    # This installed CLI fails an explicit missing-socket attachment. No daemon
    # start/restart is requested, and no user-selected endpoint is reachable.
    set probe [nativecheck::own [terminal::pipe [list | $native app-server proxy --sock $socketPath \
        < /dev/null 2>/dev/null] r]]
    fconfigure $probe -blocking 0
    set probeDone 0
    fileevent $probe readable [list apply {{channel} {
        read $channel
        if {[eof $channel]} { fileevent $channel readable ""; set ::probeDone 1 }
    }} $probe]
    set timer [after 3000 {set ::probeDone -1}]
    vwait probeDone
    after cancel $timer
    nativecheck::check {$probeDone == 1} "missing private socket attachment timed out"
    fconfigure $probe -blocking 1
    set failed [catch {close $probe} message options]
    set ::nativecheck::channels [lsearch -all -inline -not -exact $::nativecheck::channels $probe]
    nativecheck::check {$failed && [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS" && \
        ![file exists $socketPath]} "missing private socket did not fail cleanly"
    set ::nativecheck::phase 12
    set server [nativecheck::own [terminal::pipe [list | $native app-server --listen unix://$socketPath \
        < /dev/null 2>/dev/null] r]]
    # Independent hard bound also releases a blocked native frame read.
    set script [owned::watchdog [expr {[clock milliseconds] + 40000}] [pid $server]]
    set guard [nativecheck::own [terminal::pipe [list | expect -c $script] r]]
    fconfigure $guard -blocking 0
    fileevent $guard readable {error "private native fixture deadline expired"}
    set startup [expr {[clock milliseconds] + 5000}]
    while {![file exists $socketPath]} {
        nativecheck::check {[clock milliseconds] < $startup} "private server startup timed out"
        after 20 {set ::tick 1}
        vwait ::tick
    }
    lappend ::nativecheck::owned {*}[owned::tree [lmap child [pid $server] {owned::identity $child}]]
    set ::nativecheck::phase 20
    set observer [nativecheck::own [terminal::pipe [list | $native app-server proxy --sock $socketPath 2>/dev/null] r+]]
    set ready 0
    backend_upgrade $observer {apply {{channel ok} {set ::ready [expr {$ok ? 1 : -1}]}}} 3000
    vwait ready
    nativecheck::check {$ready == 1} "private observer attachment failed"
    lappend ::nativecheck::owned {*}[owned::tree [lmap child [pid $observer] {owned::identity $child}]]
    websocket::takeover $observer nativecheck::response 0
    nativecheck::rpc $observer initialize [huddle create clientInfo [huddle create \
        name [huddle string mcp-native-observer] version [huddle string 1]] capabilities [huddle create]] 30
    set ::nativecheck::phase 21
    websocket::send $observer text {{"method":"initialized"}}
    set started [nativecheck::rpc $observer thread/start [huddle create model [huddle string fixture-model] \
        modelProvider [huddle string offline] cwd [huddle string $scratch] approvalPolicy [huddle string never] \
        sandbox [huddle string read-only]] 40]
    set ::nativecheck::phase 17
    set thread [huddle get $started thread id]
    nativecheck::check {[huddle type $thread] eq "string" && [huddle get_stripped $thread] ne ""} "neutral thread was not loaded"
    # Read stable metadata without requiring a persisted rollout or turn history.
    # The proxy allowlist prevents history mutations and all inference requests.
    set baseline [nativecheck::rpc $observer thread/read [huddle create threadId $thread includeTurns [huddle false]] 50]
    set ::nativecheck::phase 13
    nativecheck::check {[automatic::text $baseline thread id] eq [huddle get_stripped $thread]} "baseline thread identity changed"
    set ::nativecheck::phase 22
    nativecheck::check {[automatic::text $baseline thread modelProvider] eq "offline"} "private provider was not selected"
    set output [open captured-thread w]; puts $output [huddle get_stripped $thread]; close $output
    nativecheck::inventory $observer $thread version_one 1
    set input [open mcp-owned r]; set initialMcp [split [string trim [read $input]] \n]; close $input
    nativecheck::check {[llength $initialMcp] == 1 && [nativecheck::live [lindex $initialMcp 0]]} "initial fake MCP process was not owned and live"
    set previousMcp [lindex $initialMcp 0]
    set configBefore [nativecheck::rpc $observer config/read [huddle create includeLayers [huddle true] cwd [huddle null]] 61]
    nativecheck::check {![huddle exists $configBefore config mcp_servers neutral env CODEX_RETRY_MCP_GENERATION]} "private fixture started with a marker"
    nativecheck::check {[automatic::text $configBefore config mcp_servers neutral environment_id] eq "local" &&
        [automatic::is $configBefore boolean config mcp_servers neutral enabled] &&
        [huddle get_stripped $configBefore config mcp_servers neutral enabled] &&
        [automatic::is $configBefore null config mcp_servers neutral tool_timeout_sec] &&
        [automatic::text $configBefore config mcp_servers neutral tools version_one approval_mode] eq "approve" &&
        [huddle get_stripped $configBefore config mcp_servers neutral tools version_two output_token_limit] == 456} \
        "private native defaults or per-tool settings were not exercised"
    set layers [huddle get $configBefore layers]
    set raw ""
    for {set i 0} {$i < [huddle llength $layers]} {incr i} {
        if {[automatic::text $layers $i name type] eq "user"} { set raw [huddle get $layers $i config mcp_servers neutral] }
    }
    nativecheck::check {$raw ne "" && ![huddle exists $raw enabled] && ![huddle exists $raw environment_id] &&
        ![huddle exists $raw tool_timeout_sec] && [automatic::is $raw dict tools]} "private raw layer did not differ from native defaults"
    nativecheck::program $program $subject $scratch version_two

    set ::nativecheck::phase 23
    file mkdir [file join $scratch bin]
    set shim [open [file join $scratch bin codex] w]
    puts $shim {#!/bin/sh
if [ "$#" -ne 2 ] || [ "$1" != app-server ] || [ "$2" != proxy ]; then exit 91; fi}
    puts $shim "exec expect [shell_quote $subject] --proxy [shell_quote $scratch] [shell_quote $native] [shell_quote $socketPath] \"\${FIXTURE_FORCE:-0}\""
    close $shim
    file attributes [file join $scratch bin codex] -permissions 0755
    set env(PATH) "[file join $scratch bin]:$env(PATH)"
    set env(CODEX_RETRY_TOKEN) private-inherited-sentinel
    set ::nativecheck::phase 24
    set helper [nativecheck::own [terminal::pipe [list | $wrapper reload-mcp < /dev/null 2>@1] r]]
    fconfigure $helper -blocking 0
    set receipt ""
    set done 0
    fileevent $helper readable [list apply {{channel} {
        append ::receipt [read $channel]
        if {[eof $channel]} { fileevent $channel readable ""; set ::done 1 }
    }} $helper]
    vwait done
    fconfigure $helper -blocking 1
    set failed [catch {close $helper}]
    set ::nativecheck::channels [lsearch -all -inline -not -exact $::nativecheck::channels $helper]
    # Helper failure codes are 200 + 5*category + handshake progress (0..4:
    # none, initialize, initialized, reload request, native acknowledgement).
    # Categories follow the fixed diagnostics below; 10 means other. Never
    # emit captured output or any protocol payload to classify the failure.
    if {$failed} {
        set progress 0
        if {[file exists requests]} {
            set input [open requests r]
            set progress [llength [split [string trim [read $input]] \n]]
            close $input
        }
        set category 0
        foreach diagnostic {
            {WebSocket attachment failed or timed out}
            {no correlated reply within}
            {proxy disconnected or failed}
            {invalid App Server JSON}
            {initialize rejected by App Server}
            {reload rejected by App Server}
            {invalid initialize acknowledgement}
            {invalid reload acknowledgement}
            {tDOM 0.9.3 or newer is required}
            {proxy send failed}
        } {
            if {[string first $diagnostic $receipt] >= 0} { break }
            incr category
        }
        set ::nativecheck::phase [expr {200 + 5*$category + min(4, $progress)}]
        # For an attachment failure before initialize, distinguish shim startup,
        # native upgrade, relay startup and frontend upgrade (90..93).
        if {$category == 0 && $progress == 0} {
            set ::nativecheck::phase [expr {![file exists proxy-owned] ? 90 :
                ![file exists upstream-ready] ? 91 : ![file exists frontend-ready] ? 92 : 93}]
        }
    }
    nativecheck::check {!$failed} "headless native helper failed"
    set ::nativecheck::phase 26
    nativecheck::check {$receipt eq "MCP configuration reread; refresh queued for loaded threads (server-wide).\n"} \
        "headless native helper did not acknowledge queued refresh"
    set ::nativecheck::phase 27
    set input [open requests r]
    set requests [split [string trim [read $input]] \n]
    close $input
    set ::nativecheck::phase 28
    nativecheck::check {$requests eq {initialize initialized config/mcpServer/reload ACK}} "native reload handshake or acknowledgement changed"
    nativecheck::inventory $observer $thread version_one
    set input [open config.toml r]; set plainConfig [read $input]; close $input
    nativecheck::check {$plainConfig eq $originalConfig} "ordinary reload changed private configuration"
    set markers {}
    foreach iteration {first second} {
        set ::nativecheck::phase 62
        nativecheck::helper $wrapper 1
        nativecheck::inventory $observer $thread version_two
        set input [open mcp-owned r]; set processes [split [string trim [read $input]] \n]; close $input
        set currentMcp [lindex $processes end]
        nativecheck::check {$currentMcp ne $previousMcp && [nativecheck::live $currentMcp]} "force did not replace the actual fake MCP process"
        set previousMcp $currentMcp
        set current [nativecheck::rpc $observer config/read [huddle create includeLayers [huddle true] cwd [huddle null]] 63]
        set marker [automatic::text $current config mcp_servers neutral env CODEX_RETRY_MCP_GENERATION]
        nativecheck::check {[regexp {^[0-9a-f]{32}$} $marker] && $marker ni $markers} "force did not create or rotate generation"
        lappend markers $marker
        set expected [huddle get $configBefore config]
        huddle set expected mcp_servers neutral env CODEX_RETRY_MCP_GENERATION [huddle string $marker]
        nativecheck::check {[huddle equal $expected [huddle get $current config]]} "force changed unrelated settings or environment"
    }
    set input [open config.toml r]; set forcedConfig [read $input]; close $input
    nativecheck::helper $wrapper 0
    set input [open config.toml r]; set finalConfig [read $input]; close $input
    nativecheck::check {$finalConfig eq $forcedConfig} "ordinary reload changed a previously published marker"
    nativecheck::inventory $observer $thread version_two
    set input [open mcp-owned r]; set mcpProcesses [split [string trim [read $input]] \n]; close $input
    nativecheck::check {[llength $mcpProcesses] == 3} "helper started an unrelated MCP discovery client"
    set ::nativecheck::phase 15
    foreach child [pid $server] { nativecheck::check {![catch {exec kill -0 $child}]} "helper stopped private server" }
    set loaded [nativecheck::rpc $observer thread/loaded/list [huddle create] 70]
    set ::nativecheck::phase 18
    nativecheck::check {[huddle get_stripped $thread] in [huddle get_stripped $loaded data]} "helper unloaded neutral thread"
    set read [nativecheck::rpc $observer thread/read [huddle create threadId $thread includeTurns [huddle false]] 80]
    set ::nativecheck::phase 19
    nativecheck::check {[huddle get_stripped $read thread id] eq [huddle get_stripped $thread]} "helper changed neutral thread identity"
    foreach key {cwd modelProvider turns} {
        nativecheck::check {[huddle equal [huddle get $baseline thread $key] [huddle get $read thread $key]]} \
            "helper changed neutral thread settings"
    }
    set input [open proxy-owned r]
    foreach record [split [string trim [read $input]] \n] {
        nativecheck::check {![nativecheck::live $record]} "helper left an owned proxy child running"
    }
    close $input
} on error {message options} {
    puts stderr "private MCP fixture failed in phase $::nativecheck::phase: $message"
    set nativeFailure $::nativecheck::phase
} finally {
    nativecheck::cleanup
    cd $originalDirectory
    foreach name [array names env] { unset env($name) }
    array set env $environment
    file delete -force $scratch
}
if {$nativeFailure} { exit $nativeFailure }
foreach record $mcpProcesses {
    for {set i 0} {$i < 20 && [nativecheck::live $record]} {incr i} { after 10 }
    nativecheck::check {![nativecheck::live $record]} "private fake MCP survived fixture cleanup"
}
puts "PASS: ordinary acknowledgement/isolation, actual same-thread STDIO reconnection, generation creation/rotation, settings/history and owned cleanup; inference blocked"
