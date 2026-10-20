# codex-retry

A Tcl/Expect wrapper that keeps the native Codex TUI and retries confirmed
model overload through the [App Server protocol](https://learn.chatgpt.com/docs/app-server).

Requires `codex`, `expect`, and Tcllib, with the shared-server commands available
in Codex CLI 0.163.0.
On Debian/Ubuntu, install the Tcl dependencies with `sudo apt install expect tcllib`.
Run the wrapper with interactive Codex arguments:

```sh
./codex-retry
./codex-retry resume --last
./codex-retry resume SESSION_ID --yolo
./codex-retry resume --last --yolo
./codex-retry --yolo resume SESSION_ID
./codex-retry resume SESSION_ID --dangerously-bypass-approvals-and-sandbox
```

The wrapper runs the idempotent `codex app-server daemon start`, then attaches
with an owned `codex app-server proxy` byte tunnel. Tcllib speaks WebSocket
through that pipe to the control socket. Codex selects the shared
control socket, so sessions already loaded by ordinary Codex keep their ID and
history. A cold launch starts that same shared server. Startup or attachment
failure is reported without falling back to an independent writer. JSON-RPC
traffic from the main TUI passes through the retry engine and an authenticated
loopback WebSocket endpoint. The native in-session `/resume` picker can list,
search and select saved sessions. Each temporary picker connection initializes
through its own owned proxy bridge to the same shared server; closing the picker
or losing its bridge keeps the main TUI connected. Picker metadata does not
affect the main TUI's retries, launch permissions or selected-session exit advice.
Selecting a session still uses the native TUI's normal session handoff.
Recovery decisions use structured events exclusively. By default, only the
overload retry below is enabled; the optional recovery modes submit a new
`continue` turn only when explicitly configured.
Terminal input/output, window resizing, and TUI exit status pass through.
`Ctrl+C` stays under native TUI control, including stopping an active turn and
its normal repeat-to-exit behavior. If it arrives as `SIGINT`, the wrapper
forwards a Ctrl+C keystroke to the TUI. Before the TUI starts, `SIGINT` cancels
startup; `SIGTERM` and `SIGHUP` still close the wrapper.
If wrapper input closes, it disconnects and drains the TUI's final output before
reaping the child and restoring the terminal.
Large unrelated startup replies use their request ID and envelope boundaries
for routing without decoding the payload, keeping keyboard forwarding responsive.
Other response layouts use the full JSON parser.

Background app-server diagnostics are kept out of the interactive terminal.
After the TUI exits and releases the terminal, the wrapper prints them to stderr
with a diagnostic heading. Only the latest 64 KiB are retained in memory; a
truncation notice appears when earlier output was discarded. Startup failures
are reported directly if no TUI launched. No diagnostic log is saved to disk.

Closing Retry disconnects its client; the shared server, sessions and background
work may continue, including when Retry started the server. Cleanup terminates
only the owned TUI and stdio bridges, including temporary picker connections.
Terminal attributes and mouse reporting are restored before exit advice or
diagnostics, including failed and interrupted exits. An adapter buffers at most
16 KiB of the possible native exit epilogue after terminal release, replacing
reconnect/stop commands that target the expired wrapper endpoint. Live terminal
content and token usage remain intact.
The final output offers one
copyable wrapper command for the last successfully selected session, for example:

```sh
codex-retry resume 01900000-0000-7000-8000-000000000001 --yolo
```

The command uses the installed launcher when available, otherwise its absolute
path, with shell quoting so it also works outside this checkout. Explicit launch
YOLO is retained only while confirmed permissions still apply; manual permission
changes stop it from being carried forward. The session comes from correlated
successful App Server replies, never terminal text or saved history. If activation
fails or no resumable session is confirmed, the command opens the `resume` picker
instead of inventing a session ID. You can also open that picker yourself with
`codex-retry resume` (or the absolute launcher path shown at exit).

`CODEX_RETRY_TOKEN` names a temporary environment variable available to the child
TUI, not a token value to paste into the command. It is not exported back to
your shell, and displaying its value would not restore the closed wrapper endpoint.

## Arguments and compatibility

The wrapper forwards your arguments to the native Codex TUI, preserving quoted
values, ordering, and argument boundaries, with the resume YOLO exception below.
This includes options such as
`--model` (`-m`), `--cd` (`-C`), `--profile` (`-p`), `--ask-for-approval` (`-a`),
`--sandbox` (`-s`), `--image` (`-i`), and `--no-alt-screen`. The installed Codex
version decides which options are valid in remote mode and how they take effect.
Forwarding alone does not guarantee the same behavior as a regular local Codex
session.

- `-c`/`--config`, `--enable`, and `--disable` are also passed to app-server.
  They are supplied to shared-server startup and the bridge as well as the TUI.
  They do not reconfigure an already-running daemon; the server decides effective
  settings. Other options go to the TUI. A `--` separator stops the wrapper's
  option scan, so arguments after it are forwarded to the TUI without being
  interpreted or copied to app-server.
- `--remote` and `--remote-auth-token-env` are reserved for the wrapper's private
  connection. Supplying either option before `--`, including its `=value` form,
  is rejected.
- `--no-daemon` cannot be combined with the remote mode used by this wrapper.
  See the [Codex CLI reference](https://learn.chatgpt.com/docs/cli/reference).
- For interactive `resume`, the wrapper consumes explicit `--yolo` or
  `--dangerously-bypass-approvals-and-sandbox`, before or after `resume`.
  Codex CLI 0.163.0 rejects these permission overrides on remote resume before
  connecting. The wrapper instead requests `approvalPolicy: "never"` and
  `sandbox: "danger-full-access"` on the launch's `thread/resume` RPC: commands
  run without approvals or the Codex sandbox. Prompts and option values containing
  either spelling are preserved; `--` ends flag recognition. Ordinary launches
  and resumes retain native behavior, including new-session YOLO flags.
- Resume YOLO retains native conflicts with `-a`/`--ask-for-approval` and
  `--approve-for-me` (alias `--not-so-yolo`). A non-null named `permissions`
  profile on the resume RPC is also incompatible with the requested sandbox;
  the wrapper rejects it rather than removing it. Other arguments and config
  overrides remain available for native or server validation.
- The server decides the effective permissions. The wrapper verifies the matching
  response's request ID, thread ID, approval policy, and sandbox before allowing
  work, and forwards confirmed responses and profile provenance unchanged.
  A server rejection, malformed acknowledgement, permission mismatch, or premature
  work request stops the guarded launch with an error. Native RPC errors are
  forwarded and their messages included in the wrapper's failure guidance.
  The launch override applies once to the intended resume. Manual thread changes
  cancel it; changes during verification stop the launch. After confirmation,
  subsequent manual permission changes and later threads remain native-owned.
- This tool is intended for interactive sessions, including `resume --last`.
  Non-interactive commands such as `exec`, `review`, `login`, and `mcp` are
  outside its supported scope. Run them directly with `codex`, for example
  `codex exec "Review the changes"`.

Offline fixtures and fake Codex PTY checks cover resume permissions, config and
input forwarding, shared-server attachment and ownership, cold startup, terminal
restoration, and failure without model work. Native connection checks block
inference and cover TUI initialization and both native and wrapped exits using
synthetic history, live lookalikes, token totals, terminal restoration and cleanup.
These checks do not verify real stored-session resume behavior or cover every
Codex flag or subcommand. App Server is experimental, so check compatibility when
upgrading Codex.

## Retry behavior

A retry requires an acknowledged `turn/start` and a matching `turn/completed`
with `status: "failed"` and `error.codexErrorInfo: "serverOverloaded"`.
The original input and settings are reused with a fresh request ID. This starts
a new turn in the same thread; it does not rewind history or roll back effects.

Retries wait 5, 10, 20, 40 seconds, and so on, capped at 30 minutes, without
jitter or an attempt limit. Success resets the delay. Duplicate and stale events
do not schedule extra retries. New submitted input, steering, interruption,
thread switching, account/auth changes, and disconnection cancel a pending retry.
Conflicting activity in the same thread from another client also cancels replay,
including settings changes, a different live turn, and additional or changed
user messages in our turn. Duplicate notifications of our original input remain
eligible. Foreign responses cannot acknowledge our work.

Automatic replay stops after model output, non-user item activity (including
tool execution and automatic context compaction), MCP elicitation requests, or
hook activity, including early events and start snapshots. Correlated legacy
`thread/compacted` notifications also count as progress and preserve ownership
for opt-in recovery after a later overload. Manual compaction cancels recovery.
Hooks and MCP elicitation without a turn ID conservatively block replay in the
active thread.
Other failures and ambiguous request rejections require manual recovery.
The default behavior covers overload before observable progress; it is not a
general transaction recovery mechanism.
To continue after overload following model/tool/hook progress, enable
`auto_continue_after_stop` below. This submits a new `continue` turn using the
same exponential delay, rather than replaying the original request.

## Optional recovery

The wrapper reads `$XDG_CONFIG_HOME/codex-retry/config.json` once at startup.
If `XDG_CONFIG_HOME` is unset, empty or relative, it uses
`$HOME/.config/codex-retry/config.json`. Both flags default to `false`:

```json
{
  "auto_reset_limit": false,
  "auto_continue_after_stop": false
}
```

Copy [config.example.json](config.example.json) to the configuration path above.
For the default location, run from the repository directory:

```sh
mkdir -p "$HOME/.config/codex-retry"
cp -i config.example.json "$HOME/.config/codex-retry/config.json"
```

Set either flag to the JSON boolean `true` to enable it. Missing files or keys
retain the defaults. Unreadable, malformed, oversized or non-object files, or
incorrectly typed flags such as `"true"`, disable both modes with a warning.
Unknown keys are ignored. Configuration is data, never Tcl or shell code;
there are no additional wrapper command-line flags, profiles or saved recovery
state. Native Codex argument forwarding remains as described above.

`auto_reset_limit` handles an acknowledged, failed turn with the typed error
`usageLimitExceeded`. It reads fresh account limits and requires confirmed
OpenAI provider provenance, an identified account and relevant ordinary quota,
`ordinaryUsageAllowed: false`, `rateLimitReachedType: "rate_limit_reached"`,
and `spendControlReached: false`. The default `codex` quota is supported;
other quota aliases require an exact effective-model match. Missing provenance,
transient throttling (`rateLimitExceeded`), session budgets and spend controls
do not authorize redemption.

The authoritative `rateLimitResetCredits.availableCount` must be positive.
Missing or null availability means unknown; zero means no earned resets.
A positive count works even when credit details are null or empty. A credit ID
is supplied only when an available Codex reset is identified in that read.
For each distinct failure, the wrapper sends one redemption with a fresh logical
idempotency key that remains stable for that incident. It never retries an
ambiguous redemption or purchases credits, and never emails
workspace owners. Account requests time out after 10 seconds with a warning;
the server may already have processed a timed-out redemption.

After `reset` or `alreadyRedeemed`, a full limits read must identify the same
account and quota, explicitly allow ordinary usage, and confirm no reached
rate limit or spend control. Percentages, reset timestamps and sparse
`account/rateLimits/updated` notifications cannot establish recovery. Verified
recovery starts a new same-thread turn with exactly `continue`, independently
of the second flag. Unsupported APIs, unknown or unavailable resets,
`nothingToReset`, `noCredit`, failed verification and unchanged exhausted
limits warn and leave work stopped. A limit change before redemption cancels
it. For each redemption, updates can cause at most one additional full
verification read. Further changes warn and leave work stopped, without another
redemption.

`auto_continue_after_stop` handles the confirmed native content stop represented
by `cyberPolicy` in CLI 0.163.0 and `serverOverloaded` after observable progress.
It requires this client's acknowledged `turn/start` and a matching
`turn/completed` with `status: "failed"` and a string `error.codexErrorInfo`
exactly equal to the applicable code. The wrapper forwards the native failure,
then submits exactly the plain ASCII user text
`continue` as one new turn in the same thread. Content stops continue immediately;
overload follow-ups wait 5, 10, 20 seconds, and so on up to 30 minutes, without an
attempt limit. Consecutive overloads retain the delay even when a new `continue`
is needed; success or manual new work resets it. Before progress, overloads keep
the original-input replay behavior regardless of this flag.
Generic refusal text, `other`, `misalignmentPolicyViolation`, transient safety
buffering, opaque moderation metadata, error notifications alone and successful
completion do not trigger it. Other CLI versions or stop types require a verified
protocol mapping; there is no terminal-text fallback.

Both modes preserve native history and restrictions and retain the turn's
settings. Earlier tool effects remain in place. Only the neutral follow-up is
submitted, without replaying original input, attachments, tool outputs or
additional context. This automates a manual follow-up; it does not diagnose
false positives or override native restriction decisions.

Each distinct qualifying failure can recover, including failures of automatic
continuations. There is no per-chain or total-attempt cap, and the modes have
no shared allowance. Each usage-limit incident requires fresh eligibility and
verification with an available earned reset. Duplicate or stale events cannot
repeat a continuation or redemption for the same failure. Overload retries
before progress retain their original input, settings and backoff. IDs,
ownership and ordering must be unambiguous.
Pre-existing active work reported by activation/history snapshots or
thread-status events cannot be claimed as this client's newly started turn.
Metadata reads preserve recovery eligibility without changing the selected thread.
Manual turn/thread, settings or goal changes, conflicting same-thread activity,
account changes and disconnection cancel pending recovery, including overload
retries of its automatic continuation. Late progress, including new or changed
work in repeated terminal snapshots, also cancels queued recovery.
Native warnings appear through the typed warning notification; if delivery is
unavailable, the existing bounded diagnostics show them after the TUI releases
the terminal.

Run the offline checks with `tclsh tests/retry.test.tcl`. They use structured
event fixtures, controlled timers, and a fake backend without model calls or
waiting through backoff. Fixtures cover opt-in configuration, reset eligibility
and verification, repeated and mixed-mode continuation, deduplication and
cancellation, plus warnings and responsive input through fake PTYs.

Project guidance lives in `AGENTS.md` and `.agents/skills/`; `CLAUDE.md` and
`.claude/skills` are relative symlinks to those canonical files.
