# Changelog

## 0.1.2

- Bound `clcd`'s process-tree cleanup: replace unbounded recursion with an iterative, visited-set traversal capped at 4096 nodes. Deep or stale PID ancestry could exhaust the 8 MB bash stack, leave bridge handlers orphaned, and trigger a fork/pre-exec crash storm.
- Make `stop_upstream` idempotent, close the upstream descriptor first, and harden handlers with runtime-directory checks, TERM/HUP handling, and descriptor cleanup.
- Add regression coverage for cyclic and deep PID graphs.

## 0.1.1

- Report the selected Claude executable, symlink target, version, and competing installations in `clai doctor`.
- Honor `CLAI_CLAUDE_BIN` across managed and standalone launchers; reject invalid overrides.
- Cover PATH precedence, explicit selection, paths with spaces, and invalid executables with regression tests.
- Document macOS login-shell PATH ordering and installation on each destination machine.
