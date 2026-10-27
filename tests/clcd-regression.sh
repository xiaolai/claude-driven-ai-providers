#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/clcd"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/provider-tests.XXXXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
cd "$test_dir"
mkdir -p hardening-bin filters
cat > hardening-bin/codex <<'MOCK'
#!/bin/bash
set -euo pipefail
while IFS= read -r line; do
  id=$(printf '%s' "$line" | jq -r '.id // empty')
  method=$(printf '%s' "$line" | jq -r .method)
  [ -n "$id" ] || continue
  printf '%s\n' "$id" >>"$CLCD_TEST_STATE/ids"
  printf '{"id":"late-response","result":{"authMethod":null}}\n'
  case "$method" in
    initialize) jq -cn --arg id "$id" '{id:$id,result:{userAgent:"codex_cli_rs/0.164.0"}}';;
    getAuthStatus)
      if printf '%s' "$line" | jq -e '.params.refreshToken==true' >/dev/null; then echo refreshed >>"$CLCD_TEST_STATE/refreshes"; fi
      payload=$(jq -cn --argjson exp "$(( $(date +%s) + 7200 ))" '{exp:$exp,"https://api.openai.com/auth":{chatgpt_account_id:"unit-test-account"}}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
      jq -cn --arg id "$id" --arg token "eyJhbGciOiJub25lIn0.$payload.dGVzdA" '{id:$id,result:{authMethod:"chatgpt",requiresOpenaiAuth:true,authToken:$token}}';;
  esac
done
MOCK
cat > hardening-bin/curl <<'MOCK'
#!/bin/bash
set -euo pipefail
route=false headers=''
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  [ "${args[$i]}" != 'https://chatgpt.com/backend-api/codex/responses' ] || route=true
  [ "${args[$i]}" != --dump-header ] || headers=${args[$((i+1))]}
done
if [ "$route" = false ]; then exec /usr/bin/curl "$@"; fi
config=$(cat)
[[ "$config" == *'Authorization: Bearer eyJ'* ]]
case "$CLCD_TEST_MODE" in
  quota) printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\n\r\n' >"$headers"; printf '{"error":{"message":"Subscription limit reached"}}'; exit;;
  context) printf 'HTTP/1.1 400 Bad Request\r\n\r\n' >"$headers"; printf '{"error":{"message":"Maximum context length exceeded"}}'; exit;;
  refresh) if [ ! -f "$CLCD_TEST_STATE/refused" ]; then touch "$CLCD_TEST_STATE/refused"; printf 'HTTP/1.1 401 Unauthorized\r\n\r\n' >"$headers"; printf '{"error":{"message":"expired"}}'; exit; fi;;
esac
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
printf 'data: {"type":"response.created","response":{"id":"resp_test"}}\n\n'
if [ "$CLCD_TEST_MODE" = disconnect ]; then
  trap 'echo stopped >>"$CLCD_TEST_STATE/stopped"' EXIT
  echo "$$" >"$CLCD_TEST_STATE/upstream-pid"

  trap 'exit 0' TERM
  printf 'data: {"type":"response.content_part.added","item_id":"m","content_index":0,"part":{"type":"output_text","text":""}}\n\n'
  for i in {1..1000}; do
    printf 'data: {"type":"response.output_text.delta","item_id":"m","content_index":0,"delta":"a long enough chunk to notice a closed downstream connection"}\n\n'
    sleep 0.01
  done
fi
printf 'data: {"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"CLCD_OK"}]}],"usage":{"input_tokens":10,"output_tokens":2}}}\n\n'
MOCK
cat > hardening-bin/claude <<'MOCK'
#!/bin/bash
set -euo pipefail
call() { printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_AUTH_TOKEN" | /usr/bin/curl --config - --silent --show-error --max-time 15 "$@"; }
[ "$ANTHROPIC_MODEL" = legacy-codex ]
[ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" = 900001 ]
[ "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" = 675000 ]
case "$CLCD_TEST_MODE" in
 quota|context)
  status=$(call -D "$CLCD_TEST_STATE/headers" -o "$CLCD_TEST_STATE/body" -w '%{http_code}' -H 'Content-Type: application/json' --data '{"stream":true,"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages")
  if [ "$CLCD_TEST_MODE" = quota ]; then
    [ "$status" = 429 ]; tr -d '\r' <"$CLCD_TEST_STATE/headers" | grep -q '^Retry-After: 7$'
    jq -e '.error.type=="rate_limit_error"' "$CLCD_TEST_STATE/body" >/dev/null
  else
    [ "$status" = 400 ]; jq -e '.error.type=="invalid_request_error" and (.error.message|startswith("prompt is too long:"))' "$CLCD_TEST_STATE/body" >/dev/null
  fi;;
 disconnect)
  (call --no-buffer -H 'Content-Type: application/json' --data '{"stream":true,"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages" 2>/dev/null | head -c 100 >/dev/null) || true
  for i in {1..100}; do pid=$(cat "$CLCD_TEST_STATE/upstream-pid"); kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  ! kill -0 "$pid" 2>/dev/null;;
esac
MOCK
chmod 700 hardening-bin/*
export CLCD_MODEL=legacy-codex CLAI_CODEX_MODEL=ignored CLCD_CONTEXT_TOKENS=900001 CLAI_CODEX_CONTEXT=500000
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
for mode in quota context refresh disconnect; do
  state=$(mktemp -d "$PWD/hardening-state.XXXXXXXX")
  if [ "$mode" = refresh ]; then
    CLCD_TEST_STATE="$state" CLCD_TEST_MODE="$mode" PATH="$PWD/hardening-bin:$PATH" "$script" --check >"$state/stdout" 2>"$state/stderr"
    test "$(wc -l <"$state/refreshes" | tr -d ' ')" = 1
  else
    CLCD_TEST_STATE="$state" CLCD_TEST_MODE="$mode" PATH="$PWD/hardening-bin:$PATH" "$script" >"$state/stdout" 2>"$state/stderr"
  fi
  if grep -q 'Broken pipe' "$state/stderr"; then cat "$state/stderr"; exit 1; fi
  test "$(sort "$state/ids" | uniq -d | wc -l | tr -d ' ')" = 0
  echo "PASS: integration $mode, unique RPC IDs, stale replies ignored"
done
# The descriptor lock disappears on process death, without deleting a lock file.
lock="$PWD/filters/cancel.lock"
rm -f "$lock.ready"

( exec 9>"$lock"; lockf -s -t 1 9; echo ready >"$lock.ready"; exec sleep 60 ) &
lock_owner=$!
for _attempt in {1..50}; do [ ! -f "$lock.ready" ] || break; sleep 0.02; done
test -f "$lock.ready"
kill "$lock_owner"; wait "$lock_owner" 2>/dev/null || true
( exec 9>"$lock"; lockf -s -t 1 9 )
echo 'PASS: authentication lock releases on process death'
