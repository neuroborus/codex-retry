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

Terminal input/output, window resizing, and TUI exit status pass through.
`-c`/`--config`, `--enable`, and `--disable` overrides also reach app-server. The wrapper
owns `--remote` and `--remote-auth-token-env`; non-interactive subcommands are
outside its scope. App Server is experimental, so check compatibility when
upgrading Codex.

Run the offline checks with `tclsh tests/retry.test.tcl`. They use structured
event fixtures, controlled timers, and a fake backend without model calls or
waiting through backoff.

Project guidance lives in `AGENTS.md` and `.agents/skills/`; `CLAUDE.md` and
`.claude/skills` are relative symlinks to those canonical files.
