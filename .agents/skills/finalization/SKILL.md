---
name: finalization
description: Validate codex-retry changes and shared guidance before handing them off.
---

# Finalization

Review the change against the request, `AGENTS.md`, and the README. Check that
the wrapper stays small, the documented retry behavior matches it, and shared
guidance symlinks resolve inside this repository.

Complete the required checks in `AGENTS.md` through the authorized executor;
repair failures within the current scope.
When a runner owns FINALIZE, report reserved checks as `NOT_RUN` with their
frozen identities and reservation reason; let the runner execute the selected
commands. Do not duplicate them with bare invocations or inspect or alter the
index during polishing. Workspace-wide hygiene can cover whitespace before
staging, including an unborn branch; HANDOFF owns index checks and staging.
For transport changes, follow the [test-authoring skill](../test-authoring/SKILL.md)
and include a fake Codex check in a pseudo-terminal. Native TUI initialization
must intercept and block inference requests. Validate changed skills with an
available skill validator, through FINALIZE when checks are runner-owned.
Keep downloaded tools and generated artifacts in ignored `LOCAL_ARTIFACTS/`
or outside the repository within permitted storage.

Report actual results and any unrun checks. Preserve unrelated changes and leave
staging and commits to an explicit user request.
