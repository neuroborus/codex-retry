# codex-retry

A Tcl/Expect wrapper that keeps the native Codex TUI and retries confirmed
model overload through the [App Server protocol](https://learn.chatgpt.com/docs/app-server).

Requires `codex`, `expect`, and Tcllib. Tested with Codex CLI 0.162.1.
On Debian/Ubuntu, install the Tcl dependencies with `sudo apt install expect tcllib`.
Run the wrapper with interactive Codex arguments:

```sh
./codex-retry
./codex-retry resume --last
```

The wrapper starts a private `codex app-server` process and relays its JSON-RPC
traffic to the TUI through one authenticated loopback WebSocket connection.
It never examines terminal text or types `continue`.
Terminal input/output, window resizing, and TUI exit status pass through.
Large unrelated startup replies use their request ID and envelope boundaries
for routing without decoding the payload, keeping keyboard forwarding responsive.
Other response layouts use the full JSON parser.

The private app-server stops when the TUI exits or disconnects. The native TUI's
remote reconnect commands and "running work continues" message assume a server
that stays alive; that assumption does not apply to this wrapper. Reopen a saved
session with `./codex-retry resume SESSION_ID` or `./codex-retry resume --last`.

`CODEX_RETRY_TOKEN` names a temporary environment variable available to the child
TUI, not a token value to paste into the command. It is not exported back to
your shell, and displaying its value would not restore the stopped server.

## Arguments and compatibility

The wrapper forwards your argument list unchanged to the native Codex TUI,
preserving quoted values and argument boundaries. This includes options such as
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
- This tool is intended for interactive sessions, including `resume --last`.
  Non-interactive commands such as `exec`, `review`, `login`, and `mcp` are
  outside its supported scope. Run them directly with `codex`, for example
  `codex exec "Review the changes"`.

Automated checks cover resume/config argument forwarding and native TUI
initialization; they do not verify every Codex flag or subcommand. App Server is
experimental, so check compatibility when upgrading Codex.

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
