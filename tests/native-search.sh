#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clcd-search-tests.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
for name in request search-response search-sse; do
  awk -v marker="cat >\"\$runtime/$name.jq\"" 'index($0,marker)==1 {p=1;next} p&&/^JQ$/ {exit} p {print}' "$repo/clcd" >"$tmp/$name.jq"
done
printf '{}\n' >"$tmp/names.json"
request() {
  jq --arg model fixture --arg effort low --arg transport "${TRANSPORT:-codex}" \
    --arg search_mode "${MODE:-live}" --arg search_unbounded "${UNBOUNDED:-true}" \
    --slurpfile names "$tmp/names.json" -f "$tmp/request.jq" "$1"
}
printf '%s\n' '{"messages":[{"role":"user","content":"Search docs"}],"tools":[{"name":"web_search","type":"web_search_20250305","max_uses":8}],"tool_choice":{"type":"auto"}}' >"$tmp/request.json"
request "$tmp/request.json" | jq -e '.tools==[{type:"web_search",external_web_access:true}] and .tool_choice=="auto" and (has("max_tool_calls")|not)' >/dev/null
MODE=cached request "$tmp/request.json" | jq -e '.tools[0].external_web_access==false' >/dev/null
for setting in 'MODE=disabled' 'UNBOUNDED=false' 'TRANSPORT=openai'; do
  if (export "${setting?}";request "$tmp/request.json") >"$tmp/ignored" 2>&1; then echo "accepted $setting";exit 1;fi
done
for change in '.tools[0].allowed_domains=false' '.tools[0].blocked_domains=false' '.tools[0].max_uses=1' '.tools[0].max_uses=0' '.tools[0].type="web_search_20260209"' '.tools[0].blocked_domains=["example.com"]' '.tools[0].user_location={country:"US"}' '.tools[0].search_profile="x"' '.tools[0].allowed_callers=["code_execution"]' '.tools[0].allowed_domains=["example.com/path"]' '.tool_choice={type:"none"}' '.tools+=[{name:"Bash",input_schema:{type:"object"}}]'; do
  jq "$change" "$tmp/request.json" >"$tmp/bad.json"
  if request "$tmp/bad.json" >"$tmp/ignored" 2>&1;then echo "accepted $change";exit 1;fi
done
jq '.tools[0].allowed_domains=["docs.example.com"] | .tool_choice={type:"tool",name:"web_search"}' "$tmp/request.json" >"$tmp/allowed.json"
request "$tmp/allowed.json" | jq -e '.tools[0].filters.allowed_domains==["docs.example.com"] and .tool_choice=={type:"web_search"}' >/dev/null
jq '.tools=[{name:"WebSearch",input_schema:{type:"object"}}]' "$tmp/request.json" >"$tmp/ordinary.json"
MODE=disabled request "$tmp/ordinary.json" | jq -e '.tools[0].type=="function" and .tools[0].name=="WebSearch"' >/dev/null
printf 'PASS: native search request gating, modes, explicit unbounded opt-in, limits, ordinary WebSearch preserved\n'
# Full completed.output is absent on the real subscription endpoint: use done items.
jq -n '
  "中文😀 Result citeturn0search0" as $text |
  {id:"m",type:"message",content:[{type:"output_text",text:$text,annotations:[{type:"url_citation",start_index:($text|split("cite")[0]|length),end_index:($text|length),url:"https://example.com/a(b)",title:"Docs"}]}]} as $message |
  [{type:"response.created",response:{id:"r"}},
   {type:"response.output_item.done",output_index:1,item:$message},
   {type:"response.output_item.done",output_index:0,item:{id:"ws",type:"web_search_call",status:"completed",action:{type:"search",query:"Search docs"}}},
   {type:"response.completed",response:{id:"r",usage:{input_tokens:100,input_tokens_details:{cached_tokens:20},output_tokens:10}}}]
