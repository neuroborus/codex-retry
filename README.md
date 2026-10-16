# codex-retry

A Tcl/Expect wrapper that keeps the native Codex TUI and retries confirmed
model overload through the [App Server protocol](https://learn.chatgpt.com/docs/app-server).

Requires `codex`, `expect`, and Tcllib. Tested with Codex CLI 0.162.1.
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

The wrapper starts a private `codex app-server` process and relays its JSON-RPC
traffic to the TUI through one authenticated loopback WebSocket connection.
Retry decisions use structured events exclusively; it never types `continue`.
Terminal input/output, window resizing, and TUI exit status pass through.
Large unrelated startup replies use their request ID and envelope boundaries
for routing without decoding the payload, keeping keyboard forwarding responsive.
Other response layouts use the full JSON parser.

Background app-server diagnostics are kept out of the interactive terminal.
After the TUI exits and releases the terminal, the wrapper prints them to stderr
with a diagnostic heading. Only the latest 64 KiB are retained in memory; a
truncation notice appears when earlier output was discarded. Startup failures
are reported directly if no TUI launched. No diagnostic log is saved to disk.

The private app-server stops when the TUI exits or disconnects. On supported
native 0.162.1 exits, an adapter buffers at most 16 KiB of the possible exit
epilogue after terminal restoration, replacing remote reconnect/stop instructions
and the continued-work claim. Live terminal content and token usage remain intact.
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
your shell, and displaying its value would not restore the stopped server.

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
  These are the only options copied to both processes; other options go to the
  TUI. A `--` separator stops the wrapper's option scan, so arguments after it
  are forwarded to the TUI without being interpreted or copied to app-server.
- `--remote` and `--remote-auth-token-env` are reserved for the wrapper's private
  connection. Supplying either option before `--`, including its `=value` form,
  is rejected.
- `--no-daemon` cannot be combined with the remote mode used by this wrapper.
  See the [Codex CLI reference](https://learn.chatgpt.com/docs/cli/reference).
- For interactive `resume`, the wrapper consumes explicit `--yolo` or
  `--dangerously-bypass-approvals-and-sandbox`, before or after `resume`.
  Codex CLI 0.162.1 rejects these permission overrides on remote resume before
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
input forwarding, and failure without model work. Native connection checks block
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
thread switching, and disconnection cancel a pending retry.

Automatic replay stops after model output, non-user item activity (including
tool execution), MCP elicitation requests, or hook activity, including early
events and start snapshots. Hooks and MCP elicitation without a turn ID
conservatively block replay in the active thread.
Other failures and ambiguous request rejections require manual recovery.
This deliberately covers overload before observable progress; it is not a
general transaction recovery mechanism.

Run the offline checks with `tclsh tests/retry.test.tcl`. They use structured
event fixtures, controlled timers, and a fake backend without model calls or
waiting through backoff.

Project guidance lives in `AGENTS.md` and `.agents/skills/`; `CLAUDE.md` and
`.claude/skills` are relative symlinks to those canonical files.
