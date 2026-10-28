# Changelog

## 0.1.1

- Report the selected Claude executable, symlink target, version, and competing installations in `clai doctor`.
- Honor `CLAI_CLAUDE_BIN` across managed and standalone launchers; reject invalid overrides.
- Cover PATH precedence, explicit selection, paths with spaces, and invalid executables with regression tests.
- Document macOS login-shell PATH ordering and installation on each destination machine.
