#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-models.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" XDG_DATA_HOME="$tmp/data" MODEL_TEST_STATE="$tmp/state"
mkdir -p "$HOME" "$tmp/bin" "$MODEL_TEST_STATE"
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLCD_MODEL CLCD_EFFORT CLCD_CONTEXT_TOKENS
export OPENAI_API_KEY=fixture-probe-key GEMINI_API_KEY=fixture-probe-key DEEPSEEK_API_KEY=fixture-probe-key
cat >"$tmp/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
file=''; args=("$@"); url=${!#}
for ((i=0;i<${#args[@]};i++));do [ "${args[$i]}" != -o ] || file=${args[$((i+1))]};done
if [ -z "$file" ];then exec /usr/bin/curl "$@";fi
if [ "${MODEL_TEST_MALFORMED:-false}" = true ];then printf '{"data":{}}' >"$file";printf 200;exit;fi
if [ "${MODEL_TEST_PAGING:-false}" = true ];then printf '{"data":[],"has_more":true}' >"$file";printf 200;exit;fi
if [ "${MODEL_TEST_LOOP:-false}" = true ];then printf '{"models":[],"nextPageToken":"loop"}' >"$file";printf 200;exit;fi
if [ "${MODEL_TEST_FALLBACK:-false}" = true ] && [[ "$url" == */api/v1/models ]];then printf '{}' >"$file";printf 404;exit;fi
echo "$url" >>"$MODEL_TEST_STATE/requests"
if [ "${MODEL_TEST_FAIL:-false}" = true ];then printf '{"error":{"message":"blocked"}}' >"$file";printf 403;exit;fi
if [[ "$url" == *generativelanguage* ]];then
 if [[ "$url" == *pageToken=* ]];then
  printf '{"models":[{"name":"models/gemini-flash-3","inputTokenLimit":128000,"outputTokenLimit":8192,"supportedGenerationMethods":["generateContent"]}]}' >"$file"
 else
  printf '{"models":[{"name":"models/gemini-pro-3","inputTokenLimit":1000000,"supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-1","supportedGenerationMethods":["embedContent"]},{"name":"models/deep-research-pro-preview-12-2025","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"page/2+"}' >"$file"
 fi
elif [[ "$url" == */api/v1/models ]];then
 printf '{"models":[{"key":"local-pro","type":"llm","max_context_length":128000,"loaded_instances":[{"config":{"context_length":8192}}],"capabilities":{"trained_for_tool_use":true,"vision":false}},{"key":"local-fast","type":"llm","loaded_instances":[],"capabilities":{"trained_for_tool_use":false}}]}' >"$file"
else
 cat >"$file" <<'JSON'
{"data":[{"id":"coding-pro-2","context_window":1000000,"max_output_tokens":32768,"capabilities":{"text":true,"tools":true}},{"id":"coding-standard-2","isDefault":true,"context_window":500000,"capabilities":{"text":true,"tools":true}},{"id":"coding-mini-2","context_window":128000,"max_output_tokens":8192,"capabilities":{"text":true,"tools":true}},{"id":"text-embedding-3"},{"id":"audio-only-1","capabilities":{"text":false}},{"id":"mystery-1"}]}
JSON
fi
printf 200
MOCK
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
[ "${MODEL_TEST_TOOL_FAIL:-false}" != true ] || exit 1
echo invoked >>"$MODEL_TEST_STATE/generations"
if [[ "${!#}" == *CLAI_OK_* ]];then
 [[ "${!#}" =~ CLAI_OK_[0-9a-f]+ ]]
 jq -cn --arg result "${BASH_REMATCH[0]}" '{is_error:false,result:$result,num_turns:2}'
else
 [ "$ANTHROPIC_DEFAULT_OPUS_MODEL" = coding-pro-2 ]
 [ "$ANTHROPIC_DEFAULT_FABLE_MODEL" = coding-pro-2 ]
 [ "$ANTHROPIC_DEFAULT_SONNET_MODEL" = coding-standard-2 ]
 [ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = coding-mini-2 ]
 [ "$CLAUDE_CODE_SUBAGENT_MODEL" = coding-mini-2 ]
 [ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" = 128000 ]
 [ "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" = 96000 ]
fi
MOCK
cat >"$tmp/bin/codex" <<'MOCK'
#!/bin/bash
set -euo pipefail
while IFS= read -r line;do
 id=$(printf '%s' "$line"|jq -r '.id//empty');[ -n "$id" ] || continue
 printf '%s\n' "$id" >>"$MODEL_TEST_STATE/rpc-ids"
 printf '{"id":"stale","result":{}}\n'
 method=$(printf '%s' "$line"|jq -r .method)
 if [ "$method" = initialize ];then jq -cn --arg id "$id" '{id:$id,result:{}}'
 elif [ "$method" = account/read ];then jq -cn --arg id "$id" '{id:$id,result:{account:{type:"chatgpt",email:"fixture@example.invalid",planType:"pro"}}}'
 elif [ "$method" = model/list ];then
  if printf '%s' "$line"|jq -e '.params.cursor!=null' >/dev/null;then
   jq -cn --arg id "$id" '{id:$id,result:{data:[{model:"coding-mini-2",inputModalities:["text"],supportedReasoningEfforts:[{reasoningEffort:"low"}]}],nextCursor:null}}'
  else jq -cn --arg id "$id" '{id:$id,result:{data:[{model:"coding-pro-2",isDefault:true,inputModalities:["text","image"],supportedReasoningEfforts:[{reasoningEffort:"high"}]}],nextCursor:"next"}}';fi
 fi
done
MOCK
chmod 700 "$tmp/bin/"*;export PATH="$tmp/bin:$PATH"
printf '[{"id":"unknown-limit","context_window":0,"max_output_tokens":1.5}]' | jq --arg kind openai -f "$repo/adapters/model-inventory.jq" | jq -e 'length==1 and .[0].input_tokens==null and .[0].output_tokens==null' >/dev/null
"$repo/clai" config set openai model coding-standard-2 >/dev/null
"$repo/clai" probe openai >"$tmp/inventory"
jq -e '.state=="listed" and .complete and (.models|length)==6 and any(.models[];.id=="mystery-1" and .capabilities.tools==null) and any(.models[];.id=="text-embedding-3" and .eligible==false)' "$tmp/inventory" >/dev/null
test ! -e "$MODEL_TEST_STATE/generations"
"$repo/clai" probe gemini >"$tmp/gemini"
jq -e '(.models|length)==4 and any(.models[];.id=="gemini-flash-3" and .input_tokens==128000) and all(.models[];.id|startswith("models/")|not)' "$tmp/gemini" >/dev/null
grep -q 'pageToken=page%2F2%2B' "$MODEL_TEST_STATE/requests"
"$repo/clai" map gemini --strategy balanced --cached | jq -e '.models.opus=="gemini-pro-3"' >/dev/null
"$repo/clai" probe codex >"$tmp/codex"
jq -e '(.models|length)==2 and any(.models[];.capabilities.vision==true)' "$tmp/codex" >/dev/null
[ "$(sort "$MODEL_TEST_STATE/rpc-ids"|uniq -d|wc -l|tr -d ' ')" = 0 ]
"$repo/clai" probe lmstudio >"$tmp/lm"
jq -e 'any(.models[];.id=="local-pro" and .input_tokens==8192 and .capabilities.tools==true and .capabilities.vision==false) and any(.models[];.id=="local-fast" and .eligible==false)' "$tmp/lm" >/dev/null
"$repo/clai" map openai --strategy balanced >"$tmp/proposal"
jq -e '.models.opus=="coding-pro-2" and .models.sonnet=="coding-standard-2" and .models.haiku=="coding-mini-2" and .bounds.context_tokens==128000 and .verification=="unverified"' "$tmp/proposal" >/dev/null
for strategy in single quality economy;do
 "$repo/clai" map openai --strategy "$strategy" >"$tmp/strategy"
 case "$strategy" in single) expected=coding-standard-2;;quality) expected=coding-pro-2;;economy) expected=coding-mini-2;;esac
 jq -e --arg expected "$expected" 'all(.models[];.==$expected)' "$tmp/strategy" >/dev/null
done
if "$repo/clai" map openai --strategy manual --opus text-embedding-3 --apply >/dev/null 2>&1;then echo 'non-chat mapping accepted';exit 1;fi
"$repo/clai" map openai --strategy manual --opus coding-pro-2 --haiku coding-mini-2 >"$tmp/manual"
jq -e '.models.opus=="coding-pro-2" and .models.sonnet=="coding-standard-2"' "$tmp/manual" >/dev/null
if MODEL_TEST_FAIL=true "$repo/clai" probe openai >"$tmp/blocked";then echo 'failed probe returned stale success';exit 1;fi
"$repo/clai" probe openai --cached | jq -e '.source=="cache"' >/dev/null
if OPENAI_API_KEY=another-fixture-key "$repo/clai" probe openai --cached >/dev/null 2>&1;then echo 'cross-key cache accepted';exit 1;fi
"$repo/clai" probe openai --model coding-mini-2 --check-tools >"$tmp/checked"
jq -e 'any(.models[];.id=="coding-mini-2" and .checks.tools=="passed")' "$tmp/checked" >/dev/null
for flag in MODEL_TEST_MALFORMED MODEL_TEST_PAGING;do
 if env "$flag=true" "$repo/clai" probe openai >/dev/null 2>&1;then echo 'invalid catalog accepted';exit 1;fi
done
if MODEL_TEST_LOOP=true "$repo/clai" probe gemini >/dev/null 2>&1;then echo 'repeated cursor accepted';exit 1;fi
MODEL_TEST_FALLBACK=true "$repo/clai" probe lmstudio | jq -e '.complete and (.models|length)==6' >/dev/null
if MODEL_TEST_TOOL_FAIL=true "$repo/clai" probe openai --model coding-mini-2 --check-tools >"$tmp/failed-tools" 2>/dev/null;then echo 'failed tools accepted';exit 1;fi
jq -e 'any(.models[];.id=="coding-mini-2" and .checks.tools=="failed")' "$tmp/failed-tools" >/dev/null
"$repo/clai" config set local base_url http://127.0.0.1:19998 >/dev/null
"$repo/clai" probe local >/dev/null
"$repo/clai" config set local base_url http://127.0.0.1:19997 >/dev/null
if "$repo/clai" probe local --cached >/dev/null 2>&1;then echo 'cross-endpoint cache accepted';exit 1;fi
"$repo/clai" config set deepseek model coding-standard-2 >/dev/null
"$repo/clai" map deepseek --strategy balanced --apply >"$tmp/applied"
"$repo/clai" run deepseek
"$repo/clai" config unset deepseek mapping >/dev/null
printf 'PASS: current paged/scoped inventory, capability evidence, five strategies, explicit qualification, native role bindings and limits\n'
