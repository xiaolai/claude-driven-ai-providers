#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-api.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache" CLAI_TEST_STATE="$tmp/state"
mkdir -p "$HOME" "$tmp/bin" "$CLAI_TEST_STATE"
export CLAI_TEST_KEY
CLAI_TEST_KEY=$(openssl rand -hex 16)
cat >"$tmp/bin/codex" <<'MOCK'
#!/bin/bash
touch "$CLAI_TEST_STATE/codex-was-started"
exit 99
MOCK
cat >"$tmp/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
route=false headers='' request='';args=("$@")
for ((i=0;i<${#args[@]};i++));do
  case "${args[$i]}" in https://api.openai.com/v1/responses|https://api.x.ai/v1/responses|https://generativelanguage.googleapis.com/v1beta/openai/chat/completions|http://127.0.0.1:19999/v1/chat/completions) route=true;;esac
  [ "${args[$i]}" != --dump-header ] || headers=${args[$((i+1))]}
  [ "${args[$i]}" != --data-binary ] || request=${args[$((i+1))]#@}
  if [ "${args[$i]}" = --proto ];then
    if [ "$CLAI_TEST_PHASE" = local ];then [ "${args[$((i+1))]}" = '=https,http' ];else [ "${args[$((i+1))]}" = '=https' ];fi
  fi
  [[ "${args[$i]}" != *"$CLAI_TEST_KEY"* ]]
done
if [ "$route" = false ];then exec /usr/bin/curl "$@";fi
config=$(cat)
if [ "$CLAI_TEST_PHASE" = local ];then [[ "$config" != *Authorization* ]];else [[ "$config" == *"Authorization: Bearer $CLAI_TEST_KEY"* ]];fi
echo called >>"$CLAI_TEST_STATE/backend-calls"
sleep "${CLAI_TEST_HEADER_DELAY:-0}"
if [ "$CLAI_TEST_PHASE" = error ];then
  printf 'HTTP/1.1 403 Forbidden\r\n\r\n' >"$headers"
  printf '%s' "$CLAI_TEST_KEY" | jq -Rs '{error:{message:("Invalid key "+.)}}'
  exit
fi
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
if [ "$CLAI_TEST_PHASE" = responses ] || [ "$CLAI_TEST_PHASE" = mapping ] || [ "$CLAI_TEST_PHASE" = grok ];then
  if [ "$CLAI_TEST_PHASE" = mapping ];then jq -e '.model=="fixture-pro"' "$request" >/dev/null;fi
  jq -e '.store==false and .stream==true and .max_output_tokens>0' "$request" >/dev/null
  if [ "$CLAI_TEST_PHASE" = grok ];then jq -e 'has("reasoning")|not' "$request" >/dev/null;fi
  printf 'data: {"type":"response.created","response":{"id":"resp_test"}}\n\ndata: {"type":"response.content_part.added","item_id":"m","content_index":0,"part":{"type":"output_text","text":""}}\n\ndata: {"type":"response.output_text.delta","item_id":"m","content_index":0,"delta":"API_OK"}\n\ndata: {"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"API_OK"}]}],"usage":{}}}\n\n'
elif [ "$CLAI_TEST_PHASE" = malformed ];then
  printf 'data: {broken-json}\n\n'
elif [ "$CLAI_TEST_PHASE" = disconnect ];then
  echo "$$" >"$CLAI_TEST_STATE/upstream-pid"
  trap 'exit 0' TERM
  for _attempt in {1..1000}; do
    printf 'data: {"id":"disconnect","choices":[{"delta":{"content":"a long enough chunk to trigger downstream cancellation promptly"},"finish_reason":null}]}\n\n'
    sleep 0.01
  done
elif [ "$CLAI_TEST_PHASE" = refusal ];then
  printf 'data: {"type":"response.created","response":{"id":"refusal"}}\n\ndata: {"type":"response.completed","response":{"id":"refusal","status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Cannot comply"}]}],"usage":{}}}\n\n'
elif [ "$CLAI_TEST_PHASE" = first ];then
  cat <<'SSE'
data: {"id":"chat_first","choices":[{"delta":{"tool_calls":[{"index":0,"id":"gemini_call","function":{"name":"read_file","arguments":"{\"path\":"},"extra_content":{"google":{"thought_signature":"fixture-private-signature"}}},{"index":1,"id":"parallel_call","function":{"name":"read_file","arguments":"{\"path\":\"b\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

SSE
else
  if [ "$CLAI_TEST_PHASE" = replay ];then jq -e 'any(.messages[];.tool_calls[0].extra_content.google.thought_signature=="fixture-private-signature" and (.tool_calls|length)==2 and .tool_calls[1].extra_content=={})' "$request" >/dev/null;fi
  printf 'data: {"id":"chat_reply","choices":[{"delta":{"content":"CHAT_OK"},"finish_reason":null}]}\n\n'
  if [ "${CLAI_TEST_STREAM:-false}" = true ] && [ "$CLAI_TEST_PHASE" = local ];then
    for _attempt in {1..100}; do [ ! -f "$CLAI_TEST_STATE/client-saw-text" ] || break; sleep 0.05; done
    test -f "$CLAI_TEST_STATE/client-saw-text"
  fi
  printf 'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":2}}\n\ndata: [DONE]\n\n'
fi
MOCK
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
call() { printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_AUTH_TOKEN" | /usr/bin/curl --config - --silent --show-error --max-time 15 -H 'Content-Type: application/json' "$@"; }
collect_chat() {
  local line entry call_id digest
  while IFS= read -r line; do
    if [[ "$line" == 'data: '* ]];then
      entry=${line#data: }
      if printf '%s' "$entry"|jq -e '.type=="content_block_start" and .content_block.type=="tool_use"' >/dev/null;then
        call_id=$(printf '%s' "$entry"|jq -r .content_block.id)
        digest=$(printf '%s\n%s' fixture-gemini "$call_id"|openssl dgst -sha256|awk '{print $NF}')
        test -f "$XDG_CACHE_HOME/claude-driven-ai-providers/gemini/$digest.json"
      fi
      if printf '%s' "$entry"|jq -e '.delta.text=="CHAT_OK"' >/dev/null;then touch "$CLAI_TEST_STATE/client-saw-text";fi
    fi
    printf '%s\n' "$line"
  done >"$CLAI_TEST_STATE/chat-stream"
  sed -n 's/^data: //p' "$CLAI_TEST_STATE/chat-stream"|jq -se '.[-1].type=="message_stop" and (any(.[];.type=="error")|not)' >/dev/null
  sed -n 's/^data: //p' "$CLAI_TEST_STATE/chat-stream"|jq -s '. as $events |
    {content:([$events[]|select(.type=="content_block_start" and .content_block.type=="tool_use")|. as $start|
      .content_block+{input:([$events[]|select(.type=="content_block_delta" and .index==$start.index)|.delta.partial_json//empty]|join("")|fromjson)}] +
      ([$events[]|select(.type=="content_block_delta")|.delta.text//empty]|join("")|if .=="" then [] else [{type:"text",text:.}] end))}'
}
if [ "$CLAI_TEST_PHASE" = header_timeout ];then
  status=$(call -o "$CLAI_TEST_STATE/timeout" -w '%{http_code}' --data '{"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages")
  [ "$status" = 502 ];jq -e '.error.message|contains("headers")' "$CLAI_TEST_STATE/timeout" >/dev/null
elif [ "$CLAI_TEST_PHASE" = disconnect ];then
  (call --no-buffer --data '{"stream":true,"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages" 2>/dev/null|head -c 100 >/dev/null) || true
  for _attempt in {1..100};do pid=$(cat "$CLAI_TEST_STATE/upstream-pid");kill -0 "$pid" 2>/dev/null||break;sleep 0.05;done
  ! kill -0 "$pid" 2>/dev/null
elif [ "$CLAI_TEST_PHASE" = malformed ];then
  if [ "$CLAI_TEST_STREAM" = true ];then
    call --data '{"stream":true,"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages" >"$CLAI_TEST_STATE/bad-stream"
    sed -n 's/^data: //p' "$CLAI_TEST_STATE/bad-stream"|jq -se 'any(.[];.type=="error" and (.error.message|contains("Chat"))) and (any(.[];.type=="message_stop")|not)' >/dev/null
  else
    status=$(call -o "$CLAI_TEST_STATE/bad" -w '%{http_code}' --data '{"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages")
    [ "$status" = 502 ];jq -e '.error.message|contains("Chat")' "$CLAI_TEST_STATE/bad" >/dev/null
  fi
elif [ "$CLAI_TEST_PHASE" = refusal ];then
  call --data '{"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages"|jq -e '.content[0].text=="Cannot comply"' >/dev/null
elif [ "$CLAI_TEST_PHASE" = error ];then
  status=$(call -o "$CLAI_TEST_STATE/error" -w '%{http_code}' --data '{"max_tokens":512,"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages")
  [ "$status" = 403 ]
  ! grep -q "$CLAI_TEST_KEY" "$CLAI_TEST_STATE/error"
  jq -e '.error.message|contains("<redacted>")' "$CLAI_TEST_STATE/error" >/dev/null
elif [ "$CLAI_TEST_PHASE" = mapping ];then
  [ "$ANTHROPIC_DEFAULT_OPUS_MODEL" = fixture-pro ]
  [ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = fixture-mini ]
  [ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" = 128000 ]
  [ "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" = 96000 ]
  call --data '{"model":"claude-opus-4-1","max_tokens":512,"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages"|jq -e '.content[0].text=="API_OK"' >/dev/null
elif [ "$CLAI_TEST_PHASE" = responses ] || [ "$CLAI_TEST_PHASE" = grok ];then
  call --data '{"stream":true,"max_tokens":512,"messages":[{"role":"user","content":"test"}]}' "$ANTHROPIC_BASE_URL/v1/messages" >"$CLAI_TEST_STATE/response-stream"
  sed -n 's/^data: //p' "$CLAI_TEST_STATE/response-stream"|jq -se 'any(.[];.delta.text=="API_OK") and .[-1].type=="message_stop"' >/dev/null
elif [ "$CLAI_TEST_PHASE" = first ];then
  request=$(jq -cn --argjson stream "${CLAI_TEST_STREAM:-false}" '{stream:$stream,max_tokens:512,messages:[{role:"user",content:"read"}],tools:[{name:"read_file",input_schema:{type:"object",properties:{path:{type:"string"}}}}]}')
  if [ "${CLAI_TEST_STREAM:-false}" = true ];then call --no-buffer --data "$request" "$ANTHROPIC_BASE_URL/v1/messages"|collect_chat >"$CLAI_TEST_STATE/first"
  else call --data "$request" "$ANTHROPIC_BASE_URL/v1/messages" >"$CLAI_TEST_STATE/first";fi
  jq -e '.content[0].type=="tool_use" and .content[0].id=="gemini_call"' "$CLAI_TEST_STATE/first" >/dev/null
elif [ "$CLAI_TEST_PHASE" = local ];then
  request=$(jq -cn --argjson stream "${CLAI_TEST_STREAM:-false}" '{stream:$stream,max_tokens:512,messages:[{role:"user",content:"test"}]}')
  if [ "${CLAI_TEST_STREAM:-false}" = true ];then call --no-buffer --data "$request" "$ANTHROPIC_BASE_URL/v1/messages"|collect_chat|jq -e '.content[0].text=="CHAT_OK"' >/dev/null
  else call --data "$request" "$ANTHROPIC_BASE_URL/v1/messages"|jq -e '.content[0].text=="CHAT_OK"' >/dev/null;fi
else
  jq -cn --argjson stream "${CLAI_TEST_STREAM:-false}" --slurpfile prior "$CLAI_TEST_STATE/first" '{stream:$stream,max_tokens:512,messages:[{role:"user",content:"read"},{role:"assistant",content:$prior[0].content},{role:"user",content:[$prior[0].content[]|select(.type=="tool_use")|{type:"tool_result",tool_use_id:.id,content:"file data"}]}]}' >"$CLAI_TEST_STATE/replay"
  status=$(call -o "$CLAI_TEST_STATE/reply" -w '%{http_code}' --data-binary "@$CLAI_TEST_STATE/replay" "$ANTHROPIC_BASE_URL/v1/messages")
  if [ "$CLAI_TEST_PHASE" = missing ];then [ "$status" = 400 ];jq -e '.error.message|contains("metadata")' "$CLAI_TEST_STATE/reply" >/dev/null
  else [ "$status" = 200 ];if [ "${CLAI_TEST_STREAM:-false}" = true ];then collect_chat <"$CLAI_TEST_STATE/reply" >"$CLAI_TEST_STATE/collected";jq -e '.content[0].text=="CHAT_OK"' "$CLAI_TEST_STATE/collected" >/dev/null
    else jq -e '.content[0].text=="CHAT_OK"' "$CLAI_TEST_STATE/reply" >/dev/null;fi;fi
fi
MOCK
chmod 700 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export OPENAI_API_KEY="$CLAI_TEST_KEY" GEMINI_API_KEY="$CLAI_TEST_KEY" XAI_API_KEY="$CLAI_TEST_KEY"
CLAI_TEST_PHASE=responses CLAI_OPENAI_MODEL=fixture-openai "$repo/clai" run openai
CLAI_TEST_PHASE=grok "$repo/clai" run grok
CLAI_TEST_PHASE=error "$repo/clai" run openai
CLAI_TEST_PHASE=refusal "$repo/clai" run openai
CLAI_TEST_PHASE=header_timeout CLAI_TEST_HEADER_DELAY=2 CLCD_HEADER_TIMEOUT=1 "$repo/clai" run openai
CLAI_TEST_PHASE=responses CLAI_TEST_HEADER_DELAY=2 CLCD_HEADER_TIMEOUT=4 "$repo/clai" run openai
[ ! -e "$CLAI_TEST_STATE/codex-was-started" ]
CLAI_TEST_PHASE=first CLAI_GEMINI_MODEL=fixture-gemini "$repo/clai" run gemini
CLAI_TEST_PHASE=replay CLAI_GEMINI_MODEL=fixture-gemini "$repo/clai" run gemini
calls=$(wc -l <"$CLAI_TEST_STATE/backend-calls")
CLAI_TEST_PHASE=missing CLAI_GEMINI_MODEL=different-gemini "$repo/clai" run gemini
[ "$(wc -l <"$CLAI_TEST_STATE/backend-calls")" = "$calls" ]
"$repo/clai" config set local base_url http://127.0.0.1:19999 >/dev/null
"$repo/clai" config set local protocol chat >/dev/null
"$repo/clai" config set local model fixture-local >/dev/null
CLAI_TEST_PHASE=local "$repo/clai" run local
"$repo/clai" config set ollama base_url http://127.0.0.1:19999 >/dev/null
"$repo/clai" config set ollama protocol chat >/dev/null
"$repo/clai" config set ollama model fixture-local >/dev/null
CLAI_TEST_PHASE=local "$repo/clai" run ollama
export CLAI_TEST_STREAM=true
rm -rf -- "$XDG_CACHE_HOME/claude-driven-ai-providers/gemini"
CLAI_TEST_PHASE=first CLAI_GEMINI_MODEL=fixture-gemini "$repo/clai" run gemini
CLAI_TEST_PHASE=replay CLAI_GEMINI_MODEL=fixture-gemini "$repo/clai" run gemini
rm -f "$CLAI_TEST_STATE/client-saw-text"
CLAI_TEST_PHASE=local "$repo/clai" run local
for stream in false true;do CLAI_TEST_PHASE=malformed CLAI_TEST_STREAM=$stream "$repo/clai" run gemini;done
CLAI_TEST_PHASE=disconnect "$repo/clai" run gemini
mkdir -p "$XDG_CONFIG_HOME/claude-driven-ai-providers/providers"
printf '%s\n' '{"model":"fixture-standard","mapping":{"strategy":"balanced","models":{"opus":"fixture-pro","fable":"fixture-pro","sonnet":"fixture-standard","haiku":"fixture-mini","subagent":"fixture-mini","custom":"fixture-standard"},"bounds":{"context_tokens":128000,"output_tokens":8192}}}' >"$XDG_CONFIG_HOME/claude-driven-ai-providers/providers/openai.json"
chmod 600 "$XDG_CONFIG_HOME/claude-driven-ai-providers/providers/openai.json"
CLAI_TEST_PHASE=mapping "$repo/clai" run openai
CLAI_TEST_PHASE=mapping CLCD_TRANSPORT=openai "$repo/clcd"
printf 'PASS: managed and standalone bridge role mapping, bounds and upstream selection\n'
printf 'PASS: Chat streaming parallel tools/cache-before-forward/restart replay/incremental text/disconnect/parser errors; collected refusal and configurable header deadline\n'
printf 'PASS: OpenAI/Grok Responses without Codex; API error redaction; Gemini replay across bridge restarts; model-scoped missing-cache rejection; local chat without unrelated credential leakage\n'
