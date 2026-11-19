# Changelog

## 0.1.2

- Bound `clcd`'s process-tree cleanup: replace unbounded recursion with an iterative, visited-set traversal capped at 4096 nodes. Deep or stale PID ancestry could exhaust the 8 MB bash stack, leave bridge handlers orphaned, and trigger a fork/pre-exec crash storm.
- Make `stop_upstream` idempotent, close the upstream descriptor first, and harden handlers with runtime-directory checks, TERM/HUP handling, and descriptor cleanup.
- Add regression coverage for cyclic and deep PID graphs.
- Return confirmed search activity to Claude Code so successful native searches are counted in the WebSearch result display.
- Add opt-in native Codex web search through Claude Code's existing WebSearch execution path, preserving permission and hook checks.
- Validate hosted search versions and restrictions, require explicit opt-in to waive the unsupported max_uses:8 limit, and report the effective policy in diagnostics.
- Buffer and validate search SSE before returning clickable citations; cover incomplete streams, duplicate terminals, cancellation, response limits and Unicode/multiple citations.
- Add explicit search checks and private setup fields; leave other provider routes and normal function-tool streaming unchanged.
- Add an isolated `kimi-code` / `clkc` membership route, with its own key and an official China/overseas endpoint allowlist, separate from Open Platform `clki`.
- Add `CLAI_SKIP_PERMISSIONS=0` so launchers can omit `--dangerously-skip-permissions`.
- Add `clai profile link` to opt selected `~/.claude` items into one provider profile.
- Document that `clcd` does not serve the auto-mode classifier, so those checks fail closed.

## 0.1.1

- Report the selected Claude executable, symlink target, version, and competing installations in `clai doctor`.
- Honor `CLAI_CLAUDE_BIN` across managed and standalone launchers; reject invalid overrides.
- Cover PATH precedence, explicit selection, paths with spaces, and invalid executables with regression tests.
- Document macOS login-shell PATH ordering and installation on each destination machine.
