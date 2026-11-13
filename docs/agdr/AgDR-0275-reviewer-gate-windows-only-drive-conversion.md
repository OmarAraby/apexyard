---
id: AgDR-0275
timestamp: 2026-11-13T00:00:00Z
agent: platform-engineer
model: claude-opus-5-5
trigger: user-prompt
status: executed
---

# Convert drive-letter paths in the reviewer write gate on Windows shells only

> In the context of `limit-reviewer-writes.sh`, facing a drive-letter conversion that runs on every OS and trailing dots and spaces that Windows strips from path segments, I decided to convert only when `OSTYPE` is `msys` or `cygwin` and to block any segment that ends in a dot or a space, to keep the write boundary identical on every host, accepting that a path with such a segment cannot be a body path.

## Context

- AgDR-0273 made the hook convert `C:\...` and `C:/...` with `_windows_path_to_posix`. The conversion ran on every OS.
- On Linux and macOS the helper reads `C:/x` as `/c/x`. The Write tool may read `C:/x` as a relative path. The two could name different targets. An exploit needs an ops root under `/c/`, so the risk is low (Security review of PR #6, Low).
- No test sent a literal `/c/...` path. MSYS rewrites a `/c/` argument to `C:/` when it starts a non-MSYS program such as `jq`.
- Windows strips a trailing dot or space from a path segment in some APIs. The hook compares strings, so it cannot see the stripped form.
- Probe on Windows 11 (Python 3.15 file creation under a temp folder, 2026-11-13): `bodies./a.txt` wrote into `bodies/`. These did not resolve: `bodies /`, `bodies/.. /`, `bodies/.../`, `bodies/.. ./`, `bodies/. /`, `bodies/x./`. No variant reached `reviews/`. The probe does not cover every Windows API or version.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Gate on `OSTYPE` (`msys*`, `cygwin*`) | Matches the shell that sends drive-letter paths. Tests force each branch with an environment value, so the hook needs no test seam. | A Windows shell that clears `OSTYPE` blocks drive-letter paths (fail closed). |
| B. Gate on `command -v cygpath` | Detects the tool that the conversion uses. | A test cannot hide `cygpath` on a Windows host without a minimal PATH. A `cygpath` on a non-Windows host enables the conversion. |
| C. Gate on either signal | Widest Windows coverage. | Inherits the weakness of B. |
| D. Add a test-only override variable | Easy to test. | Adds a control knob to trust-chain code. |

Trailing dots and spaces:

| Option | Pros | Cons |
|--------|------|------|
| E. Block every segment that ends in a dot or a space | Needs no knowledge of the OS rules. Removes the whole class, including the final-segment case the probe did not cover. | Rejects names that no body uses. |
| F. Rely on the probe and add no rule | No code change. | Depends on OS behaviour that differs by API and version. |

## Decision

Chosen: **A** and **E**.

- A Windows shell always sets `OSTYPE` to `msys` or `cygwin`. On any other OS the path stays unconverted and the hook blocks it as not absolute. The hook still fails closed.
- Tests set `OSTYPE` in the hook's environment. Bash keeps an inherited `OSTYPE`, so no seam is needed.
- The segment rule runs on the raw path before conversion, because `cygpath -u` can rewrite segments. Segments `.`, `..` and `...` are also caught.
- The probe shows no escape. Rule E blocks the aliases anyway, because the string checks cannot tell them apart.

## Consequences

- On Linux and macOS, `C:/x` is never read as `/c/x`.
- On Windows the behaviour of AgDR-0273 is unchanged. A review agent can still write its body.
- Linux CI runs the Windows cases through `OSTYPE=msys` and the fake `cygpath`. On a Windows host the tests also send a literal `/c/...` path, built with `MSYS2_ARG_CONV_EXCL='*'`.
- Alternate data streams (`name:stream`) and 8.3 short names are not covered. The probe did not test them.

## Artifacts

- Ticket: OmarAraby/apexyard#8
- Builds on: AgDR-0273
- Changed files: `.claude/hooks/limit-reviewer-writes.sh`, `.claude/hooks/tests/test_limit_reviewer_writes.sh`
