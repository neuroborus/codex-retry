---
name: test-authoring
description: Add or review offline codex-retry checks for structured retries and the TUI proxy.
---

# Test Authoring

Use Tcl, structured JSON event fixtures, and controlled timers for retry checks.
Cover response/notification ordering, stale IDs, cancellation, unchanged input,
and the guard against replay after partial progress. Add a test only for a
distinct observable contract or a reproduced defect. Use neutral fixtures;
avoid assertions about source layout or documentation wording.

Check the WebSocket/stdio proxy with fake Codex processes in a pseudo-terminal
when changing transport or process handling. Check native TUI connection without
submitting a model turn when changing the remote handshake. Model calls remain
opt-in. Keep long backoff out of test execution; bound waits for process output
and clean up children.
