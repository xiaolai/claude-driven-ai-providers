def provided($xs): [$xs[]|select(.!=null)][0];
def limit_value($v): try ($v|tonumber|if .>0 and .==floor then . else null end) catch null;
def flag($v): if ($v|type)=="boolean" then $v else null end;
def normalize:
  (.model//.id//.key//.name) as $wire |
  (if $kind=="gemini" then ($wire|sub("^models/";"")) else $wire end) as $id |
  {id:$id, provider_id:$wire, display_name:(.displayName//.display_name//$id),
   input_tokens:limit_value(provided([([.loaded_instances[]?.config.context_length]|min),.inputTokenLimit,.context_window,.input_token_limit,.max_context_length])),
   output_tokens:limit_value(provided([.outputTokenLimit,.max_output_tokens,.output_token_limit])),
   capabilities:{
     text:flag(if .supportedGenerationMethods!=null then (.supportedGenerationMethods|index("generateContent")!=null)
       elif .inputModalities!=null then (.inputModalities|index("text")!=null)
       elif $kind=="codex" then true elif $kind=="lmstudio" and .type!=null then .type=="llm"
       else provided([.capabilities.text,.supports_text]) end),
     tools:flag(provided([.capabilities.tools,.capabilities.trained_for_tool_use,.supports_tool_calling,.supports_function_calling])),
     vision:flag(if .inputModalities!=null then (.inputModalities|index("image")!=null) else provided([.capabilities.vision,.supports_vision]) end)},
   reasoning_efforts:(if .supportedReasoningEfforts!=null then [.supportedReasoningEfforts[].reasoningEffort]
     elif .supported_reasoning_efforts!=null then .supported_reasoning_efforts else null end),
   loaded:(if .loaded_instances!=null then (.loaded_instances|length)>0 else flag(.loaded) end),
   hidden:(.hidden//false),is_default:(.isDefault//.is_default//false),
   evidence:"provider-model-list",checks:{tools:"unverified"}} |
  .tier_hint=(if ($id|test("(^|[-_:/])(astra|pro|ultra|reasoner|high)([-_:/]|$)";"i")) then "quality"
    elif ($id|test("(^|[-_:/])(luna|mini|nano|flash|lite|fast|low)([-_:/]|$)";"i")) then "fast" else "standard" end) |
  .exclusion=(if .hidden then "hidden"
    elif .capabilities.text==false then "provider reports non-text model"
    elif .capabilities.tools==false then "provider reports no tool support"
    elif $kind=="lmstudio" and .loaded==false then "not loaded"
    elif .capabilities.tools!=true and ($id|test("embedding|whisper|deep-research|computer-use|(^|[-/])(tts|dall-e|moderation|realtime|transcribe|sora|audio|image)([-/]|$)";"i")) then "name suggests a non-chat model (heuristic)"
    else null end) |
  .eligible=(.exclusion==null);
[.[]|select((.model//.id//.key//.name|type)=="string")|normalize|
 select((.id|length)>0 and (.id|length)<=512 and (.id|test("[[:cntrl:]]")|not) and (.id|startswith("-")|not))] |
unique_by(.id)
