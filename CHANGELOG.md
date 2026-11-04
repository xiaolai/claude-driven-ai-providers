# Changelog

## Unreleased

- Return confirmed search activity to Claude Code so successful native searches are counted in the WebSearch result display.
- Add opt-in native Codex web search through Claude Code's existing WebSearch execution path, preserving permission and hook checks.
- Validate hosted search versions and restrictions, require explicit opt-in to waive the unsupported max_uses:8 limit, and report the effective policy in diagnostics.
- Buffer and validate search SSE before returning clickable citations; cover incomplete streams, duplicate terminals, cancellation, response limits and Unicode/multiple citations.
- Add explicit search checks and private setup fields; leave other provider routes and normal function-tool streaming unchanged.

## 0.1.1

- Report the selected Claude executable, symlink target, version, and competing installations in `clai doctor`.
- Honor `CLAI_CLAUDE_BIN` across managed and standalone launchers; reject invalid overrides.
- Cover PATH precedence, explicit selection, paths with spaces, and invalid executables with regression tests.
- Document macOS login-shell PATH ordering and installation on each destination machine.
