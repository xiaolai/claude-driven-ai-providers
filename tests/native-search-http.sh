#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clcd-search-http.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config"
# Reuse the existing synthetic Codex RPC credential fixture (no real account).
awk '/^cat > hardening-bin\/codex / {p=1;next} p&&/^MOCK$/ {exit} p {print}' "$repo/tests/clcd-regression.sh" >"$tmp/bin/codex"
jq -nr '
 "Docs citeturn0search0" as $text |
 [{type:"response.created",response:{id:"r"}},
 {type:"response.output_item.done",output_index:0,item:{id:"ws",type:"web_search_call",status:"completed",action:{type:"search",query:"Search docs"}}},
 {type:"response.output_item.done",output_index:1,item:{id:"m",type:"message",content:[{type:"output_text",text:$text,annotations:[{type:"url_citation",start_index:5,end_index:($text|length),url:"https://example.com/docs"}]}]}},
 {type:"response.completed",response:{id:"r",usage:{input_tokens:10,output_tokens:5}}}][]|"data: "+tojson+"\n"
' >"$tmp/fixture"
cat >"$tmp/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
args=("$@");route=false;headers='';request=''
for ((i=0;i<${#args[@]};i++));do
 [ "${args[$i]}" != 'https://chatgpt.com/backend-api/codex/responses' ] || route=true
 [ "${args[$i]}" != --dump-header ] || headers=${args[$((i+1))]}
 [ "${args[$i]}" != --data-binary ] || request=${args[$((i+1))]#@}
done
if [ "$route" = false ];then exec /usr/bin/curl "$@";fi
cat >/dev/null
jq -e '.tools==[{type:"web_search",external_web_access:true}]' "$request" >/dev/null
echo called >>"$CLCD_TEST_STATE/called"
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
case "$SEARCH_TEST_MODE" in
 disconnect)
  echo "$$" >"$CLCD_TEST_STATE/upstream-pid"
  trap 'echo stopped >"$CLCD_TEST_STATE/stopped"' EXIT
  trap 'exit 0' TERM
  while :;do printf ': waiting\n';sleep 0.1;done;;
 oversized) head -c 8388609 /dev/zero | tr '\0' ' ';exit;;
 delayed) sleep 2.1;;
 nosearch) grep -v '"id":"ws"' "$SEARCH_FIXTURE";exit;;
esac
cat "$SEARCH_FIXTURE"
case "$SEARCH_TEST_MODE" in
 malformed) printf 'data: {bad}\n';;
 duplicate) tail -n 2 "$SEARCH_FIXTURE";;
 curlerror) exit 18;;
esac
MOCK
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
call() { printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_AUTH_TOKEN" | /usr/bin/curl --config - --silent --max-time 8 "$@"; }
body='{"messages":[{"role":"user","content":"Search docs"}],"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":8}],"tool_choice":{"type":"auto"}}'
if [ "$SEARCH_TEST_MODE" = disconnect ];then
 (call --max-time 1 -H 'Content-Type: application/json' --data "$body" "$ANTHROPIC_BASE_URL/v1/messages" >/dev/null) || true
 for _ in {1..50};do [ -f "$CLCD_TEST_STATE/stopped" ] && break;sleep 0.1;done
 test -f "$CLCD_TEST_STATE/stopped";exit
fi
for stream in true false;do
 input=$(printf '%s' "$body"|jq -c --argjson stream "$stream" '.stream=$stream')
 status=$(call -o "$CLCD_TEST_STATE/body" -w '%{http_code}' -H 'Content-Type: application/json' --data "$input" "$ANTHROPIC_BASE_URL/v1/messages")
 case "$SEARCH_TEST_MODE" in
  success|delayed)
   [ "$status" = 200 ]
   if [ "$stream" = true ];then
    sed -n 's/^data: //p' "$CLCD_TEST_STATE/body" | jq -se '([.[]|select(.type=="message_stop")]|length)==1 and any(.[];.delta.text=="Docs [1](https://example.com/docs)")' >/dev/null
   else jq -e '([.content[]|select(.type=="text")][0].text)=="Docs [1](https://example.com/docs)" and .usage.server_tool_use.web_search_requests==1' "$CLCD_TEST_STATE/body" >/dev/null;fi;;
  strict) [ "$status" = 400 ];test ! -f "$CLCD_TEST_STATE/called";;
  *) [ "$status" = 502 ];jq -e '.type=="error"' "$CLCD_TEST_STATE/body" >/dev/null;! grep -q 'message_stop' "$CLCD_TEST_STATE/body";;
 esac
done
MOCK
chmod 700 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" CLAI_CLAUDE_BIN="$tmp/bin/claude" XDG_CONFIG_HOME="$tmp/config"
export CLCD_WEB_SEARCH=live CLCD_WEB_SEARCH_UNBOUNDED=true SEARCH_FIXTURE="$tmp/fixture"
for mode in success delayed malformed duplicate curlerror nosearch oversized strict disconnect;do
 state=$(mktemp -d "$tmp/state.XXXXXXXX")
 unbounded=true;[ "$mode" != strict ] || unbounded=false
 CLCD_TEST_STATE="$state" SEARCH_TEST_MODE="$mode" CLCD_WEB_SEARCH_UNBOUNDED="$unbounded" "$repo/clcd"
 printf 'PASS: native search HTTP %s\n' "$mode"
done
