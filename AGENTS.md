# Project Guidance

Keep this tool a small Tcl/Expect wrapper around the interactive Codex CLI.
The README owns usage and retry behavior. Keep source, comments, and repository
documentation in English.

- Preserve the native TUI and terminal forwarding. Use App Server JSON events,
  correlate request/thread/turn IDs, and by default retry only a completed
  overload or narrowly verified transient model-transport failure before observable
  model/tool/hook progress. Let native retries finish; require this client's
  acknowledged start and correlated failed completion. Use one typed classifier:
  `serverOverloaded`, the four explicit transport object variants documented in
  README, or string `other` with either exact verified native closure message and
  absent/null additional details and misalignment metadata. Transport objects need
  one discriminator, an object payload, and absent/null HTTP status or integer
  408/429/500/502/503/504; reject unknown or contradictory shapes. Preserve the
  original input and settings; keep one timer with exponential delays from
  5 seconds to 30 minutes across mixed overload/stream failures.
- Cancel on manual turn/thread changes or disconnection; reset delay on success.
  Do not infer success or failure from terminal text. Only the explicit,
  default-false recovery flags may submit a new literal `continue` turn after
  verified earned-reset recovery, an acknowledged terminal `cyberPolicy` stop,
  or a qualified completed overload/transport failure after progress via
  `auto_continue_after_stop`. Keep the same exponential backoff for these
  follow-ups. Handle each distinct failure at most once; never replay partial
  work. Error notifications, reconnect banners and elapsed time grant no action;
  proxy/TUI disconnection still cancels recovery. Deploy source changes only in
  new wrapper processes; never intervene in an existing live session.
- Use the public tDOM 0.9.3+ API for strict typed JSON decoding, rejecting
  duplicate decoded member names and deleting temporary DOMs. Keep Tcllib for
  WebSocket framing, Huddle containers and JSON writing. Avoid frameworks,
  persistent state, and configuration layers unless requested behavior requires them.
- Keep project skills under `.agents/skills/`. `.claude/skills` points there;
  `CLAUDE.md` points to this file. Edit only the canonical files.
- Use `project-structure` for structural changes, `test-authoring` for checks,
  and `finalization` before handing off changes.
- Preserve unrelated user changes. Commit, stage, or push only when requested;
  keep the existing Git identity and omit co-author trailers.

Required checks:

```sh
tclsh tests/retry.test.tcl
git diff --check
git diff --cached --check
```

Use fake processes for terminal checks. A native TUI connection check must block
inference requests. Live model calls are opt-in.

When a runner reserves checks for FINALIZE, supply their inventory without
executing them in an agent turn. Workspace-wide hygiene may implement the
whitespace requirement before staging, including on an unborn branch; leave
index checks and staging to the runner's HANDOFF.
