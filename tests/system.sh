#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-system.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache"
shellcheck -S warning "$repo/clai"
mkdir -p "$HOME" "$tmp/bin"
unset OPENAI_API_KEY XAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY CLAUDE_CODE_AUTO_COMPACT_WINDOW
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --help ]; then printf 'CLAUDE_OPTIONS\n'; exit; fi
[ "$ANTHROPIC_MODEL" = "$EXPECTED_MODEL" ]
[ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" = "$EXPECTED_CONTEXT" ]
[ "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" = "$EXPECTED_COMPACT" ]
[ "$ANTHROPIC_AUTH_TOKEN" = "$EXPECTED_KEY" ]
[ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude-deepseek" ]
[ "$1" = --dangerously-skip-permissions ]
[ "$2" = --print ]; [ "$3" = 'argument with spaces and $characters' ]
MOCK
cat >"$tmp/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
file='';args=("$@")
for ((i=0;i<${#args[@]};i++));do [ "${args[$i]}" != -o ] || file=${args[$((i+1))]};done
[ -n "$file" ]
case "${CLAI_TEST_HTTP:-200}" in 400) printf '{"error":{"message":"Location unsupported"}}';; 403) printf '{"error":{"message":"Billing credits required"}}';; *) printf '{"data":[{"id":"fixture-model"}]}';; esac >"$file"
printf '%s' "${CLAI_TEST_HTTP:-200}"
MOCK
chmod 700 "$tmp/bin/claude" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
"$repo/clai" list --json | jq -e '.schema_version==1 and (.providers|length>=10) and (([.providers[].id]|unique|length)==(.providers|length)) and (([.providers[].alias]|unique|length)==(.providers|length)) and all(.providers[];.docs|startswith("https://"))' >/dev/null
"$repo/clai" config show cllds | jq -e '.id=="local-deepseek"' >/dev/null
if "$repo/clai" config show unknown >/dev/null 2>&1;then echo 'unknown provider accepted';exit 1;fi
key=$(openssl rand -hex 16)
printf '%s\n' "$key" | "$repo/clai" key set deepseek --stdin >"$tmp/key-output"
! grep -q "$key" "$tmp/key-output"
[ "$(stat -f '%Lp' "$XDG_CONFIG_HOME/claude-driven-ai-providers/deepseek-api-key")" = 600 ]
"$repo/clai" config set deepseek model custom-model >/dev/null
"$repo/clai" config set deepseek context 800000 >/dev/null
"$repo/clai" config set deepseek compact 600000 >/dev/null
export EXPECTED_KEY="$key" EXPECTED_MODEL=custom-model EXPECTED_CONTEXT=800000 EXPECTED_COMPACT=600000
"$repo/clai" run deepseek -- --print 'argument with spaces and $characters'
export EXPECTED_KEY
EXPECTED_KEY=$(openssl rand -hex 16)
DEEPSEEK_API_KEY="$EXPECTED_KEY" "$repo/clai" run deepseek -- --print 'argument with spaces and $characters'
export EXPECTED_MODEL=env-model
CLAI_DEEPSEEK_MODEL=env-model DEEPSEEK_API_KEY="$EXPECTED_KEY" "$repo/clai" run deepseek -- --print 'argument with spaces and $characters'
"$repo/clai" doctor deepseek | jq -e '.state=="configured" and .credential_source=="private-file"' >/dev/null
"$repo/clai" models deepseek | grep -qx fixture-model
for status in 400 403; do
  CLAI_TEST_HTTP=$status "$repo/clai" doctor deepseek --network >"$tmp/doctor" && exit 1
  if [ "$status" = 400 ]; then state=provider-location-blocked; else state=provider-billing-blocked; fi
  jq -e --arg state "$state" '.state==$state' "$tmp/doctor" >/dev/null
done
if "$repo/clai" config set openai base_url https://example.com >/dev/null 2>&1;then echo 'cloud origin override accepted';exit 1;fi
if "$repo/clai" config set deepseek api_key value >/dev/null 2>&1;then echo 'credential config field accepted';exit 1;fi
if "$repo/clai" config set deepseek compact 900000 >/dev/null 2>&1;then echo 'invalid context relation accepted';exit 1;fi
chmod 644 "$XDG_CONFIG_HOME/claude-driven-ai-providers/deepseek-api-key"
if "$repo/clai" doctor deepseek >/dev/null 2>&1;then echo 'insecure key file accepted';exit 1;fi
chmod 600 "$XDG_CONFIG_HOME/claude-driven-ai-providers/deepseek-api-key"
"$repo/clai" install --bin "$tmp/installed bin" >/dev/null
export EXPECTED_KEY="$key" EXPECTED_MODEL=custom-model
(cd "$tmp"; "$tmp/installed bin/clds" --print 'argument with spaces and $characters')
"$tmp/installed bin/clai" list --json | jq -e '.schema_version==1' >/dev/null
while IFS= read -r alias; do (cd "$tmp"; "$tmp/installed bin/$alias" --help >/dev/null); done < <(jq -r '.providers[]|.alias,.legacy_aliases[]?' "$repo/providers.json")
"$tmp/installed bin/clai" install --bin "$tmp/installed bin" >"$tmp/install-source"
releases=$(cd "$XDG_DATA_HOME/claude-driven-ai-providers/releases" && pwd)
grep -Fq "Installing runtime from $releases/" "$tmp/install-source"
"$repo/clai" install --bin "$tmp/installed bin" >/dev/null
[ "$(find "$XDG_DATA_HOME/claude-driven-ai-providers/releases" -mindepth 1 -maxdepth 1 -type d|wc -l|tr -d ' ')" = 3 ]
printf 'PASS: registry, private credentials/config, precedence, argv, diagnostics, URL and permission guards, relocatable atomic installation\n'
