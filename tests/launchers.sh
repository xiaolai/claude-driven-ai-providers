#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/provider-launchers.XXXXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
for launcher in clcd clds cldls; do
  bash -n "$repo/$launcher"
  shellcheck -S warning "$repo/$launcher"
done
mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/config/claude-driven-ai-providers"
cat >"$test_dir/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
[ "$CLAUDE_CONFIG_DIR" = "$EXPECTED_PROFILE" ]
[ "$ANTHROPIC_BASE_URL" = "$EXPECTED_URL" ]
[ -z "${ANTHROPIC_API_KEY+x}" ]
[ -z "${CLAUDE_CODE_OAUTH_TOKEN+x}" ]
[ "$1" = --dangerously-skip-permissions ]
[ "$2" = --print ]
[ "$3" = "$EXPECTED_PROMPT" ]
if [ "$CHECK_PROVIDER" = deepseek ]; then
  [ "$ANTHROPIC_AUTH_TOKEN" = "$EXPECTED_KEY" ]
  [ "$ANTHROPIC_MODEL" = 'deepseek-flash[1m]' ]
else
  [ -n "$ANTHROPIC_AUTH_TOKEN" ]
  [ "${ANTHROPIC_MODEL:-}" = "$EXPECTED_MODEL" ]
  [ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" = "$EXPECTED_CONTEXT" ]
fi
MOCK
cat >"$test_dir/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
[ "${!#}" = "$EXPECTED_URL/health" ]
MOCK
chmod 700 "$test_dir/bin/claude" "$test_dir/bin/curl"
export CLAI_STANDALONE=1
export HOME="$test_dir/home" XDG_CONFIG_HOME="$test_dir/config" PATH="$test_dir/bin:$PATH"
export EXPECTED_PROMPT='a literal argument with spaces and $characters'
export ANTHROPIC_API_KEY=discard-this CLAUDE_CODE_OAUTH_TOKEN=discard-this
export CHECK_PROVIDER=deepseek EXPECTED_PROFILE="$HOME/.claude-deepseek"
export EXPECTED_URL=https://api.deepseek.com/anthropic
export EXPECTED_KEY
EXPECTED_KEY=$(openssl rand -hex 16)
DEEPSEEK_API_KEY="$EXPECTED_KEY" "$repo/clds" --print "$EXPECTED_PROMPT"
# A configuration value is data: this string must never execute as shell code.
EXPECTED_KEY="\$(touch $test_dir/executed)"
printf '%s\n' "$EXPECTED_KEY" >"$XDG_CONFIG_HOME/claude-driven-ai-providers/deepseek-api-key"
env -u DEEPSEEK_API_KEY "$repo/clds" --print "$EXPECTED_PROMPT"
test ! -e "$test_dir/executed"
export CHECK_PROVIDER=local EXPECTED_PROFILE="$HOME/.claude-lds"
export EXPECTED_URL=http://127.0.0.1:8331 EXPECTED_MODEL='' EXPECTED_CONTEXT=32768
printf '%s\n' "$EXPECTED_URL" >"$XDG_CONFIG_HOME/claude-driven-ai-providers/cldls-base-url"
env -u CLDLS_BASE_URL -u CLLDS_BASE_URL -u CLDLS_MODEL -u CLLDS_MODEL -u CLDLS_CONTEXT_TOKENS -u CLLDS_CONTEXT_TOKENS "$repo/cldls" --print "$EXPECTED_PROMPT"
export EXPECTED_URL=http://127.0.0.1:8332 EXPECTED_MODEL=cyberneurova-low EXPECTED_CONTEXT=65536
CLLDS_BASE_URL="$EXPECTED_URL" CLLDS_MODEL="$EXPECTED_MODEL" CLLDS_CONTEXT_TOKENS="$EXPECTED_CONTEXT" "$repo/cldls" --print "$EXPECTED_PROMPT"
CLDLS_BASE_URL="$EXPECTED_URL" CLLDS_BASE_URL=http://127.0.0.1:8333 CLDLS_MODEL="$EXPECTED_MODEL" CLLDS_MODEL=cyberneurova-high CLDLS_CONTEXT_TOKENS="$EXPECTED_CONTEXT" CLLDS_CONTEXT_TOKENS=16384 "$repo/cldls" --print "$EXPECTED_PROMPT"
mv "$test_dir/bin/claude" "$test_dir/bin/Claude Code"
export CLAI_CLAUDE_BIN="$test_dir/bin/Claude Code"
CLDLS_BASE_URL="$EXPECTED_URL" CLDLS_MODEL="$EXPECTED_MODEL" CLDLS_CONTEXT_TOKENS="$EXPECTED_CONTEXT" "$repo/cldls" --print "$EXPECTED_PROMPT"
printf 'PASS: launcher syntax, ShellCheck, private data loading, provider/profile/argument preservation, new and legacy local-provider overrides\n'
