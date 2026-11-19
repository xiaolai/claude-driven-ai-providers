#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-profile.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/commands" "$HOME/.claude/agents"
printf '# Global\n' >"$HOME/.claude/CLAUDE.md"
printf '{}\n' >"$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude-codex"
printf 'local\n' >"$HOME/.claude-codex/CLAUDE.md"

if "$repo/clai" profile link codex --items 'CLAUDE.md,nope' >/dev/null 2>"$tmp/err"; then echo 'unknown item accepted'; exit 1; fi
grep -q 'profile items must be chosen' "$tmp/err"
[ ! -L "$HOME/.claude-codex/CLAUDE.md" ]
[ -f "$HOME/.claude-codex/CLAUDE.md" ]
if "$repo/clai" profile link codex --items CLAUDE.md >/dev/null 2>"$tmp/err"; then echo 'real file replaced'; exit 1; fi
grep -q 'not a symlink' "$tmp/err"
rm -- "$HOME/.claude-codex/CLAUDE.md"

"$repo/clai" profile link codex --items CLAUDE.md,skills >/dev/null
[ "$(readlink "$HOME/.claude-codex/CLAUDE.md")" = "$HOME/.claude/CLAUDE.md" ]
[ "$(readlink "$HOME/.claude-codex/skills")" = "$HOME/.claude/skills" ]
[ ! -e "$HOME/.claude-codex/settings.json" ]
[ ! -e "$HOME/.claude-codex/commands" ]
"$repo/clai" profile link codex --items CLAUDE.md,skills >/dev/null
"$repo/clai" profile link codex --items commands,settings.json >/dev/null
[ "$(readlink "$HOME/.claude-codex/settings.json")" = "$HOME/.claude/settings.json" ]
if "$repo/clai" profile link codex --items 'CLAUDE.md,CLAUDE.md' >/dev/null 2>"$tmp/err"; then echo 'duplicate item accepted'; exit 1; fi
grep -q 'duplicate profile item' "$tmp/err"
if "$repo/clai" profile link codex --items 'skills/extra' >/dev/null 2>"$tmp/err"; then echo 'nested item accepted'; exit 1; fi

ln -s /tmp "$HOME/.claude-codex/agents"
if "$repo/clai" profile link codex --items agents >/dev/null 2>"$tmp/err"; then echo 'foreign symlink replaced'; exit 1; fi
grep -q 'somewhere else' "$tmp/err"
rm -- "$HOME/.claude-codex/agents"
"$repo/clai" profile link codex --items agents >/dev/null

"$repo/clai" profile show codex >"$tmp/show"
grep -qx 'profile .claude-codex' "$tmp/show"
grep -qx "linked CLAUDE.md -> $HOME/.claude/CLAUDE.md" "$tmp/show"
grep -qx "linked skills -> $HOME/.claude/skills" "$tmp/show"
grep -qx "linked agents -> $HOME/.claude/agents" "$tmp/show"
grep -qx "linked settings.json -> $HOME/.claude/settings.json" "$tmp/show"

"$repo/clai" profile unlink codex --items CLAUDE.md >/dev/null
[ ! -e "$HOME/.claude-codex/CLAUDE.md" ]
[ -L "$HOME/.claude-codex/skills" ]
"$repo/clai" profile unlink codex --items CLAUDE.md >/dev/null
rm -- "$HOME/.claude-codex/skills"
mkdir "$HOME/.claude-codex/skills"
if "$repo/clai" profile unlink codex --items skills >/dev/null 2>"$tmp/err"; then echo 'directory unlinked'; exit 1; fi
grep -q 'not an inheritance symlink' "$tmp/err"
rmdir "$HOME/.claude-codex/skills"

rm -rf -- "$HOME/.claude"
ln -s "$tmp/real-claude" "$HOME/.claude"
mkdir -p "$tmp/real-claude"
printf '# x\n' >"$tmp/real-claude/CLAUDE.md"
if "$repo/clai" profile link codex --items CLAUDE.md >/dev/null 2>"$tmp/err"; then echo 'symlinked ~/.claude accepted'; exit 1; fi
grep -q 'must be a real directory' "$tmp/err"

printf 'PASS: profile inheritance is opt-in, idempotent, and refuses replacement\n'