' >"$tmp/events.json"
render() { jq -r '.[]|"data: "+tojson+"\n"' "$1" | jq -Rsc --arg model fixture -f "$tmp/search-response.jq"; }
render "$tmp/events.json" >"$tmp/answer.json"
jq -e '([.content[]|select(.type=="text")][0].text)=="中文😀 Result [1](https://example.com/a%28b%29)" and .stop_reason=="end_turn" and .usage.input_tokens==80 and .usage.server_tool_use.web_search_requests==1' "$tmp/answer.json" >/dev/null
jq -rj -f "$tmp/search-sse.jq" "$tmp/answer.json" | sed -n 's/^data: //p' | jq -se '([.[]|select(.type=="message_stop")]|length)==1 and any(.[];.delta.text=="中文😀 Result [1](https://example.com/a%28b%29)")' >/dev/null
# Natural-language annotation spans must not be deleted.
jq '.[1].item.content[0] |= (.text="Fact" | .annotations[0].start_index=0 | .annotations[0].end_index=4)' "$tmp/events.json" >"$tmp/natural.json"
render "$tmp/natural.json" | jq -e '([.content[]|select(.type=="text")][0].text)=="Fact[1](https://example.com/a%28b%29)"' >/dev/null
jq '.[1].item.content[0].annotations += [(.[1].item.content[0].annotations[0]|.url="https://second.example/docs")]' "$tmp/events.json" >"$tmp/multi.json"
render "$tmp/multi.json" | jq -e '([.content[]|select(.type=="text")][0].text)=="中文😀 Result [1](https://example.com/a%28b%29)[2](https://second.example/docs)"' >/dev/null
for change in '.[-1].response.output=[{id:"fc",type:"function_call",name:"unexpected"}]' '.[2].item.action.type="unknown"' '.[2].item.action.query=""' '.[-1].type="response.failed"' '.[-1].type="response.incomplete"' '.+=[.[-1]]' '.[-1].type="error"' '.[2].item.status="failed"' 'del(.[2])' '.[1].item.content[0].annotations=[]' '.[1].item.content[0].annotations[0].url="javascript:alert(1)"' '.[1].item.content[0].annotations[0].end_index=9999'; do
  jq "$change" "$tmp/events.json" >"$tmp/bad.json"
  if render "$tmp/bad.json" >"$tmp/ignored" 2>&1;then echo "accepted bad response: $change";exit 1;fi
done
if { jq -r '.[]|"data: "+tojson+"\n"' "$tmp/events.json";printf 'data: {bad}\n'; } | jq -Rsc --arg model fixture -f "$tmp/search-response.jq" >"$tmp/ignored" 2>&1;then echo 'accepted trailing bad JSON';exit 1;fi
# completed.output duplicates done items: count search once.
jq '.[-1].response.output=[.[2].item,.[1].item]' "$tmp/events.json" >"$tmp/duplicate.json"
render "$tmp/duplicate.json" | jq -e '.usage.server_tool_use.web_search_requests==1 and ([.content[]|select(.type=="text")]|length)==1' >/dev/null
printf 'PASS: search evidence, terminal validation, Unicode clickable citations, source safety, deduplication and SSE\n'

# Count only completed searches, never page opens/finds; no encrypted result invented.
render "$tmp/events.json" | jq -e '[.content[]|select(.type=="server_tool_use")]==[{type:"server_tool_use",id:"srvtoolu_ws",name:"web_search",input:{query:"Search docs"}}] and ([.content[].type]|index("web_search_tool_result")==null)' >/dev/null
jq '.[2].item.action={type:"open_page",url:"https://example.com"}' "$tmp/events.json" >"$tmp/open.json"
render "$tmp/open.json" | jq -e '[.content[]|select(.type=="server_tool_use")]|length==0' >/dev/null
printf 'PASS: truthful search activity records for Claude Code counters; non-search actions excluded\n'
