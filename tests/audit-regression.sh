#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-audit.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" XDG_DATA_HOME="$tmp/data"
mkdir -p "$HOME" "$tmp/bin"
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLCD_EFFORT CLCD_CONTEXT_TOKENS CLCD_MODEL
export CLAI_TEST_KEY_NAMES
CLAI_TEST_KEY_NAMES=$(jq -r '.providers[]|.key_env,.alt_env//empty|select(.!="")' "$repo/providers.json")
while IFS= read -r name; do export "$name=audit-fixture-key"; done <<<"$CLAI_TEST_KEY_NAMES"
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --help ]; then printf 'CLAUDE_OPTIONS\n'; exit; fi
while IFS= read -r name; do [ -z "${!name:-}" ]; done <<<"$CLAI_TEST_KEY_NAMES"
touch "$HOME/probe-file"
jq -cn --arg mask "$(umask)" --arg mode "$(stat -f '%Lp' "$HOME/probe-file")" --arg locale "${LC_ALL:-unset}" \
 --arg compact "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" --arg output "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-unset}" \
 --arg model "${ANTHROPIC_MODEL:-}" --arg opus "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" \
 '{mask:$mask,mode:$mode,locale:$locale,compact:$compact,output:$output,model:$model,opus:$opus}'
MOCK
chmod 700 "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH" LC_ALL=en_US.UTF-8
umask 022
for provider in deepseek openai; do
  rm -f "$HOME/probe-file"
  "$repo/clai" run "$provider" | jq -e '.mask=="0022" and .mode=="644" and .locale=="en_US.UTF-8"' >/dev/null
done
env -u LC_ALL "$repo/clai" run openai | jq -e '.locale=="unset"' >/dev/null
"$repo/clai" run deepseek | jq -e '.output=="unset"' >/dev/null
"$repo/clai" config set openai context 900001 >/dev/null
"$repo/clai" run openai | jq -e '.compact=="675000"' >/dev/null
CLAUDE_CODE_AUTO_COMPACT_WINDOW=150000 CLAI_OLLAMA_CONTEXT=broken "$repo/clai" config set ollama context 65537 >/dev/null
printf 'audit-fixture-key\n' | CLAUDE_CODE_AUTO_COMPACT_WINDOW=150000 "$repo/clai" key set ollama --stdin >/dev/null
"$repo/clai" config show ollama | jq -e '.compact==49152' >/dev/null
for provider in grok local deepseek; do
  if "$repo/clai" config set "$provider" effort high >/dev/null 2>&1; then echo "unsupported effort accepted: $provider"; exit 1; fi
done
if "$repo/clai" config set gemini effort xhigh >/dev/null 2>&1; then echo 'Gemini xhigh accepted'; exit 1; fi
"$repo/clai" config set openai effort xhigh >/dev/null
for protocol in anthropic chat; do
  "$repo/clai" config set local model fixture-local >/dev/null
  "$repo/clai" config set local protocol "$protocol" >/dev/null
  for host in 192.0.2.1 localhost; do
    "$repo/clai" config set local base_url "http://$host:19999" >/dev/null
    if "$repo/clai" run local >"$tmp/out" 2>"$tmp/error"; then echo 'authenticated nonnumeric HTTP accepted'; exit 1; fi
    grep -q loopback "$tmp/error"
  done
  for host in 127.0.0.1 '[::1]'; do
    "$repo/clai" config set local base_url "http://$host:19999" >/dev/null
    "$repo/clai" run local >/dev/null
  done
done
"$repo/clai" run deepseek --help | grep -q CLAUDE_OPTIONS
CLDS_MODEL=legacy-model CLAI_DEEPSEEK_MODEL=other "$repo/clai" run deepseek | jq -e '.model=="legacy-model"' >/dev/null
CLCD_TRANSPORT=openai "$repo/clcd" | jq -e '.mask=="0022" and .locale=="en_US.UTF-8"' >/dev/null
"$repo/clai" config set ollama model fixture-ollama >/dev/null
"$repo/clai" config set ollama protocol chat >/dev/null
jq '.effort="high"' "$XDG_CONFIG_HOME/claude-driven-ai-providers/providers/local.json" >"$tmp/local-profile"
install -m 600 "$tmp/local-profile" "$XDG_CONFIG_HOME/claude-driven-ai-providers/providers/local.json"
"$repo/clai" run ollama | jq -e '.model=="fixture-ollama"' >/dev/null
"$repo/clai" config unset local effort >/dev/null
"$repo/clai" config set openai max_output_tokens 8192 >/dev/null
"$repo/clai" config unset openai max_output_tokens >/dev/null
"$repo/clai" config show openai | jq -e '.max_output_tokens==4096' >/dev/null
mkdir "$tmp/runtime"
cp "$repo/clai" "$repo/providers.json" "$tmp/runtime/"
jq '(.providers[]|select(.id=="local-deepseek")) |= (.legacy_url_file="fixture-url"|.aliases.opus="fixture-opus")' "$repo/providers.json" >"$tmp/runtime/providers.json"
printf 'http://127.0.0.1:19999\n' >"$XDG_CONFIG_HOME/claude-driven-ai-providers/fixture-url"
chmod 600 "$XDG_CONFIG_HOME/claude-driven-ai-providers/fixture-url"
"$tmp/runtime/clai" run local-deepseek | jq -e '.opus=="fixture-opus" and .output=="4096"' >/dev/null
if CLCD_HEADER_TIMEOUT=invalid "$repo/clai" run openai >"$tmp/out" 2>"$tmp/error"; then echo 'invalid header timeout accepted'; exit 1; fi
grep -q 'header timeout' "$tmp/error"
printf 'PASS: caller environment, integer compaction, independent management, explicit effort, HTTP guards, help and precedence\n'
