#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-kimi-code.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'mock claude\n'; exit; fi
[ "${1:-}" = --dangerously-skip-permissions ]
[ "${2:-}" = --print ]
[ "${3:-}" = 'fixture' ]
[ "$ANTHROPIC_BASE_URL" = "$EXPECTED_URL" ]
[ "$CLAUDE_CONFIG_DIR" = "$EXPECTED_PROFILE" ]
[ "$ANTHROPIC_MODEL" = "$EXPECTED_MODEL" ]
[ -z "${CLAUDE_CODE_OAUTH_TOKEN+x}" ]
if [ "$EXPECTED_ROUTE" = membership ]; then
  [ "$ANTHROPIC_API_KEY" = "$EXPECTED_KEY" ]
  [ -z "${ANTHROPIC_AUTH_TOKEN+x}" ]
  [ -z "${KIMI_CODE_API_KEY+x}" ]
  [ -z "${MOONSHOT_API_KEY+x}" ]
  [ -z "${KIMI_API_KEY+x}" ]
  [ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" = 262144 ]
  [ "$CLAUDE_CODE_EFFORT_LEVEL" = high ]
  for name in ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
    [ "${!name}" = "$EXPECTED_MODEL" ]
  done
else
  [ -z "${ANTHROPIC_API_KEY+x}" ]
  [ "$ANTHROPIC_AUTH_TOKEN" = "$EXPECTED_KEY" ]
fi
MOCK
chmod 700 "$tmp/bin/claude"
jq -e '[.providers[]|.alias]|index("clkc")!=null' "$repo/providers.json" >/dev/null
"$repo/clai" prepare kimi-code --out "$tmp/.env-kimi-code" >/dev/null
grep -Fxq 'KIMI_CODE_API_KEY=' "$tmp/.env-kimi-code"
grep -Fxq 'BASE_URL=https://api.kimi.com/coding/' "$tmp/.env-kimi-code"
membership_key=$(openssl rand -hex 16)
sed "s/^KIMI_CODE_API_KEY=$/KIMI_CODE_API_KEY=$membership_key/" "$tmp/.env-kimi-code" >"$tmp/filled"
mv "$tmp/filled" "$tmp/.env-kimi-code"; chmod 600 "$tmp/.env-kimi-code"
"$repo/clai" setup --env "$tmp/.env-kimi-code" --dry-run >"$tmp/dry"
[ ! -e "$XDG_CONFIG_HOME/claude-driven-ai-providers/kimi-code-api-key" ]
! grep -q "$membership_key" "$tmp/dry"
"$repo/clai" setup --env "$tmp/.env-kimi-code" --no-install >"$tmp/applied"
! grep -q "$membership_key" "$tmp/applied"
[ "$(stat -f '%Lp' "$XDG_CONFIG_HOME/claude-driven-ai-providers/kimi-code-api-key")" = 600 ]
"$repo/clai" doctor kimi-code --network | jq -e '.provider=="kimi-code" and .state=="no-model-discovery-route" and .credential_source=="private-file"' >/dev/null
export EXPECTED_ROUTE=membership EXPECTED_URL=https://api.kimi.com/coding/ EXPECTED_PROFILE="$HOME/.claude-kimi-code"
export EXPECTED_MODEL=k3.1-pro EXPECTED_KEY="$membership_key"
MOONSHOT_API_KEY=separate-open-platform-key KIMI_API_KEY=separate-alias-key "$repo/clai" run kimi-code -- --print fixture
"$repo/clai" config set kimi-code base_url https://api.kimi.ai/coding/ >/dev/null
export EXPECTED_URL=https://api.kimi.ai/coding/
"$repo/clai" run clkc -- --print fixture
if "$repo/clai" config set kimi-code base_url https://example.com/coding/ >/dev/null 2>&1; then echo 'unofficial endpoint accepted'; exit 1; fi
"$repo/clai" config show kimi-code | jq -e '.base_url=="https://api.kimi.ai/coding/"' >/dev/null
if CLAI_KIMI_CODE_BASE_URL=https://example.com/coding/ "$repo/clai" run clkc -- --print fixture >/dev/null 2>&1; then echo 'unofficial environment endpoint accepted'; exit 1; fi
if "$repo/clai" config set clki base_url https://api.kimi.com/coding/ >/dev/null 2>&1; then echo 'Open Platform endpoint override accepted'; exit 1; fi
if "$repo/clai" config set kimi-code protocol chat >/dev/null 2>&1; then echo 'Kimi Code protocol override accepted'; exit 1; fi
"$repo/clai" config set kimi-code model k3-256k >/dev/null
export EXPECTED_MODEL=k3-256k
"$repo/clai" run kimi-code -- --print fixture
export EXPECTED_KEY=environment-membership-key
KIMI_CODE_API_KEY="$EXPECTED_KEY" "$repo/clai" run kimi-code -- --print fixture
"$repo/clai" config unset kimi-code model >/dev/null
export EXPECTED_MODEL=k3.1-pro EXPECTED_KEY="$membership_key"
printf 'PROVIDER=kimi-code\nKIMI_CODE_API_KEY=%s\nBASE_URL=https://example.com/coding/\n' "$membership_key" >"$tmp/invalid"
chmod 600 "$tmp/invalid"
if "$repo/clai" setup --env "$tmp/invalid" --dry-run >/dev/null 2>&1; then echo 'unofficial setup endpoint accepted'; exit 1; fi
export EXPECTED_ROUTE=open-platform EXPECTED_URL=https://api.moonshot.ai/anthropic EXPECTED_PROFILE="$HOME/.claude-kimi"
export EXPECTED_MODEL=kimi-k3 EXPECTED_KEY=separate-open-platform-key
MOONSHOT_API_KEY="$EXPECTED_KEY" KIMI_CODE_API_KEY="$membership_key" "$repo/clai" run clki -- --print fixture
printf 'PASS: Kimi Code membership route, regional allowlist, isolated credentials/profile, unchanged Open Platform route\n'
