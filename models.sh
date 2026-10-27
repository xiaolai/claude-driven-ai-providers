#!/bin/bash
# Sourced by clai; private metadata only, never a persistent credential copy.
# shellcheck disable=SC2154
model_credential_ready=false

model_rpc() {
  local method=$1 params=$2 rpc_id line deadline remaining
  rpc_id=$(openssl rand -hex 12); deadline=$((SECONDS+30))
  jq -cn --arg id "$rpc_id" --arg method "$method" --argjson params "$params" '{id:$id,method:$method,params:$params}' >&7
  while [ "$SECONDS" -lt "$deadline" ]; do
    remaining=$((deadline-SECONDS))
    IFS= read -r -t "$remaining" line <&8 || return 1
    if printf '%s' "$line"|jq -e --arg id "$rpc_id" '.id==$id and (has("result") or has("error"))' >/dev/null;then
      printf '%s' "$line"|jq -ce 'if has("error") then error("Model catalog RPC failed") else .result end';return
    fi
  done
  return 1
}
model_inventory() (
  local cached=${1:-false} work auth_pid='' identity='' kind url header page=0 cursor='' prior=' ' status raw scope cache_file source_state=listed
  work=$(mktemp -d);trap 'if [ -n "$auth_pid" ];then kill "$auth_pid" 2>/dev/null||true;wait "$auth_pid" 2>/dev/null||true;fi;rm -rf -- "$work"' EXIT
  [ "$model_credential_ready" = true ] || read_key
  kind=$(printf '%s' "$provider"|jq -r '.discovery_kind//"openai"')
  models_url; header=$(printf '%s' "$provider"|jq -r '.models_header//"Authorization"')
  if [ "$kind" = codex ];then
    mkfifo "$work/in" "$work/out";exec 7<>"$work/in" 8<>"$work/out"
    (unset OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN;exec codex -c 'model_provider="openai"' app-server --listen stdio://) <"$work/in" >"$work/out" 7>&- 8>&- 2>"$work/rpc-error" & auth_pid=$!
    model_rpc initialize '{"clientInfo":{"name":"clai_models","version":"1"},"capabilities":{}}' >/dev/null || fail 'could not initialize model catalog RPC'
    printf '{"method":"initialized"}\n' >&7
    identity=$(model_rpc account/read '{"refreshToken":false}') || fail 'could not read subscription catalog identity'
    printf '%s' "$identity"|jq -e '.account.type=="chatgpt"' >/dev/null || fail 'model probe requires Codex ChatGPT login'
    identity=$(printf '%s' "$identity"|jq -c '{account,workspaceRouting}'|openssl dgst -sha256|awk '{print $NF}')
  fi
  scope=$(printf '%s\n%s\n%s\n%s' "$id" "$(printf '%s' "$cfg"|jq -r .base_url)" "$credential" "$identity"|openssl dgst -sha256|awk '{print $NF}')
  cache_file="$cache_root/models/$id-$scope.json"
  if [ "$cached" = true ];then
    [ -e "$cache_file" ] || fail 'no inventory cache for this endpoint/account; run clai probe first'
    private_file "$cache_file"
    jq -ce --arg scope "$scope" 'select(.schema_version==1 and .scope==$scope)|.source="cache"' "$cache_file";return
  fi
  if [ "$kind" = lmstudio ];then
    url="$(printf '%s' "$cfg"|jq -r .base_url)";url=${url%/};url=${url%/v1};url="$url/api/v1/models"
  fi
  if [ -z "$url" ] && [ "$kind" != codex ];then
    source_state=catalog-only
    printf '%s' "$cfg"|jq '[{id:.model}]+[.aliases[]?|{id:.}]|map(select(.id!=""))' >"$work/items"
  else
    [ "$(printf '%s' "$provider"|jq -r .auth)" != api ] || [ -n "$credential" ] || fail 'provider key is missing'
    printf '[]\n' >"$work/items"
    while :;do
      page=$((page+1));[ "$page" -le 100 ] || fail 'model pagination exceeded 100 pages'
      if [ "$kind" = codex ];then
        raw=$(model_rpc model/list "$(jq -cn --arg cursor "$cursor" '{limit:100,includeHidden:false,cursor:(if $cursor=="" then null else $cursor end)}')") || fail 'model catalog RPC failed'
        printf '%s' "$raw" >"$work/page"
      else
        if [ "$kind" = gemini ] && [ -n "$cursor" ];then status=$(net_get "$url" "$header" "$work/page" pageToken "$cursor") || status=network-error
        else status=$(net_get "$url" "$header" "$work/page") || status=network-error;fi
        if [ "$kind" = lmstudio ] && [ "$status" = 404 ];then models_url;kind=openai;status=$(net_get "$url" "$header" "$work/page") || status=network-error;fi
        if [ "$status" != 200 ];then
          jq -cn --arg provider "$id" --arg state "http-$status" '{schema_version:1,provider:$provider,state:$state,complete:false,models:[]}'
          return 1
        fi
      fi
      jq -e '(.data//.models)|type=="array"' "$work/page" >/dev/null || fail 'malformed model catalog response'
      jq --slurpfile previous "$work/items" '$previous[0]+(.data//.models)' "$work/page" >"$work/next";mv "$work/next" "$work/items"
      [ "$(jq length "$work/items")" -le 10000 ] || fail 'model catalog exceeded 10000 entries'
      if [ "$kind" = gemini ];then cursor=$(jq -r '.nextPageToken//empty' "$work/page")
      elif [ "$kind" = codex ];then cursor=$(jq -r '.nextCursor//empty' "$work/page")
      else
        jq -e '(.has_more//false)==false and (.nextPageToken//.nextCursor//"")==""' "$work/page" >/dev/null || fail 'provider returned pagination without a documented paging contract'
        cursor=''
      fi
      [ -n "$cursor" ] || break
      # Compare encoded cursors as whole JSON strings, not glob patterns.
      raw=$(printf '%s' "$cursor"|jq -Rs .)
      [[ "$prior" != *" $raw "* ]] || fail 'model pagination repeated a cursor'
      prior="$prior$raw "
    done
  fi
  jq --arg kind "$kind" -f "$root/adapters/model-inventory.jq" "$work/items" >"$work/models" || fail 'invalid model metadata'
  jq -n --arg provider "$id" --arg scope "$scope" --arg state "$source_state" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile models "$work/models" \
    '{schema_version:1,provider:$provider,scope:$scope,state:$state,complete:true,source:(if $state=="catalog-only" then "registry" else "live" end),observed_at:$now,models:$models[0]}' >"$work/inventory"
  if [ "$source_state" = catalog-only ];then jq '.models|=map(.evidence="configured-catalog-unverified")' "$work/inventory" >"$work/next";mv "$work/next" "$work/inventory";fi
  mkdir -p "$cache_root/models";chmod 700 "$cache_root" "$cache_root/models"
  raw=$(mktemp "$cache_root/models/.inventory.XXXXXXXX");cat "$work/inventory" >"$raw";chmod 600 "$raw";mv -f "$raw" "$cache_file"
  cat "$work/inventory"
)
qualify_inventory() {
  local input=$1 target=$2 status=passed output effort context budget args
  jq -e --arg target "$target" 'any(.models[];.id==$target and .eligible)' "$input" >/dev/null || fail 'selected model is not an eligible inventory entry'
  context=$(jq -r --arg target "$target" --argjson requested "$cfg" '[.models[]|select(.id==$target)|.input_tokens// $requested.context,$requested.context]|min' "$input")
  budget=$(jq -r --arg target "$target" --argjson context "$context" '[.models[]|select(.id==$target)|.output_tokens//4096,4096,$context]|min' "$input")
  effort=$(jq -r --arg target "$target" --argjson cfg "$cfg" '[.models[]|select(.id==$target)|(.reasoning_efforts//[])[] as $level | select(($cfg.effort_levels//[])|index($level)!=null)|$level][0]//empty' "$input")
  args=(--model "$target" --tools --context "$context" --max-output-tokens "$budget")
  if [ -n "$effort" ];then args+=(--effort "$effort");fi
  "$root/clai" check "$id" "${args[@]}" >&2 || status=failed
  output=$(mktemp)
  jq --arg target "$target" --arg status "$status" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.models|=map(if .id==$target then .checks={tools:$status,observed_at:$now} else . end)' "$input" >"$output"
  mv "$output" "$input"
  output="$cache_root/models/$id-$(jq -r .scope "$input").json"
  local stage;stage=$(mktemp "$cache_root/models/.inventory.XXXXXXXX");cat "$input" >"$stage";chmod 600 "$stage";mv -f "$stage" "$output"
  [ "$status" = passed ]
}
probe_provider() (
  local cached=false check=false target='' work status=0
  while [ "$#" -gt 0 ];do
    case "$1" in --cached) cached=true;; --check-tools) check=true;; --model) [ "$#" -ge 2 ] || fail '--model needs an ID';target=$2;shift;; *) fail 'unknown probe option';;esac;shift
  done
  work=$(mktemp);trap 'rm -f -- "$work"' EXIT
  model_inventory "$cached" >"$work" || { cat "$work";return 1; }
  if [ "$check" = true ];then [ -n "$target" ] || fail 'choose one --model for a paid tool probe';target=$(printf '%s' "$target"|jq -Rr --arg id "$id" 'if $id=="gemini" then sub("^models/";"") else . end');qualify_inventory "$work" "$target" || status=1;fi
  cat "$work";return "$status"
)
mapping_proposal() (
  local strategy=$1 choices=$2 cached=${3:-false} work
  work=$(mktemp);trap 'rm -f -- "$work"' EXIT
  model_inventory "$cached" >"$work" || { cat "$work" >&2;return 1; }
  jq -n --arg strategy "$strategy" --argjson cfg "$cfg" --argjson choices "$choices" --slurpfile inventory "$work" -f "$root/adapters/model-mapping.jq"
)
map_provider() (
  local strategy=single choices='{}' cached=false apply=false check=false key value proposal file old='{}' stage inventory target
  while [ "$#" -gt 0 ];do
    case "$1" in
      --cached) cached=true;; --apply) apply=true;; --check-tools) check=true;;
      --strategy|--quality|--standard|--fast|--model|--opus|--fable|--sonnet|--haiku|--subagent|--custom)
        [ "$#" -ge 2 ] || fail 'mapping option needs a value';key=${1#--};value=$2;shift
        if [ "$key" = strategy ];then strategy=$value;else choices=$(printf '%s' "$choices"|jq -c --arg k "$key" --arg v "$value" '.+{($k):$v}');fi;;
      *) fail 'unknown mapping option';;
    esac;shift
  done
  proposal=$(mapping_proposal "$strategy" "$choices" "$cached") || return 1
  if [ "$check" = true ];then
    inventory=$(mktemp);trap 'rm -f -- "$inventory"' EXIT
    model_inventory true >"$inventory"
    while IFS= read -r target;do qualify_inventory "$inventory" "$target" || return 1;done < <(printf '%s' "$proposal"|jq -r '.models[]'|sort -u)
    proposal=$(printf '%s' "$proposal"|jq -c '.verification="tool-verified"')
  fi
  if [ "$apply" = true ];then
    file="$config_root/providers/$id.json";if [ -e "$file" ];then private_file "$file";old=$(cat "$file");fi
    cfg=$(printf '%s' "$provider"|jq -c --argjson old "$old" --argjson mapping "$proposal" '.+$old|.mapping=$mapping|.model=$mapping.models.sonnet');validate_config
    mkdir -p "$config_root/providers";chmod 700 "$config_root" "$config_root/providers"
    stage=$(mktemp "$config_root/providers/.${id}.XXXXXXXX")
    printf '%s' "$old"|jq -c --argjson mapping "$proposal" '.mapping=$mapping|.model=$mapping.models.sonnet' >"$stage";chmod 600 "$stage";mv -f "$stage" "$file"
  fi
  printf '%s\n' "$proposal"
)
