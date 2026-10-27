#!/bin/bash
# Loaded only by clai's prepare/setup/skill commands; setup files are never sourced.
# Globals are owned by clai; the main entry point is also checked with ShellCheck.
# shellcheck disable=SC2154

setup_path() {
  local path=$1
  case "$path" in [~]/*) path="$HOME/${path:2}";; esac
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || fail 'setup paths must be absolute or start with ~/'
  printf '%s' "$path"
}
setup_bin() {
  local command path
  for command in clai $(jq -r '.providers[]|.alias,.legacy_aliases[]?' "$registry"); do
    path=$(type -P "$command" || true)
    if [ -n "$path" ]; then (cd "$(dirname "$path")" && pwd); return; fi
  done
  printf '%s/.local/bin' "$HOME"
}
prepare_setup() (
  [ "$#" -ge 1 ] || fail 'usage: clai prepare PROVIDER [--out FILE]'
  select_provider "$1" stored; shift
  local out="$config_root/setup/.env-$id" stage bin key_name model context
  if [ "$#" -ne 0 ]; then [ "$#" -eq 2 ] && [ "$1" = --out ] || fail 'usage: clai prepare PROVIDER [--out FILE]'; out=$2; fi
  case "$out" in /*|[~]/*) out=$(setup_path "$out");; *) out="$PWD/$out";; esac
  [ ! -e "$out" ] && [ ! -L "$out" ] || fail 'template already exists; it was not overwritten'
  bin=$(setup_bin); key_name=$(printf '%s' "$provider"|jq -r '.key_env//empty')
  model=$(printf '%s' "$cfg"|jq -r .model); context=$(printf '%s' "$cfg"|jq -r .context)
  [[ "$model$bin" != *$'\n'* && "$model$bin" != *$'\r'* ]] || fail 'template values cannot contain line breaks'
  mkdir -p "$(dirname "$out")"
  stage=$(mktemp "$(dirname "$out")/.clai-template.XXXXXXXX"); trap 'rm -f -- "$stage"' EXIT
  {
    printf '# Fill this private file, then ask Claude: apply this file with clai setup.\n'
    printf '# Data only: KEY=value, optional matching outer quotes; no export or expansion.\n'
    printf '# Blank optional values reuse existing settings/credentials. Never paste keys in chat.\n'
    printf 'PROVIDER=%s\n' "$id"
    if [ -n "$key_name" ]; then printf '%s=\n' "$key_name"; else printf '# This route uses existing subscription login or needs no stored API key.\n'; fi
    printf 'MODEL=%s\nCONTEXT_TOKENS=%s\nAUTO_COMPACT_TOKENS=\nEFFORT=\nMAX_OUTPUT_TOKENS=\n' "$model" "$context"
    printf '# Optional strategy: single, quality, balanced, economy, manual. Blank preserves current mapping.\n'
    printf 'MAPPING_STRATEGY=\nQUALITY_MODEL=\nSTANDARD_MODEL=\nFAST_MODEL=\nOPUS_MODEL=\nFABLE_MODEL=\nSONNET_MODEL=\nHAIKU_MODEL=\nSUBAGENT_MODEL=\nCUSTOM_MODEL=\n'
    if [ "$(printf '%s' "$provider"|jq -r .auth)" = local ]; then
      printf '# Local server root, not /v1/messages or /chat/completions.\nBASE_URL=\nPROTOCOL=%s\n' "$(printf '%s' "$cfg"|jq -r .protocol)"
    fi
    printf 'BIN_DIR=%s\n' "$bin"
  } >"$stage"
  chmod 600 "$stage"
  ln "$stage" "$out" || fail 'template could not be created without overwriting a file'
  printf 'Prepared private template: %s\n' "$out"
)
parse_setup() {
  local line key value quote seen=' ' number=0
  setup_values='{}'; setup_secret=''; setup_key_name=''
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number+1)); line=${line%$'\r'}
    line=${line#"${line%%[![:blank:]]*}"}; line=${line%"${line##*[![:blank:]]}"}
    case "$line" in ''|'#'*) continue;; esac
    [[ "$line" == *=* ]] || fail "expected KEY=value at line $number"
    key=${line%%=*}; key=${key%"${key##*[![:blank:]]}"}
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "invalid field at line $number"
    [[ "$seen" != *" $key "* ]] || fail "duplicate field at line $number"
    seen="$seen$key "
    value=${line#*=}; value=${value#"${value%%[![:blank:]]*}"}; value=${value%"${value##*[![:blank:]]}"}
    quote=${value:0:1}
    if [ "$quote" = '"' ] || [ "$quote" = "'" ]; then
      [ "${#value}" -ge 2 ] && [ "${value: -1}" = "$quote" ] || fail "unbalanced quotes at line $number"
      value=${value:1:${#value}-2}
    fi
    case "$key" in
      PROVIDER|MODEL|CONTEXT_TOKENS|AUTO_COMPACT_TOKENS|EFFORT|MAX_OUTPUT_TOKENS|BASE_URL|PROTOCOL|BIN_DIR|MAPPING_STRATEGY|QUALITY_MODEL|STANDARD_MODEL|FAST_MODEL|OPUS_MODEL|FABLE_MODEL|SONNET_MODEL|HAIKU_MODEL|SUBAGENT_MODEL|CUSTOM_MODEL)
        setup_values=$(printf '%s' "$setup_values"|jq -c --arg key "$key" --arg value "$value" '.+{($key):$value}');;
      *)
        if [ "$key" != API_KEY ]; then jq -e --arg key "$key" 'any(.providers[];.key_env==$key or .alt_env==$key)' "$registry" >/dev/null || fail "unsupported field at line $number"; fi
        [ -z "$setup_key_name" ] || fail 'use one credential field per setup file'
        setup_key_name=$key; setup_secret=$value;;
    esac
  done <"$1"
}
install_setup_skill() {
  local target="$HOME/.claude/skills/clai-setup" stage
  if [ "$#" -ne 0 ]; then
    [ "$#" -eq 2 ] || fail 'usage: clai skill install [--profile PROVIDER|--dir DIRECTORY]'
    case "$1" in
      --profile) select_provider "$2" key; target="$HOME/$(printf '%s' "$provider"|jq -r .profile)/skills/clai-setup";;
      --dir) target=$(setup_path "$2");;
      *) fail 'unknown skill install option';;
    esac
  fi
  if [ -e "$target/SKILL.md" ]; then
    [ ! -L "$target/SKILL.md" ] && grep -Fq '<!-- managed-by: claude-driven-ai-providers -->' "$target/SKILL.md" || fail 'existing skill is not managed by clai; choose a different directory'
  fi
  mkdir -p "$target"
  stage=$(mktemp "$target/.SKILL.XXXXXXXX")
  install -m 644 "$root/skills/clai-setup/SKILL.md" "$stage"; mv -f "$stage" "$target/SKILL.md"
  printf 'Installed Claude skill: %s\n' "$target"
}
apply_setup() {
  local input='' dry=false deploy=true check=false probe_only=false name old='{}' changes bin key_name alternate active file stage configured_id strategy mapping choices target final_cfg
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env) [ "$#" -ge 2 ] && [ -z "$input" ] || fail 'provide exactly one --env file'; input=$2; shift;;
      --dry-run) dry=true;; --no-install) deploy=false;; --check-tools) check=true;; --probe) probe_only=true;;
      *) fail 'usage: clai setup --env FILE [--dry-run|--probe] [--no-install] [--check-tools]';;
    esac
    shift
  done
  [ "$dry" != true ] || [ "$probe_only" != true ] || fail 'choose dry-run (offline) or probe (live discovery)'
  [ -n "$input" ] || fail 'prepare a template first: clai prepare PROVIDER; then clai setup --env FILE'
  case "$input" in /*|[~]/*) input=$(setup_path "$input");; *) input="$PWD/$input";; esac
  private_file "$input"; parse_setup "$input"
  name=$(printf '%s' "$setup_values"|jq -r '.PROVIDER//empty'); [ -n "$name" ] || fail 'PROVIDER is required'
  select_provider "$name" edit; configured_id=$id
  key_name=$(printf '%s' "$provider"|jq -r '.key_env//empty'); alternate=$(printf '%s' "$provider"|jq -r '.alt_env//empty')
  if [ -n "$setup_key_name" ]; then
    [ "$setup_key_name" = API_KEY ] || [ "$setup_key_name" = "$key_name" ] || [ "$setup_key_name" = "$alternate" ] || fail 'credential field belongs to another provider'
  fi
  file="$config_root/providers/$id.json"; if [ -e "$file" ]; then old=$(cat "$file"); fi
  changes=$(printf '%s' "$setup_values"|jq -c '
    {MODEL:"model",CONTEXT_TOKENS:"context",AUTO_COMPACT_TOKENS:"compact",EFFORT:"effort",MAX_OUTPUT_TOKENS:"max_output_tokens",BASE_URL:"base_url",PROTOCOL:"protocol"} as $map |
    reduce to_entries[] as $item ({}; if $item.value!="" and $map[$item.key]!=null then .+{($map[$item.key]):$item.value} else . end)')
  strategy=$(printf '%s' "$setup_values"|jq -r '.MAPPING_STRATEGY//empty')
  case "$strategy" in ''|single|quality|balanced|economy|manual) ;;*) fail 'unknown mapping strategy';;esac
  choices=$(printf '%s' "$setup_values"|jq -c '{MODEL:"model",QUALITY_MODEL:"quality",STANDARD_MODEL:"standard",FAST_MODEL:"fast",OPUS_MODEL:"opus",FABLE_MODEL:"fable",SONNET_MODEL:"sonnet",HAIKU_MODEL:"haiku",SUBAGENT_MODEL:"subagent",CUSTOM_MODEL:"custom"} as $map |
    reduce to_entries[] as $item ({};if $item.value!="" and $map[$item.key]!=null then .+{($map[$item.key]):$item.value} else . end)')
  cfg=$(printf '%s' "$cfg"|jq -c --argjson changes "$changes" --arg strategy "$strategy" '.+$changes|if $strategy!="" then del(.mapping) else . end'); validate_config
  if [ -n "$setup_secret" ]; then
    [ -n "$(printf '%s' "$provider"|jq -r '.key_file//empty')" ] || fail 'this route does not accept an API key'
    [[ "$setup_secret" =~ ^[A-Za-z0-9._~+/:=-]+$ ]] || fail 'invalid credential characters'
    active=''; [ -z "$key_name" ] || active=${!key_name:-}; if [ -z "$active" ] && [ -n "$alternate" ]; then active=${!alternate:-}; fi
    [ -z "$active" ] || [ "$active" = "$setup_secret" ] || fail 'provider key environment differs from template; clear that override before applying'
    credential=$setup_secret; key_source=template
  else read_key; fi
  [ "$(printf '%s' "$provider"|jq -r .auth)" != api ] || [ -n "$credential" ] || fail 'API key missing; fill its field in the private setup file'
  if [ "$(printf '%s' "$provider"|jq -r .auth)" = local ]; then
    [ "$(printf '%s' "$cfg"|jq -r .base_url)" != '' ] || fail 'local BASE_URL is missing'
  fi
  if [ "$(printf '%s' "$cfg"|jq -r .base_url)" != '' ]; then validate_url "$(printf '%s' "$cfg"|jq -r .base_url)"; fi
  [ "$(printf '%s' "$cfg"|jq -r .model)" != '' ] || [ -n "$strategy" ] || [ "$probe_only" = true ] || fail 'MODEL is missing; choose a loaded model for the local server'
  bin=$(printf '%s' "$setup_values"|jq -r '.BIN_DIR//empty'); [ -n "$bin" ] || bin=$(setup_bin); bin=$(setup_path "$bin")
  if [ "$dry" = true ]; then
    jq -cn --arg provider "$id" --arg source "$key_source" --arg bin "$bin" --arg strategy "$strategy" '{provider:$provider,credential_source:$source,bin_dir:$bin,state:"validated-not-applied",mapping_state:(if $strategy=="" then "unchanged" else "pending-live-discovery" end)}'; return
  fi
  if [ -n "$strategy" ] || [ "$probe_only" = true ];then
    # shellcheck source=models.sh
    source "$root/models.sh"
    # Used by the separately sourced inventory module.
    # shellcheck disable=SC2034
    model_credential_ready=true
    if [ "$probe_only" = true ];then model_inventory false;return;fi
    mapping=$(mapping_proposal "$strategy" "$choices" false) || return 1
    cfg=$(printf '%s' "$cfg"|jq -c --argjson mapping "$mapping" '.mapping=$mapping|.model=$mapping.models.sonnet');validate_config
    changes=$(printf '%s' "$changes"|jq -c --argjson mapping "$mapping" '.mapping=$mapping|.model=$mapping.models.sonnet')
    printf '%s\n' "$mapping"
  fi
  # All input validation precedes the first mutation. Each private file is atomic.
  final_cfg=$cfg
  if [ -n "$setup_secret" ]; then printf '%s\n' "$setup_secret"|"$root/clai" key set "$id" --stdin; fi
  mkdir -p "$config_root/providers"; chmod 700 "$config_root" "$config_root/providers"
  stage=$(mktemp "$config_root/providers/.${id}.XXXXXXXX")
  printf '%s' "$old"|jq -c --argjson changes "$changes" '.+$changes' >"$stage"; chmod 600 "$stage"; mv -f "$stage" "$file"
  unset setup_secret credential
  printf 'Saved private configuration for %s.\n' "$id"
  if [ "$deploy" = true ]; then install_runtime "$bin"; install_setup_skill; install_setup_skill --profile "$configured_id"; fi
  "$root/clai" doctor "$configured_id" --network || return 1
  if [ "$check" = true ];then
    if printf '%s' "$final_cfg"|jq -e '.mapping!=null' >/dev/null;then
      "$root/clai" probe "$configured_id" >/dev/null || return 1
      while IFS= read -r target;do "$root/clai" probe "$configured_id" --cached --model "$target" --check-tools >/dev/null || return 1;done < <(printf '%s' "$final_cfg"|jq -r '.mapping.models[]'|sort -u)
      stage=$(mktemp "$config_root/providers/.${configured_id}.XXXXXXXX")
      jq '.mapping.verification="tool-verified"' "$file" >"$stage";chmod 600 "$stage";mv -f "$stage" "$file"
    else "$root/clai" check "$configured_id" --tools;fi
  else printf 'Configured; live generation/tool use has not been tested by this setup.\n';fi
}
