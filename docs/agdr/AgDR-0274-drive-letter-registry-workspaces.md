---
id: AgDR-0274
timestamp: 2026-11-13T02:30:00Z
agent: platform-engineer
model: claude-sonnet-5-5
trigger: user-prompt
status: executed
category: security
---

# Treat Windows drive-letter registry workspaces as absolute

> In the context of the ticket-marker resolver and the project-context libraries on Windows, facing registry `workspace:` values and git-dir pointers that start with `C:/`, I decided to accept `[A-Za-z]:/*` and `[A-Za-z]:\\*` as absolute at nine path sites, to let `/start-ticket` write per-worktree markers for those projects, accepting that the same case pattern now appears in several files.

## Context

- Scope: OmarAraby/apexyard#7. The sites test absoluteness with a bare `/*)` pattern.
- Observed on 2026-11-13: for a registered project with `workspace: C:/Users/<user>/profile/projects/family`, `_at_validate_w` on the main clone returned `unregistered common dir`. On a linked worktree it returned `git dir failed validation`.
- Root cause: `C:/Users/...` fell into the relative arm and became `<ops-root>/C:/Users/...`. A space in the path is not the cause.
- Scope grew during the work. Git for Windows writes `gitdir: C:/...` in a linked worktree's `.git` file, and drive-letter `commondir` and `gitdir` back-pointers. The same bare test rejected every linked worktree on Windows, including the ops fork's own. A third pointer site was found while testing.
- Precedent: `_portfolio_resolve` in `.claude/hooks/_lib-portfolio-paths.sh` (me2resh/apexyard#1034) already accepts both drive-letter spellings. It keeps drive-relative `C:foo` relative on purpose. `tests/test_portfolio_paths_windows_drive_letter.sh` pins that rule.
- The ticket gate is trust-chain code (`.claude/hooks/**`). A wrong match here can widen or narrow which trees the gate accepts.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Inline the `_portfolio_resolve` case pattern at each site | Matches existing style. These libraries are sourced by POSIX-mode shells and need no new dependency or load order. The diff is small and easy to audit. | The pattern repeats at nine sites. |
| B. Add a shared helper such as `_is_abs_path` | One definition. | The libraries load in different orders. A new helper adds a missing-function failure mode in a gate. No helper exists today. |
| C. Convert every path with `cygpath` or `_windows_path_to_posix` first | Reuses the maintained helper. | Adds a subprocess or a library dependency to the hot path. `_at_rp` already resolves `C:/...` correctly. |

## Decision

Chosen: **Option A**, because it mirrors `_portfolio_resolve` exactly, adds no dependency, and keeps the change reviewable.

The pattern is `/*|[A-Za-z]:/*|[A-Za-z]:\\*`. The `[/\\]` after the colon is deliberate. Drive-relative `C:foo` and bare `C:` stay relative, as in `_portfolio_resolve`. Do not relax it to `[A-Za-z]:*`.

Sites changed:

- `_lib-active-ticket.sh`: `_at_entry_match`, `active_ticket_project_clone`, `active_ticket_project_markers`, and in `_at_validate_w_body` the `gitdir:` value, the `commondir` value, and the worktree's own `gitdir` back-pointer.
- `_lib-project-context.sh`: two registry workspace sites.
- `_lib-multi-repo-trace.sh`: `mrt_workspace_for`.

Not changed: `_lib-tracker.sh` readlink targets and `limit-reviewer-writes.sh` (OmarAraby/apexyard#8).

## Consequences

- A registry entry with a drive-letter `workspace:` validates its main clone and linked worktrees on Windows.
- No match is widened on POSIX hosts. There, `C:/x` is a path that does not exist, so the resolver still refuses it.
- Symlink, ownership, and registry-membership checks run after the path is classified and are unchanged.
- Tests: `test_registry_workspace_drive_letter.sh` checks classification on every platform. Real clone and worktree validation runs only where `pwd -W` exists, and prints SKIP elsewhere.
- Residual: the nine-site pattern can drift. A later change can add a shared helper once load order is unified.

## Artifacts

- Issue: OmarAraby/apexyard#7
- Precedent: `.claude/hooks/_lib-portfolio-paths.sh` `_portfolio_resolve`, me2resh/apexyard#1034
