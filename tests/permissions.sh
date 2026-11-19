#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-permissions.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME" "$tmp/bin" "$tmp/config"
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"$PERM_ARGS"
exit 0
MOCK
chmod 700 "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH" PERM_ARGS="$tmp/args"
key=$(openssl rand -hex 16)

arg() { sed -n "$1p" "$PERM_ARGS"; }
launch_deepseek() {
  : >"$PERM_ARGS"
  DEEPSEEK_API_KEY="$key" "$repo/clai" run deepseek -- --print 'keep permissions'
}
launch_deepseek
[ "$(arg 1)" = --dangerously-skip-permissions ]
[ "$(arg 2)" = --print ]
CLAI_SKIP_PERMISSIONS=0 launch_deepseek
[ "$(arg 1)" = --print ]
[ "$(arg 2)" = 'keep permissions' ]
CLAI_SKIP_PERMISSIONS=false launch_deepseek
[ "$(arg 1)" = --print ]
if CLAI_SKIP_PERMISSIONS=maybe DEEPSEEK_API_KEY="$key" "$repo/clai" run deepseek -- --print x >/dev/null 2>"$tmp/err"; then
  echo 'invalid permission setting launched'
  exit 1
fi
grep -q 'CLAI_SKIP_PERMISSIONS must be 1 or 0' "$tmp/err"

export CLAI_STANDALONE=1
: >"$PERM_ARGS"
CLAI_SKIP_PERMISSIONS=no DEEPSEEK_API_KEY="$key" "$repo/clds" --print standalone
[ "$(arg 1)" = --print ]
: >"$PERM_ARGS"
CLAI_SKIP_PERMISSIONS=yes DEEPSEEK_API_KEY="$key" "$repo/clds" --print standalone
[ "$(arg 1)" = --dangerously-skip-permissions ]
unset CLAI_STANDALONE

# clcd reaches Claude only after the local bridge is up. Mock Codex auth so
# this checks the flag without a subscription.
cat >"$tmp/bin/codex" <<'MOCK'
#!/bin/bash
set -euo pipefail
while IFS= read -r line; do
  id=$(printf '%s' "$line" | jq -r '.id // empty')
  method=$(printf '%s' "$line" | jq -r .method)
  [ -n "$id" ] || continue
  printf '{"id":"late-response","result":{"authMethod":null}}\n'
  case "$method" in
    initialize) jq -cn --arg id "$id" '{id:$id,result:{userAgent:"codex_cli_rs/test"}}';;
    getAuthStatus)
      payload=$(jq -cn --argjson exp "$(( $(date +%s) + 7200 ))" '{exp:$exp,"https://api.openai.com/auth":{chatgpt_account_id:"unit-test-account"}}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
      jq -cn --arg id "$id" --arg token "eyJhbGciOiJub25lIn0.$payload.dGVzdA" '{id:$id,result:{authMethod:"chatgpt",requiresOpenaiAuth:true,authToken:$token}}';;
  esac
done
MOCK
chmod 700 "$tmp/bin/codex"
run_clcd() {
  : >"$PERM_ARGS"
  CLAI_SKIP_PERMISSIONS=$1 "$repo/clcd" --print 'bridge permissions' >"$tmp/clcd-out" 2>"$tmp/clcd-err"
}
run_clcd 0
[ "$(arg 1)" = --print ]
[ "$(arg 2)" = 'bridge permissions' ]
run_clcd 1
[ "$(arg 1)" = --dangerously-skip-permissions ]
[ "$(arg 2)" = --print ]
: >"$PERM_ARGS"
if CLAI_SKIP_PERMISSIONS=maybe "$repo/clcd" --print x >"$tmp/clcd-out" 2>"$tmp/clcd-err"; then
  echo 'invalid clcd permission setting launched'
  exit 1
fi
grep -q 'CLAI_SKIP_PERMISSIONS must be 1 or 0' "$tmp/clcd-err"
[ ! -s "$PERM_ARGS" ]

printf 'PASS: permission bypass stays on by default and CLAI_SKIP_PERMISSIONS=0 omits it\n'
