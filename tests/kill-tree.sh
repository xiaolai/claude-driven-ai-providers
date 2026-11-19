#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/clcd"
work=$(mktemp -d "${TMPDIR:-/tmp}/kill-tree-tests.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
killed=$work/killed

# Exercise the real helper without starting the bridge.
awk '/^kill_tree\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$script" >"$work/kill_tree.sh"
[ -s "$work/kill_tree.sh" ] || { printf 'could not extract kill_tree\n' >&2; exit 1; }

# The helper resolves these at call time, so mocks take precedence over the
# real process table and signal delivery.
pgrep() {
  local parent=${2:-}
  case "$parent" in
    100) printf '101\n';;
    101) printf '100\n';;
    *)
      if [ "$parent" -ge 2000 ] 2>/dev/null && [ "$parent" -lt 7000 ]; then
        printf '%s\n' "$((parent + 1))"
      fi
      ;;
  esac
}
kill() { printf '%s\n' "$*" >>"$killed"; }

# shellcheck source=/dev/null
source "$work/kill_tree.sh"

# A PID cycle must terminate and signal each PID once.
: >"$killed"
kill_tree 100
grep -qx -- '-TERM 101' "$killed"
grep -qx -- '-TERM 100' "$killed"
[ "$(wc -l <"$killed")" -eq 2 ]

# A very deep chain must stop at the node bound instead of exhausting the stack.
: >"$killed"
kill_tree 2000
[ "$(wc -l <"$killed")" -eq 4096 ]

# PID 1, the current shell, and malformed input must never be signalled.
: >"$killed"
kill_tree 1
kill_tree "$$"
kill_tree ''
kill_tree not-a-pid
[ ! -s "$killed" ]

printf 'PASS: kill_tree handles cycles, the depth bound, PID 1, self, and malformed input\n'
