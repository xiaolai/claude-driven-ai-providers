#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
shellcheck -S warning "$repo/clai" "$repo/setup.sh" "$0"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clai-setup.XXXXXXXX")
tmp=$(cd "$tmp" && pwd)
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME" "$tmp/bin" "$tmp/existing bin"
unset DEEPSEEK_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY XAI_API_KEY LOCAL_API_KEY CLAUDE_CODE_AUTO_COMPACT_WINDOW
export PATH="$tmp/existing bin:$tmp/bin:$PATH"
printf '#!/bin/bash\nexit 0\n' >"$tmp/existing bin/clai"
cat >"$tmp/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
args=("$@"); file=''
for ((i=0;i<${#args[@]};i++));do [ "${args[$i]}" != -o ] || file=${args[$((i+1))]};done
if [ "${SETUP_HTTP:-200}" = 400 ];then printf '{"error":{"message":"location unsupported"}}' >"$file";printf 400
else printf '{"data":[{"id":"fixture-model"}]}' >"$file";printf 200;fi
MOCK
cat >"$tmp/bin/claude" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --help ];then printf 'CLAUDE_OPTIONS\n';exit;fi
if [[ "${!#}" == *CLAI_OK_* ]];then
  [[ "${!#}" =~ CLAI_OK_[0-9a-f]+ ]]
  jq -cn --arg result "${BASH_REMATCH[0]}" '{result:$result,is_error:false,num_turns:2}'
else [ "$ANTHROPIC_MODEL" = "$SETUP_EXPECT_MODEL" ];[ "$ANTHROPIC_AUTH_TOKEN" = "$SETUP_EXPECT_KEY" ];fi
MOCK
chmod 700 "$tmp/existing bin/clai" "$tmp/bin/"*
"$repo/clai" prepare deepseek --out "$tmp/.env-deepseek" >"$tmp/output"
[ "$(stat -f '%Lp' "$tmp/.env-deepseek")" = 600 ]
grep -Fxq 'DEEPSEEK_API_KEY=' "$tmp/.env-deepseek"
grep -Fxq "BIN_DIR=$tmp/existing bin" "$tmp/.env-deepseek"
if "$repo/clai" prepare deepseek --out "$tmp/.env-deepseek" >/dev/null 2>&1;then echo 'template overwritten';exit 1;fi
key=$(openssl rand -hex 16)
export SETUP_EXPECT_KEY="$key" SETUP_EXPECT_MODEL=fixture-model
awk -v key="$key" '/^DEEPSEEK_API_KEY=/{print "DEEPSEEK_API_KEY="key;next}/^MODEL=/{print "MODEL=fixture-model";next}{print}' "$tmp/.env-deepseek" >"$tmp/filled"
mv "$tmp/filled" "$tmp/.env-deepseek";chmod 600 "$tmp/.env-deepseek"
"$repo/clai" setup --env "$tmp/.env-deepseek" --dry-run >"$tmp/dry"
test ! -e "$XDG_CONFIG_HOME/claude-driven-ai-providers/deepseek-api-key"
! grep -q "$key" "$tmp/dry"
"$repo/clai" setup --env "$tmp/.env-deepseek" >"$tmp/applied"
! grep -q "$key" "$tmp/applied"
[ "$(stat -f '%Lp' "$XDG_CONFIG_HOME/claude-driven-ai-providers/deepseek-api-key")" = 600 ]
(cd "$tmp"; "$tmp/existing bin/clds" --print fixture)
test -f "$HOME/.claude/skills/clai-setup/SKILL.md"
test -f "$HOME/.claude-deepseek/skills/clai-setup/SKILL.md"
"$tmp/existing bin/clai" prepare deepseek --out "$tmp/.env-again" >/dev/null
grep -Fxq 'DEEPSEEK_API_KEY=' "$tmp/.env-again"
! grep -q "$key" "$tmp/.env-again"
"$tmp/existing bin/clai" setup --env "$tmp/.env-again" --no-install --check-tools >/dev/null
sed 's/^MAPPING_STRATEGY=$/MAPPING_STRATEGY=balanced/' "$tmp/.env-again" >"$tmp/updated-env"
cat "$tmp/updated-env" >"$tmp/.env-again"
"$repo/clai" setup --env "$tmp/.env-again" --dry-run|jq -e '.mapping_state=="pending-live-discovery"' >/dev/null
"$repo/clai" setup --env "$tmp/.env-again" --probe|jq -e '.models[0].id=="fixture-model"' >/dev/null
"$repo/clai" setup --env "$tmp/.env-again" --check-tools >"$tmp/mapped"
"$repo/clai" config show deepseek|jq -e '.mapping.strategy=="balanced" and .mapping.models.opus=="fixture-model" and .mapping.verification=="tool-verified"' >/dev/null
cp "$tmp/.env-again" "$tmp/bad";chmod 600 "$tmp/bad"
printf 'MODEL=$(touch %s/executed)\n' "$tmp" >"$tmp/literal"
printf 'PROVIDER=deepseek\nBIN_DIR=%s\n' "$tmp/existing bin" >>"$tmp/literal";chmod 600 "$tmp/literal"
"$repo/clai" setup --env "$tmp/literal" --dry-run >/dev/null
test ! -e "$tmp/executed"
printf 'PROVIDER="deepseek"\r\nMODEL=\x27fixture-model\x27\r\nBIN_DIR=~/.local/bin\r\n' >"$tmp/quoted";chmod 600 "$tmp/quoted"
"$repo/clai" setup --env "$tmp/quoted" --dry-run | jq -e --arg bin "$HOME/.local/bin" '.bin_dir==$bin' >/dev/null
old_config=$(openssl dgst -sha256 "$XDG_CONFIG_HOME/claude-driven-ai-providers/providers/deepseek.json")
printf 'PROVIDER=deepseek\nBASE_URL=https://example.com\n' >"$tmp/cloud";chmod 600 "$tmp/cloud"
if "$repo/clai" setup --env "$tmp/cloud" >/dev/null 2>&1;then echo 'unofficial cloud destination accepted';exit 1;fi
[ "$(openssl dgst -sha256 "$XDG_CONFIG_HOME/claude-driven-ai-providers/providers/deepseek.json")" = "$old_config" ]
printf 'PROVIDER=local\nBASE_URL=http://192.0.2.1:8080\nMODEL=fixture\nAPI_KEY=fixture-secret\n' >"$tmp/local";chmod 600 "$tmp/local"
if "$repo/clai" setup --env "$tmp/local" --dry-run >/dev/null 2>&1;then echo 'remote authenticated HTTP accepted';exit 1;fi
printf 'http://127.0.0.1:19999\n' >"$XDG_CONFIG_HOME/claude-driven-ai-providers/cldls-base-url";chmod 600 "$XDG_CONFIG_HOME/claude-driven-ai-providers/cldls-base-url"
printf 'PROVIDER=local-deepseek\n' >"$tmp/gateway";chmod 600 "$tmp/gateway"
"$repo/clai" setup --env "$tmp/gateway" --dry-run >/dev/null
for extra in 'MODEL=duplicate' 'UNKNOWN=sensitive-value' 'API_KEY=other';do
  cat "$tmp/.env-deepseek" >"$tmp/bad";printf '%s\n' "$extra" >>"$tmp/bad"
  if "$repo/clai" setup --env "$tmp/bad" --dry-run >/dev/null 2>&1;then echo 'invalid env input accepted';exit 1;fi
done
chmod 644 "$tmp/bad"
if "$repo/clai" setup --env "$tmp/bad" --dry-run >/dev/null 2>&1;then echo 'public env accepted';exit 1;fi
ln -s "$tmp/.env-deepseek" "$tmp/link"
if "$repo/clai" setup --env "$tmp/link" --dry-run >/dev/null 2>&1;then echo 'symlink env accepted';exit 1;fi
if DEEPSEEK_API_KEY=different-fixture-key "$repo/clai" setup --env "$tmp/.env-deepseek" --dry-run >/dev/null 2>&1;then echo 'key override conflict accepted';exit 1;fi
if SETUP_HTTP=400 "$repo/clai" setup --env "$tmp/.env-again" --no-install >"$tmp/failed-mapping";then echo 'failed discovery applied mapping';exit 1;fi
[ "$(openssl dgst -sha256 "$XDG_CONFIG_HOME/claude-driven-ai-providers/providers/deepseek.json")" = "$old_config" ]
if SETUP_HTTP=400 "$repo/clai" setup --env "$tmp/.env-deepseek" --no-install >"$tmp/blocked";then echo 'blocked provider reported ready';exit 1;fi
grep -q provider-location-blocked "$tmp/blocked"
mkdir "$tmp/manual-skill";printf 'user skill\n' >"$tmp/manual-skill/SKILL.md"
if "$repo/clai" skill install --dir "$tmp/manual-skill" >/dev/null 2>&1;then echo 'foreign skill overwritten';exit 1;fi
grep -Fxq 'user skill' "$tmp/manual-skill/SKILL.md"
"$repo/clai" skill install >/dev/null
cmp "$repo/skills/clai-setup/SKILL.md" "$HOME/.claude/skills/clai-setup/SKILL.md"
git -C "$repo" check-ignore -q .env-deepseek
printf 'PASS: prepared private templates, literal parser, key reuse/import, PATH deployment, installed skill, dry-run and blocked diagnostics\n'
