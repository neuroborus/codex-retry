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
        set receipt "MCP configuration reread; refresh queued for loaded threads (server-wide).\n"
        if {[string match force-* $mode]} {
            set receipt "MCP generation published; refreshed STDIO connections and catalogs verified for captured loaded threads (server-wide refresh).\n"
        }
        if {$failed || $status != $expected || (($expected == 0) != ($output eq $receipt))} {
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
        if {$mode eq "ordinary-marker"} {
            set input [open [file join $directory config.toml] r]
            if {[read $input] ne "CODEX_RETRY_MCP_GENERATION = \"left-by-force\"\n"} { lappend failures "$mode: ordinary reload changed the marker" }
            close $input
        }
        if {[string first "NEVER_PRINT_ENV_VALUE" $output] >= 0 ||
            ($expected != 0 && [string first "catalogs verified" $output] >= 0)} {
            lappend failures "$mode: unsafe failure diagnostic"
        }
        # Failures name only a fixed phase and method: no IDs, names or paths.
        if {$expected == 1} {
            foreach private [list codex-retry-mcp-force- thread-one thread-two thread-three secondary tertiary $::scratch] {
                if {[string first $private $output] >= 0} { lappend failures "$mode: diagnostic exposed private data" }
            }
        }
        set late "no correlated reply within 0.5 seconds during"
        set published "; generation published; readiness not verified"
        set diagnostics [dict create \
            deadline-init "$late initialization (initialize)" \
            partial-frame "$late initialization (initialize)" \
            string-init-id "$late initialization (initialize)" \
            deadline-reload "$late refresh (config/mcpServer/reload)" \
            descendant-partial-frame "$late refresh (config/mcpServer/reload)" \
            string-reload-id "$late refresh (config/mcpServer/reload)" \
            upgrade-deadline "$late connection (WebSocket upgrade)" \
            upgrade-eof "WebSocket attachment failed or timed out" \
            signal "interrupted by SIGTERM" \
            force-id-type "$late preflight (config/read)" \
            force-stall "$late preflight (mcpServerStatus/list)" \
            force-stall-future "force reply preceded its request" \
            force-future-id "force reply preceded its request" \
            force-slow-signal "interrupted by SIGTERM$published" \
            force-no-runtime "native thread runtimeStatus remained unavailable, configuration-mismatched or pending; readiness cannot be verified$published"]
        if {[dict exists $diagnostics $mode] &&
            [string first "codex-retry reload-mcp: [dict get $diagnostics $mode]\n" $output] < 0} {
            lappend failures "$mode: unexpected diagnostic: $output"
        }
        if {[string match force-* $mode] && $expected == 0 && ![file exists [file join $directory write.sent]]} {
            lappend failures "$mode: force did not publish a generation"
        }
        if {$mode in {force-no-threads force-no-servers force-origin force-origin-version force-project force-profile
            force-layer force-shape force-readonly force-name force-inherited force-thread-config force-cursor force-future-id
            force-id-type force-status-cursor force-inactive-thread force-nonlocal force-effective-command
            force-effective-timeout force-effective-tools force-tools-shape force-tool-approval force-tool-limit
            force-inherited-object force-stall force-stall-future} &&
            [file exists [file join $directory write.sent]]} { lappend failures "$mode: unsafe configuration write" }
        if {$mode in {force-overridden force-override-metadata force-bad-file force-bad-version force-bad-status force-conflict
            force-reload-error force-reload-shape force-no-runtime force-failed force-cancelled force-tools-error
            force-no-info force-churn force-cwd-churn force-race force-disconnect force-slow-signal} &&
            ![regexp {generation (published|publication uncertain)} $output]} { lappend failures "$mode: publication outcome was hidden" }
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
        # Long responsive force runs need more than the ordinary failsafe.
        after [expr {[string match force-* $mode] ? 8000 : 4000}] {exit 93}
        if {$mode eq "upgrade-eof"} { exit 0 }
        if {$mode eq "upgrade-deadline"} { vwait forever }
        set phase initialize
        set started [clock milliseconds]
        # Several threads and servers; slow modes answer every request late.
        set grid [expr {$mode in {force-slow force-slow-pending force-slow-signal force-stall force-stall-future}}]
        set slow [expr {$mode in {force-slow force-slow-pending force-slow-signal}}]
        if {[string match force-* $mode]} {
            source $wrapper
            set configFile [file join $env(RELOAD_DIR) config.toml]
            close [open $configFile w]
            set version original-version
            set name neutral
            if {$mode eq "force-name"} { set name neutral.invalid }
            set server [huddle create command tclsh args [huddle list neutral] \
                env [huddle create RETAIN NEVER_PRINT_ENV_VALUE] env_vars [huddle list KEEP]]
            if {$mode eq "force-defaults"} { set server [huddle create command tclsh] }
            if {$mode in {force-tools force-effective-tools force-tool-approval force-tool-limit}} {
                huddle set server startup_timeout_sec [huddle number 5]
                huddle set server tool_timeout_sec [huddle number 30]
                huddle set server tools [huddle create version_one [huddle create approval_mode approve output_token_limit [huddle number 123]]]
                huddle set server default_tools_approval_mode [huddle string prompt]
                huddle set server tool_input_schema_max_bytes [huddle number 1024]
                huddle set server supports_parallel_tool_calls [huddle true]
                huddle set server required [huddle false]
                huddle set server name [huddle string legacy-display-name]
            }
            if {$mode eq "force-legacy-timeout"} {
                huddle set server startup_timeout_ms [huddle number 5000]
                huddle set server env_vars [huddle list [huddle create name KEEP]]
            }
            if {$mode eq "force-nonlocal"} { huddle set server environment_id [huddle string remote] }
            if {$mode eq "force-tools-shape"} { huddle set server tools [huddle list] }
            if {$mode eq "force-tool-approval"} { huddle set server tools version_one approval_mode [huddle true] }
            if {$mode eq "force-tool-limit"} { huddle set server tools version_one output_token_limit [huddle string 123] }
            if {$mode eq "force-rotate"} { huddle set server env CODEX_RETRY_MCP_GENERATION [huddle string previous-generation] }
            if {$mode eq "force-shape"} { huddle set server env RETAIN [huddle number 1] }
            if {$mode eq "force-inherited"} { huddle set server env_vars [huddle list CODEX_RETRY_MCP_GENERATION] }
            if {$mode eq "force-inherited-object"} { huddle set server env_vars [huddle list [huddle create name CODEX_RETRY_MCP_GENERATION]] }
            set servers [huddle create $name $server disabled [huddle create enabled [huddle false] command unused] \
                http [huddle create url https://example.invalid]]
            set targetNames {neutral}
            if {$mode eq "force-multiple"} { huddle set servers secondary $server; lappend targetNames secondary }
            if {$grid} {
                huddle set servers secondary $server; huddle set servers tertiary $server
                lappend targetNames secondary tertiary
            }
            set nextId 2; set writes 0; set statusCalls 0; set loadedCalls 0
            set cwdReads {}; set postWriteReads 0; set readinessCalls 0; set verified {}; set signalled 0
            proc config {params} {
                set source [huddle create type user file $::configFile]
                if {$::mode eq "force-profile"} { huddle set source profile [huddle string selected] }
                set metadata [huddle create name $source version $::version]
                set origins [huddle create mcp_servers $metadata]
                if {$::mode eq "force-origin"} { set origins [huddle create] }
                if {$::mode eq "force-origin-version"} { huddle set origins mcp_servers version [huddle string stale] }
                if {$::mode eq "force-project" || ($::mode eq "force-thread-config" && ![automatic::is $params null cwd])} {
                    huddle set origins mcp_servers name [huddle create type project dotCodexFolder $::env(RELOAD_DIR)]
                }
                set settings [huddle create mcp_servers $::servers model neutral-model approval_policy never]
                if {$::mode eq "force-no-servers"} { huddle set settings mcp_servers [huddle create] }
                set layers [huddle list [huddle create name $source version $::version config $settings]]
                if {$::mode eq "force-layer"} {
                    huddle append layers [huddle create name [huddle create type sessionFlags] version other \
                        config [huddle create mcp_servers [huddle create neutral $::server]]]
                }
                # Independent native-shaped fixture: raw TOML omits defaults;
                # effective config adds them and serializes timeout seconds.
                set effective $settings
                foreach name $::targetNames {
                    if {![huddle exists $effective mcp_servers $name]} { continue }
                    huddle set effective mcp_servers $name enabled [huddle true]
                    if {![huddle exists $effective mcp_servers $name environment_id]} {
                        huddle set effective mcp_servers $name environment_id [huddle string local]
                    }
                    if {![huddle exists $effective mcp_servers $name args]} { huddle set effective mcp_servers $name args [huddle list] }
                    if {![huddle exists $effective mcp_servers $name tool_timeout_sec]} {
                        huddle set effective mcp_servers $name tool_timeout_sec [huddle null]
                    }
                    if {$::mode in {force-tools force-effective-tools force-tool-approval force-tool-limit force-legacy-timeout}} {
                        huddle set effective mcp_servers $name startup_timeout_sec [huddle number 5.0]
                    }
                    if {$::mode eq "force-legacy-timeout"} { set effective [huddle remove $effective mcp_servers $name startup_timeout_ms] }
                    if {[huddle exists $effective mcp_servers $name required]} { set effective [huddle remove $effective mcp_servers $name required] }
                    if {[huddle exists $effective mcp_servers $name name]} { set effective [huddle remove $effective mcp_servers $name name] }
                }
                switch -- $::mode {
                    force-effective-command { huddle set effective mcp_servers neutral command [huddle string different-command] }
                    force-effective-timeout { huddle set effective mcp_servers neutral tool_timeout_sec [huddle number 99] }
                    force-effective-tools { huddle set effective mcp_servers neutral tools version_one approval_mode [huddle string prompt] }
                }
                if {$::mode eq "force-multiple" && ![automatic::is $params null cwd]} {
                    huddle set effective mcp_servers [huddle create secondary [huddle get $effective mcp_servers secondary] \
                        neutral [huddle get $effective mcp_servers neutral] disabled [huddle get $effective mcp_servers disabled] \
                        http [huddle get $effective mcp_servers http]]
                }
                return [huddle create config $effective origins $origins layers $layers]
            }
            proc force_request {socket data} {
                set object [automatic::decode $data]
                if {[automatic::text $object id] ne "codex-retry-mcp-force-$::nextId"} { exit 71 }
                incr ::nextId
                set id [huddle get $object id]; set params [huddle get $object params]
                set method [automatic::text $object method]
                switch -- $method {
                    thread/loaded/list {
                        incr ::loadedCalls
                        set ids [huddle list thread-one]
                        set cursor [huddle null]
                        if {$::grid} { set ids [huddle list thread-one thread-two thread-three] }
                        if {$::mode eq "force-no-threads" || ($::mode eq "force-churn" && $::writes)} { set ids [huddle list] }
                        if {$::mode eq "force-pagination"} {
                            if {[huddle exists $params cursor]} {
                                if {[automatic::text $params cursor] ne "next"} { exit 72 }
                                set ids [huddle list thread-two]
                            } else { set cursor [huddle string next] }
                        }
                        if {$::mode eq "force-cursor"} { set cursor [huddle string repeated] }
                        set result [huddle create data $ids nextCursor $cursor]
                    }
                    config/read {
                        if {![automatic::is $params boolean includeLayers] || ![huddle get_stripped $params includeLayers]} { exit 73 }
                        if {$::mode eq "force-readonly"} { file attributes $::configFile -permissions 0400 }
                        # Each distinct thread directory is resolved once per run.
                        if {![automatic::is $params null cwd]} {
                            if {[dict exists $::cwdReads [automatic::text $params cwd]]} { exit 85 }
                            dict set ::cwdReads [automatic::text $params cwd] 1
                        }
                        if {$::writes && [incr ::postWriteReads] == 2 && $::slow &&
                            ([dict size $::verified] != 9 || [clock milliseconds] - $::started < 600)} { exit 86 }
                        set result [config $params]
                        if {$::mode eq "force-race" && $::writes} { huddle set result layers 0 version [huddle string concurrent] }
                        if {$::mode eq "force-future-id"} {
                            reply $socket [json_dump [huddle string codex-retry-mcp-force-$::nextId]] {{}}
                            return
                        }
                        if {$::mode eq "force-id-type"} {
                            reply $socket [expr {$::nextId - 1}] [json_dump $result]
                            return
                        }
                    }
                    thread/read {
                        if {![automatic::is $params boolean includeTurns] || [huddle get_stripped $params includeTurns]} { exit 74 }
                        set cwd $::env(RELOAD_DIR)
                        if {[automatic::text $params threadId] eq "thread-three"} { set cwd [file join $cwd other] }
                        set result [huddle create thread [huddle create id [huddle get $params threadId] \
                            cwd [huddle string $cwd] status [huddle create type idle]]]
                        if {$::mode eq "force-inactive-thread"} { huddle set result thread status type [huddle string notLoaded] }
                        if {$::mode eq "force-cwd-churn" && $::writes} { huddle set result thread cwd [huddle string /different-private-directory] }
                    }
                    config/batchWrite {
                        # Every captured pair was checked; each directory was read once.
                        if {$::grid && ([dict size $::cwdReads] != 2 || $::statusCalls != 9)} { exit 87 }
                        incr ::writes
                        if {$::writes != 1 || [automatic::text $params filePath] ne $::configFile ||
                            [automatic::text $params expectedVersion] ne "original-version" ||
                            ![automatic::is $params boolean reloadUserConfig] || [huddle get_stripped $params reloadUserConfig] ||
                            ![automatic::is $params list edits] ||
                            [huddle llength [huddle get $params edits]] != [llength $::targetNames]} { exit 75 }
                        set values {}
                        for {set i 0} {$i < [llength $::targetNames]} {incr i} {
                            set edit [huddle get $params edits $i]
                            set key ""
                            regexp {^mcp_servers\.([A-Za-z0-9_-]+)\.env\.CODEX_RETRY_MCP_GENERATION$} [automatic::text $edit keyPath] -> key
                            set marker [automatic::text $edit value]
                            if {[lsort [huddle keys $edit]] ne {keyPath mergeStrategy value} ||
                                $key ni $::targetNames || [dict exists $values $key] ||
                                [automatic::text $edit mergeStrategy] ne "upsert" || ![regexp {^[0-9a-f]{32}$} $marker] ||
                                $marker eq [automatic::text $::servers $key env CODEX_RETRY_MCP_GENERATION]} { exit 76 }
                            dict set values $key $marker
                        }
                        close [open [file join $::env(RELOAD_DIR) write.sent] w]
                        if {$::mode eq "force-conflict"} {
                            websocket::send $socket text [json_dump [huddle create id $id error [huddle create code [huddle number -32000] message conflict]]]
                            return
                        }
                        dict for {key value} $values {
                            if {![huddle exists $::servers $key env]} { huddle set ::servers $key env [huddle create] }
                            huddle set ::servers $key env CODEX_RETRY_MCP_GENERATION [huddle string $value]
                        }
                        if {($::mode ne "force-defaults" && [automatic::text $::servers neutral env RETAIN] ne "NEVER_PRINT_ENV_VALUE") ||
                            [automatic::text $::servers neutral command] ne "tclsh" ||
                            [automatic::text $::servers http url] ne "https://example.invalid"} { exit 77 }
                        set ::version updated-version
                        set result [huddle create status ok filePath $::configFile version $::version overriddenMetadata [huddle null]]
                        switch -- $::mode {
                            force-overridden { huddle set result status [huddle string okOverridden]; huddle set result overriddenMetadata [huddle create] }
                            force-override-metadata { huddle set result overriddenMetadata [huddle false] }
                            force-bad-file { huddle set result filePath [huddle string /unsupported] }
                            force-bad-version { huddle set result version [huddle string original-version] }
                            force-bad-status { huddle set result status [huddle true] }
                            force-disconnect { fixture::stop; exit 0 }
                        }
                    }
                    config/mcpServer/reload {
                        if {!$::writes || ![automatic::is $object null params]} { exit 78 }
                        close [open [file join $::env(RELOAD_DIR) reload.sent] w]
                        if {$::mode eq "force-reload-error"} {
                            websocket::send $socket text [json_dump [huddle create id $id error [huddle create code [huddle number -32601] message unsupported]]]
                            return
                        }
                        set result [huddle create]
                        if {$::mode eq "force-reload-shape"} { huddle set result queued [huddle true] }
                    }
                    mcpServerStatus/list {
                        if {[automatic::text $params threadId] ni {thread-one thread-two thread-three} ||
                            [automatic::text $params serverName] ni $::targetNames ||
                            [automatic::text $params detail] ne "toolsAndAuthOnly"} { exit 79 }
                        incr ::statusCalls
                        if {$::mode in {force-stall force-stall-future} && $::statusCalls == 5} {
                            # Mid-preflight silence for this request, amid unrelated traffic.
                            after 40 [list chatter $socket [expr {$::nextId - 2}] [expr {$::mode eq "force-stall-future"}]]
                            return
                        }
                        set status [huddle string connected]
                        if {$::mode eq "force-recover" && !$::writes} { set status [huddle string failed] }
                        if {$::mode eq "force-recover-pending" && !$::writes} { set status [huddle string starting] }
                        if {$::writes} {
                            if {$::mode eq "force-slow-pending" && [incr ::readinessCalls] <= 18} { set status [huddle string starting] }
                            if {$::mode eq "force-slow-signal" && !$::signalled} { set ::signalled 1; exec kill -TERM $::owner }
                            if {[automatic::text $status] eq "connected"} {
                                dict set ::verified [list [automatic::text $params threadId] [automatic::text $params serverName]] 1
                            }
                        }
                        set info [huddle create name neutral version neutral-version]
                        set toolsError [huddle null]
                        if {$::writes} {
                            switch -- $::mode {
                                force-no-runtime { set status [huddle null] }
                                force-failed { set status [huddle string failed] }
                                force-cancelled { set status [huddle string cancelled] }
                                force-pending { if {$::statusCalls == 2} { set status [huddle string starting] } }
                                force-tools-error { set toolsError [huddle string NEVER_PRINT_ENV_VALUE] }
                                force-no-info { set info [huddle null] }
                            }
                        }
                        set result [huddle create data [huddle list [huddle create name [huddle get $params serverName] runtimeStatus $status \
                            authStatus unsupported tools [huddle create] toolsError $toolsError \
                            resources [huddle list] resourceTemplates [huddle list] \
                            serverInfo $info serverCapabilities [huddle create tools [huddle create]]]] nextCursor [huddle null]]
                        if {$::mode in {force-status-pagination force-status-cursor}} {
                            if {![huddle exists $params cursor] || $::mode eq "force-status-cursor"} {
                                huddle set result data [huddle list]
                                huddle set result nextCursor [huddle string catalog-next]
                            }
                        }
                    }
                    default { exit 80 }
                }
                if {$::mode eq "force-unrelated"} { reply $socket {"2"} {{}}; reply $socket 1000 {[]} }
                if {$::slow} {
                    after 30 [list catch [list reply $socket [json_dump $id] [json_dump $result]]]
                    return
                }
                reply $socket [json_dump $id] [json_dump $result]
            }
            # Notifications, server requests, unrelated IDs, raw frames and stale
            # owned replies; optionally one future owned ID.
            proc chatter {socket stale future} {
                if {[catch {
                    websocket::send $socket ping neutral
                    foreach message [list {{"method":"fixture/notice","params":{}}} \
                        {{"id":"fixture-request","method":"fixture/request","params":{}}} \
                        {{"id":"unrelated","result":{}}} {{"id":1000,"result":{}}} \
                        {{"id":1000,"error":{"code":-32601,"message":"unrelated"}}} \
                        [format {{"id":"codex-retry-mcp-force-%d","result":{}}} $stale]] {
                        websocket::send $socket text $message
                    }
                    if {$future} {
                        websocket::send $socket text [format {{"id":"codex-retry-mcp-force-%d","result":{}}} $::nextId]
                    }
                }]} { return }
                after 40 [list chatter $socket $stale $future]
            }
        }
        proc reply {socket id result} {
            websocket::send $socket text [format {{"id":%s,"result":%s}} $id $result]
        }
        proc request {socket type data} {
            if {$type ne "text"} { return }
            if {$::phase eq "force"} { force_request $socket $data; return }
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
                    set ::owner $owner
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
                    if {[string match force-* $::mode]} { set ::phase force }
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
        upgrade-deadline binary signal extra option terminator ordinary-marker force-duplicate force-extra
        force-create force-defaults force-tools force-legacy-timeout force-rotate force-multiple force-recover force-recover-pending
        force-nonlocal force-effective-command force-effective-timeout force-effective-tools force-tools-shape force-tool-approval force-tool-limit force-inherited-object
        force-unrelated force-pagination force-status-pagination force-status-cursor force-pending force-no-threads force-no-servers
        force-origin force-origin-version force-project force-profile force-layer force-shape force-readonly force-name
        force-inherited force-thread-config force-inactive-thread force-cursor force-future-id force-id-type force-conflict
        force-overridden force-override-metadata force-bad-file
        force-bad-version force-bad-status force-reload-error force-reload-shape force-no-runtime force-failed
        force-cancelled force-tools-error force-no-info force-churn force-cwd-churn force-race force-disconnect
        force-slow force-slow-pending force-slow-signal force-stall force-stall-future} {
        set directory [file join $scratch $mode]
        file mkdir $directory
        set env(RELOAD_DIR) $directory
        set env(RELOAD_CASE) $mode
        set expected [expr {$mode in {ok unrelated ordinary-marker force-create force-defaults force-tools force-legacy-timeout force-rotate
            force-multiple force-recover force-recover-pending force-unrelated force-pagination force-status-pagination force-pending
            force-slow force-slow-pending} ? 0 : 1}]
        set arguments reload-mcp
        if {[string match force-* $mode]} { lappend arguments --force }
        if {$mode eq "ordinary-marker"} {
            set markerFile [open [file join $directory config.toml] w]
            puts $markerFile {CODEX_RETRY_MCP_GENERATION = "left-by-force"}
            close $markerFile
        }
        switch -- $mode {
            extra { lappend arguments extra; set expected 2 }
            option { lappend arguments --help; set expected 2 }
            terminator { lappend arguments --; set expected 2 }
            force-duplicate { lappend arguments --force; set expected 2 }
            force-extra { lappend arguments extra; set expected 2 }
        }
        set command [list $wrapper {*}$arguments]
        if {$mode in {deadline-init deadline-reload partial-frame descendant-partial-frame upgrade-deadline string-init-id string-reload-id
            force-no-runtime force-id-type force-slow force-slow-pending force-slow-signal force-stall force-stall-future}} {
            # Controlled internal per-request window, without a public configuration knob.
            set driver "set argv0 reload-deadline\n[list source $wrapper]\nset ::mcp_reload::timeout 500\nexit \[main [list $arguments]\]"
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
puts "PASS: headless MCP reload frames, typed replies, rejection, per-request deadlines, long responsive runs, arguments, receipt and owned cleanup"
