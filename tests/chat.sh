#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-chat.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/events" <<'SSE'
data: {"id":"chat_fixture","choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_one","function":{"name":"read_file","arguments":"{\"path\":"},"extra_content":{"google":{"thought_signature":"fixture-signature-A"}}},{"index":1,"id":"call_two","function":{"name":"read_file","arguments":"{\"path\":\"b\"}"}}]},"finish_reason":null}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a\"}"}}]},"finish_reason":null}]}
data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":123,"completion_tokens":24}}
data: [DONE]
SSE
jq -Rnj --arg model fixture-model -f "$repo/adapters/chat-stream.jq" "$tmp/events" >"$tmp/normalized"
sed -n 's/^cache: //p' "$tmp/normalized"|jq -s 'map({key:.id,value:.})|from_entries' >"$tmp/metadata"
sed -n 's/^data: //p' "$tmp/normalized"|jq -se 'any(.[];.type=="response.completed" and .response.usage.input_tokens==123 and (.response.output|length)==2) and ([.[]|select(.type=="response.output_item.done")]|length)==2' >/dev/null
cat >"$tmp/request" <<'JSON'
{"model":"fixture-model","instructions":"test","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"read"}]},{"type":"function_call","call_id":"call_one","name":"read_file","arguments":"{\"path\":\"a\"}"},{"type":"function_call","call_id":"call_two","name":"read_file","arguments":"{\"path\":\"b\"}"},{"type":"function_call_output","call_id":"call_one","output":"first"},{"type":"function_call_output","call_id":"call_two","output":"second"}],"tools":[],"reasoning":{"effort":"high"},"max_output_tokens":512}
JSON
jq --arg provider gemini --slurpfile metadata "$tmp/metadata" -f "$repo/adapters/chat-request.jq" "$tmp/request" >"$tmp/chat-request"
jq -e '(.messages[2].tool_calls|length)==2 and .messages[2].tool_calls[0].extra_content.google.thought_signature=="fixture-signature-A" and .messages[2].tool_calls[1].extra_content=={} and .messages[3].tool_call_id=="call_one" and .reasoning_effort=="high" and .max_tokens==512' "$tmp/chat-request" >/dev/null
printf '{}\n' >"$tmp/missing"
if jq --arg provider gemini --slurpfile metadata "$tmp/missing" -f "$repo/adapters/chat-request.jq" "$tmp/request" >/dev/null 2>&1;then echo 'missing signature metadata accepted';exit 1;fi
if head -n 1 "$tmp/events"|jq -Rnj --arg model fixture-model -f "$repo/adapters/chat-stream.jq" >/dev/null 2>&1;then echo 'incomplete chat stream accepted';exit 1;fi
printf 'PASS: parallel chat tools, fragmented arguments/signature metadata, usage, replay grouping, missing metadata and truncated-stream rejection\n'
awk '{printf "%s\r\n",$0}' "$tmp/events" | jq -Rnj --arg model fixture-model -f "$repo/adapters/chat-stream.jq" >"$tmp/crlf"
cmp "$tmp/normalized" "$tmp/crlf"
printf 'PASS: Chat LF/CRLF equivalence\n'
