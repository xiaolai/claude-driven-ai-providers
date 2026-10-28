#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
shellcheck -S warning "$0"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-executable.XXXXXXXX")
tmp=$(cd "$tmp" && pwd)
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
mkdir -p "$HOME" "$tmp/first" "$tmp/second" "$tmp/Claude Code"
unset CLAI_CLAUDE_BIN
for name in first second; do
  cat >"$tmp/$name/claude" <<'MOCK'
#!/bin/bash
if [ "${1:-}" = --version ]; then printf 'fixture-%s\n' "${0%/*}"; else printf '%s\n' "$0"; fi
MOCK
  chmod 700 "$tmp/$name/claude"
done
ln -s ../second/claude "$tmp/Claude Code/claude"
base_path=$PATH
for order in first second; do
  other=first; [ "$order" != first ] || other=second
  export PATH="$tmp/$order:$tmp/$other:$base_path"
  "$repo/clai" doctor deepseek >"$tmp/doctor" || true
  jq -e --arg path "$tmp/$order/claude" '.claude.executable==$path and .claude.resolved_target==$path and .claude.version==("fixture-"+($path|sub("/claude$";""))) and .claude.selection=="PATH" and (.warnings|length)>0' "$tmp/doctor" >/dev/null
  [ "$("$repo/clai" run deepseek -- --help | tail -1)" = "$tmp/$order/claude" ]
done
export CLAI_CLAUDE_BIN="$tmp/Claude Code/claude"
"$repo/clai" doctor deepseek >"$tmp/doctor" || true
jq -e --arg path "$CLAI_CLAUDE_BIN" --arg target "$tmp/second/claude" '.claude.executable==$path and .claude.resolved_target==$target and .claude.selection=="override"' "$tmp/doctor" >/dev/null
for launcher in clai clds cldls; do
  if [ "$launcher" = clai ]; then args=(run deepseek -- --help); else args=(--help); fi
  [ "$(CLAI_STANDALONE=1 "$repo/$launcher" "${args[@]}" | tail -1)" = "$CLAI_CLAUDE_BIN" ]
done
DEEPSEEK_API_KEY=fixture "$repo/clai" run deepseek -- --print fixture >"$tmp/launched"
grep -Fxq "$CLAI_CLAUDE_BIN" "$tmp/launched"
DEEPSEEK_API_KEY=fixture CLAI_STANDALONE=1 "$repo/clds" --print fixture >"$tmp/launched"
grep -Fxq "$CLAI_CLAUDE_BIN" "$tmp/launched"
# No Claude on PATH: an explicit executable must still work.
mkdir "$tmp/tools"
for tool in jq dirname; do ln -s "$(type -P "$tool")" "$tmp/tools/$tool"; done
PATH="$tmp/tools:/usr/bin:/bin" "$repo/clai" run deepseek -- --help >"$tmp/launched"
grep -Fxq "$CLAI_CLAUDE_BIN" "$tmp/launched"
if env -u CLAI_CLAUDE_BIN PATH="$tmp/tools:/usr/bin:/bin" "$repo/clai" doctor deepseek >"$tmp/doctor" 2>"$tmp/error"; then echo 'missing Claude accepted'; exit 1; fi
jq -e '.claude.executable==null and .claude.path_candidates==[] and (.missing_tools|contains("claude"))' "$tmp/doctor" >/dev/null
for invalid in '' claude "$tmp/missing" "$tmp/first"; do
  for launcher in clai clcd clds cldls; do
    if [ "$launcher" = clai ]; then args=(run deepseek -- --help); else args=(--print fixture); fi
    if CLAI_STANDALONE=1 CLAI_CLAUDE_BIN="$invalid" "$repo/$launcher" "${args[@]}" >"$tmp/output" 2>"$tmp/error"; then echo "invalid executable accepted: $launcher"; exit 1; fi
  done
done
chmod 600 "$tmp/second/claude"
if "$repo/clai" run deepseek -- --help >"$tmp/output" 2>"$tmp/error"; then echo 'non-executable override accepted'; exit 1; fi
printf 'PASS: Claude PATH order, competing installations, symlink/version diagnostics, explicit override, standalone launchers and invalid executables\n'
