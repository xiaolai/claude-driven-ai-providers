#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/clcd"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/provider-tests.XXXXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
cd "$test_dir"
mkdir -p filters
awk '/^cat >"\$runtime\/request.jq"/{p=1;next} p&&/^JQ$/{exit} p{print}' "$script" > filters/request.jq
awk '/^cat >"\$runtime\/stream.jq"/{p=1;next} p&&/^JQ$/{exit} p{print}' "$script" > filters/stream.jq
printf '{"mcp__long":"clcd_tool_0"}\n' > filters/names.json
printf '{"clcd_tool_0":"mcp__long"}\n' > filters/reverse.json
/bin/bash -n "$script"
shellcheck -S warning "$script"
cat > filters/input.json <<'JSON'
{"model":"gpt-6.1-sol","system":[{"type":"text","text":"test instructions"}],"messages":[{"role":"system","content":"midturn instructions"},{"role":"user","content":[{"type":"text","text":"Hi"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]},{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},{"type":"tool_use","id":"call_test","name":"mcp__long","input":{"path":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_test","is_error":true,"content":[{"type":"text","text":"missing"}]}]}],"tools":[{"name":"mcp__long","description":"read","input_schema":{"type":"object"}}],"tool_choice":{"type":"tool","name":"mcp__long","disable_parallel_tool_use":true}}
JSON
jq --arg model fallback --arg effort medium --slurpfile names filters/names.json -f filters/request.jq filters/input.json > filters/request.json
jq -e '.model=="gpt-6.1-sol" and .instructions=="test instructions" and .input[0].role=="developer" and .input[2].content[0].image_url=="data:image/png;base64,AA==" and .input[3].type=="function_call" and .input[3].name=="clcd_tool_0" and .input[4].output=="[Tool error]\nmissing" and .tools[0].name=="clcd_tool_0" and .tool_choice.name=="clcd_tool_0" and .parallel_tool_calls==false and .stream==true and .store==false' filters/request.json >/dev/null
printf '{"messages":[{"role":"user","content":[{"type":"unknown"}]}]}' > filters/bad.json
if jq --arg model test --arg effort medium --slurpfile names filters/names.json -f filters/request.jq filters/bad.json >/dev/null 2>&1; then echo 'unsupported content was accepted'; exit 1; fi
cat > filters/events <<'SSE'
data: {"type":"response.created","response":{"id":"resp_test"}}

data: {"type":"response.content_part.added","item_id":"msg1","content_index":0,"part":{"type":"output_text","text":""}}
data: {"type":"response.output_text.delta","item_id":"msg1","content_index":0,"delta":"Hello"}
data: {"type":"response.content_part.done","item_id":"msg1","content_index":0,"part":{"type":"output_text"}}
data: {"type":"response.output_item.added","item":{"id":"fc1","type":"function_call","call_id":"call1","name":"clcd_tool_0"}}
data: {"type":"response.function_call_arguments.delta","item_id":"fc1","delta":"{\"path\":\"a\"}"}
data: {"type":"response.output_item.done","item":{"id":"fc1","type":"function_call","call_id":"call1","name":"clcd_tool_0","arguments":"{\"path\":\"a\"}"}}
data: {"type":"response.completed","response":{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":30},"output_tokens":7}}}
SSE
jq -Rnj --arg model test --slurpfile names filters/reverse.json -f filters/stream.jq filters/events > filters/translated
sed -n 's/^data: //p' filters/translated | jq -se '.[0].type=="message_start" and .[-1].type=="message_stop" and ([.[]|select(.type=="content_block_start")|.index]==[0,1]) and ([.[]|select(.type=="content_block_stop")|.index]==[0,1]) and any(.[]; .content_block.name=="mcp__long") and any(.[]; .delta.text=="Hello") and any(.[]; .delta.stop_reason=="tool_use" and .usage.input_tokens==70 and .usage.output_tokens==7)' >/dev/null
if head -n 2 filters/events | jq -Rnj --arg model test --slurpfile names filters/reverse.json -f filters/stream.jq >/dev/null 2>&1; then echo 'truncated stream was accepted'; exit 1; fi
printf 'PASS: bash syntax, ShellCheck, request translation, tool/image history, streaming, usage, name mapping, unsupported input, truncated stream\n'
# socat can leave SIGPIPE ignored: a closed reader must stop output without spam.
awk '/^chunks\(\)/{p=1} p{print} p&&/^}$/{exit}' "$script" > filters/chunks.sh
/bin/bash -c 'set -o pipefail; trap "" PIPE; source "$1"; jot 2000 | chunks 2>"$2" | head -c 1 >/dev/null; test "${PIPESTATUS[1]}" -ne 0' bash "$PWD/filters/chunks.sh" "$PWD/filters/disconnect.stderr"
test ! -s filters/disconnect.stderr
printf 'PASS: disconnected reader stops chunk output without broken-pipe diagnostics\n'
for control in temperature top_p top_k output_format; do
  jq --arg control "$control" '.+{($control):1}' filters/input.json >filters/unsupported.json
  if jq --arg model test --arg effort medium --slurpfile names filters/names.json -f filters/request.jq filters/unsupported.json >/dev/null 2>&1; then echo "ignored unsupported control: $control"; exit 1; fi
done
jq '.+{stop_sequences:["stop"]}' filters/input.json >filters/unsupported.json
if jq --arg model test --arg effort medium --slurpfile names filters/names.json -f filters/request.jq filters/unsupported.json >/dev/null 2>&1; then echo 'ignored stop sequences'; exit 1; fi
jq '.+{output_config:{effort:"high"}}' filters/input.json | jq --arg model test --arg effort medium --slurpfile names filters/names.json -f filters/request.jq | jq -e '.reasoning.effort=="high"' >/dev/null
jq '.+{output_config:{effort:"high"}}' filters/input.json | jq --arg model test --arg effort low --arg effort_override true --slurpfile names filters/names.json -f filters/request.jq | jq -e '.reasoning.effort=="low"' >/dev/null
printf 'PASS: unsupported controls rejected; adaptive effort translated; explicit effort override honored\n'
printf 'data: {"type":"response.created","response":{"id":"refusal"}}\r\ndata: {"type":"response.content_part.added","item_id":"m","content_index":0,"part":{"type":"refusal","refusal":""}}\r\ndata: {"type":"response.refusal.delta","item_id":"m","content_index":0,"delta":"Cannot comply"}\r\ndata: {"type":"response.content_part.done","item_id":"m","content_index":0,"part":{"type":"refusal"}}\r\ndata: {"type":"response.completed","response":{"usage":{}}}\r\ndata: [DONE]\r\n' >filters/refusal
jq -Rnj --arg model test --slurpfile names filters/reverse.json -f filters/stream.jq filters/refusal | sed -n 's/^data: //p' | jq -se 'any(.[];.delta.text=="Cannot comply") and .[-1].type=="message_stop"' >/dev/null
for terminal in response.incomplete response.failed error; do
  printf 'data: {"type":"response.created","response":{"id":"terminal"}}\ndata: {"type":"%s","response":{"usage":{}}}\n' "$terminal" | jq -Rnj --arg model test --slurpfile names filters/reverse.json -f filters/stream.jq >filters/terminal
  if [ "$terminal" = response.incomplete ]; then grep -q '"stop_reason":"max_tokens"' filters/terminal; else grep -q 'event: error' filters/terminal; fi
done
printf 'PASS: CRLF framing, refusal text, incomplete/failed/error terminal events\n'
for requested in opus claude-opus-4-1 fable claude-fable-5-1 sonnet claude-3-5-sonnet haiku raw-provider-id;do
  case "$requested" in opus|claude-opus*|fable|claude-fable*) expected=provider-pro;;sonnet|claude-3-5-sonnet) expected=provider-standard;;haiku) expected=provider-fast;;*) expected=$requested;;esac
  jq --arg requested "$requested" '.model=$requested' filters/input.json | jq --arg model fallback --arg effort medium --argjson mapping '{"opus":"provider-pro","fable":"provider-pro","sonnet":"provider-standard","haiku":"provider-fast"}' --slurpfile names filters/names.json -f filters/request.jq | jq -e --arg expected "$expected" '.model==$expected' >/dev/null
done
printf 'PASS: Claude short/full model roles map correctly; explicit provider IDs pass through\n'
