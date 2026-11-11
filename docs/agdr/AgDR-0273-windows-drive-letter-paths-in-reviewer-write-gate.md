---
id: AgDR-0273
timestamp: 2026-11-11T21:44:07Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: executed
---

# Accept Windows drive-letter paths in the reviewer write gate

> In the context of `limit-reviewer-writes.sh` on Windows, facing a gate that rejects every review-body write, I decided to normalise drive-letter paths with the shared `_windows_path_to_posix` helper after a raw dot-segment check, to let review agents post bodies without widening the write boundary, accepting one more call into a shared library.

## Context

- Claude Code on Windows sends `tool_input.file_path` as `C:\...` or `C:/...`.
- The hook accepted only a path that starts with `/`. It blocked every review-body write on Windows, including the `/c/...` path that its own message names. This was observed on 2026-11-11, in three attempts (OmarAraby/apexyard#4).
- `_lib-path-resolve.sh` already ships `_windows_path_to_posix`. `require-active-ticket.sh` uses it for the same problem (me2resh/apexyard#1724, #1743).
- `cygpath -u` collapses `..` segments. For example, `cygpath -u 'C:/a/../b'` prints `/c/b`. This was verified on the reporting host.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Run a dot-segment check on the raw path, then call `_windows_path_to_posix` | Reuses the maintained helper and its mount-table handling. Keeps the `..` rule. Fails closed when the library is missing. | Adds a second dot-segment check for drive-letter paths. |
| B. Add a drive-letter rewrite local to the hook | Has no library dependency. | Duplicates central logic. Drifts from the Git Bash mount-table fix (#1743). |
| C. Treat `[A-Za-z]:*` as absolute and compare raw strings | Needs the fewest lines. | Never matches the `pwd -P` roots. Misses the `/tmp` mount alias. |
| D. Normalise first, then run the existing dot-segment check | Needs one check only. | `cygpath` collapses `..`, so the dot-segment rule is lost silently. |

## Decision

Chosen: **A**, because it reuses the helper that the ticket gate already uses, and it keeps every existing rejection. A drive-relative path such as `C:foo` stays unchanged and is blocked as not absolute. When `_lib-path-resolve.sh` is missing, the path stays unconverted and is blocked.

## Consequences

- Review agents can write review bodies on Windows.
- The boundary does not change. Writes are allowed only under the bodies folder. Symbolic links and `.` or `..` segments stay blocked in every path form.
- The tests use a fake `cygpath` that maps drive `Z:` onto the fixture, so the drive-letter cases run on Linux CI. On a Windows host the tests also run cases with the real `cygpath`.
- The fix should be proposed upstream to me2resh/apexyard, which has the same check.

## Artifacts

- Ticket: OmarAraby/apexyard#4
- Changed files: `.claude/hooks/limit-reviewer-writes.sh`, `.claude/hooks/tests/test_limit_reviewer_writes.sh`
