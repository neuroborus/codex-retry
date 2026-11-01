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
    if {[file exists [file join $scratch proxy-owned]]} {
        set input [open [file join $scratch proxy-owned] r]
        foreach line [split [string trim [read $input]] \n] { lappend owned $line }
        close $input
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

if {[lindex $argv 0] eq "--proxy"} {
    # PATH redirects only the helper's owned proxy. All protocol replies below
    # come unchanged from the real private server, never from a fake backend.
    lassign [lrange $argv 1 end] ::nativecheck::scratch native socketPath
    nativecheck::check {![info exists env(CODEX_RETRY_TOKEN)]} "helper leaked its inherited TUI token"
    source [file join $root tests proxy-fixture.tcl]
    foreach level [logger::levels] { ${::websocket::log}::logproc $level message {return} }
    proc guarded_request {socket type data} {
        if {$type ne "text"} { return }
        if {[catch {
            set object [automatic::decode $data]
            set method [automatic::text $object method]
            nativecheck::check {$method ne "" && $method eq [lindex $::nativecheck::methods 0]} \
                "private proxy blocked unexpected request"
            set ::nativecheck::methods [lrange $::nativecheck::methods 1 end]
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
    check {$method in {initialize thread/start thread/read thread/loaded/list}} "observer blocked unexpected request"
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
                    set phase [dict get {30 100 40 120 50 140 70 160 80 180} $stage]
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

    set ::nativecheck::phase 23
    file mkdir [file join $scratch bin]
    set shim [open [file join $scratch bin codex] w]
    puts $shim {#!/bin/sh
if [ "$#" -ne 2 ] || [ "$1" != app-server ] || [ "$2" != proxy ]; then exit 91; fi}
    puts $shim "exec expect [shell_quote $subject] --proxy [shell_quote $scratch] [shell_quote $native] [shell_quote $socketPath]"
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
            {transport deadline expired}
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
    set ::nativecheck::phase 15
    foreach child [pid $server] { nativecheck::check {![catch {exec kill -0 $child}]} "helper stopped private server" }
    set loaded [nativecheck::rpc $observer thread/loaded/list [huddle create] 70]
    set ::nativecheck::phase 18
    nativecheck::check {[huddle get_stripped $thread] in [huddle get_stripped $loaded data]} "helper unloaded neutral thread"
    set read [nativecheck::rpc $observer thread/read [huddle create threadId $thread includeTurns [huddle false]] 80]
    set ::nativecheck::phase 19
    nativecheck::check {[huddle get_stripped $read thread id] eq [huddle get_stripped $thread]} "helper changed neutral thread identity"
    foreach key {cwd modelProvider} {
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
puts "PASS: headless native MCP queued acknowledgement, private server/thread survival and owned cleanup; inference blocked"
