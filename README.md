# Claude-driven AI providers

Use Claude Code with your chosen model provider: Codex subscription, OpenAI API,
DeepSeek, Gemini, Grok, or a local model server.

The `cl**` commands select the provider. `clai` handles setup, private credentials,
configuration, diagnostics, and installation. The runtime uses Bash, curl, jq,
and small protocol adapters. It does not depend on CLIProxyAPI, Sayso, or an SDK.

## Get started with Claude

**You fill a private setup file. Claude handles configuration and deployment.**

Clone the repository, then open it in Claude Code:

```bash
git clone https://github.com/xiaolai/claude-driven-ai-providers.git
cd claude-driven-ai-providers
```

Ask:

> Install this repository's clai-setup skill, prepare DeepSeek setup for me, and
> open the private template. Reuse my existing credentials and command directory.

Claude can install the skill from the checkout with `./clai skill install`.
After that, invoke it directly:

```text
/clai-setup deepseek
```

1. **Prepare.** Claude generates a private `.env-deepseek` template. An existing
   template is preserved.
2. **Fill.** Enter missing values in that file. Leave the key blank to reuse an
   existing credential. Keep credentials out of chat.
3. **Deploy.** Tell Claude: “Apply that setup file.” It validates the file, saves
   private settings, deploys commands into the selected PATH directory, installs
   the skill for the selected Claude profile, and runs connectivity diagnostics.

Ask for a tool check when you want generation verified too. This makes a live
model request and can incur API charges. Connectivity alone does not establish
that a model can use Claude's tools.

The skill follows [Claude Code's skill format](https://code.claude.com/docs/en/skills).
You can also use the commands directly; both paths use the same setup logic.

### Requirements

Currently supported on **macOS** with Bash 3.2, Claude Code, curl, jq, and openssl.
Bridge routes also need socat. The Codex subscription route additionally needs
Codex CLI, macOS lockf, and a ChatGPT subscription login through `codex login`.
Ask Claude to check these prerequisites before setup. Linux is not qualified.

### Which Claude executable runs

Launchers use the first `claude` executable on their inherited `PATH`.
`clai doctor PROVIDER` reports `claude.executable`, its resolved symlink target,
version (null if unavailable), and the installations found on PATH. Multiple
installations produce a warning in the JSON `warnings` array. Diagnostics inspect
the invoking process's environment; a fresh terminal may have a different PATH.

To select an executable explicitly for every provider launcher:

```bash
export CLAI_CLAUDE_BIN="$HOME/.local/bin/claude"
clai doctor deepseek
```

The override must be an absolute path to an executable file. An invalid override
fails rather than selecting another installation. It also applies to standalone
`clcd`, `clds`, and `cldls`.

On macOS, `/etc/zprofile` runs `path_helper` before your `~/.zprofile`, and can
reorder PATH entries set earlier in `~/.zshenv`. If you want `~/.local/bin` first
in login shells, put `export PATH="$HOME/.local/bin:$PATH"` after other PATH setup
in `~/.zprofile`, then verify with a fresh login shell. Setup does not edit shell
profiles.

Install from the checkout on each destination machine. Generated launchers
contain absolute paths to that installation's runtime; copying them to another
machine or moving the runtime can leave stale paths. Run `./clai install` on the
destination to generate its launchers.

## Choose a provider

| Provider ID | Command | Credential or service |
| --- | --- | --- |
| `codex` | `clcd` | Existing Codex ChatGPT subscription login |
| `openai` | `cloa` | `OPENAI_API_KEY`; separately billed OpenAI Platform API |
| `deepseek` | `clds` | `DEEPSEEK_API_KEY` |
| `gemini` | `clgm` | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| `grok` | `clgr` | `XAI_API_KEY` |
| `local-deepseek` | `cldls` | Existing privately configured DeepSeek gateway |
| `local` | `cllm` | Custom server URL/model; optional `LOCAL_API_KEY` |
| `ollama` | `clol` | Running Ollama server and installed model; optional `OLLAMA_API_KEY` |
| `lmstudio` | `clms` | Running LM Studio server and loaded model; optional `LM_API_TOKEN` |
| `minimax` | `clmm` | `MINIMAX_API_KEY` |
| `zai` | `clza` | `ZAI_API_KEY` for the documented Coding Plan endpoint |
| `kimi` | `clki` | `MOONSHOT_API_KEY` or `KIMI_API_KEY` |

`cllds` remains a compatibility alias for `cldls`. Each provider has an isolated
Claude profile. There is no automatic provider or billing fallback: `clcd` uses
the subscription route, while `cloa` uses API billing.

**The launchers start Claude with `--dangerously-skip-permissions`.** This retains
the original launch behavior; run them only in a working directory you intend
Claude to operate on. They preserve the caller's umask and locale.

### Verification status

Recorded on **2026-10-27**, using the development machine's available accounts:

| Routes | Evidence |
| --- | --- |
| Codex, OpenAI API, DeepSeek API | Live Bash tool round trips passed |
| Gemini | Mock streaming/signature replay tests passed; verify live model access during setup |
| Grok | Mock Responses tests passed; verify live model access during setup |
| Custom local Chat | Mock bridge tests passed; your server/model still needs a tool check |
| Ollama, LM Studio | Official native routes configured; no live local server qualified |
| MiniMax, Z.AI, Kimi | Official native routes registered; no live credential qualification |

These are measured implementation results, not guarantees about another account
or model. Official endpoint and authentication sources are recorded in the
[provider registry](providers.json).

## The setup file

`clai prepare PROVIDER` creates a mode-600 file under:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/claude-driven-ai-providers/setup/.env-PROVIDER
```

For example, a DeepSeek setup file looks like this. `BIN_DIR` is normally filled
with the detected command directory; the example uses the supported `~/` form.

```dotenv
PROVIDER=deepseek
DEEPSEEK_API_KEY=
MODEL=deepseek-flash
CONTEXT_TOKENS=1000000
AUTO_COMPACT_TOKENS=
EFFORT=
MAX_OUTPUT_TOKENS=
BIN_DIR=~/.local/bin
MAPPING_STRATEGY=
```

- Fill the key only if no working key is already configured.
- Blank optional fields preserve stored settings or registry defaults. A blank
  compaction field does not erase an existing explicit compaction setting.
- Local templates also include `BASE_URL` and `PROTOCOL`.
- Values are literal single-line data, with optional matching outer quotes.
  There is no shell evaluation, variable interpolation, `export`, or inline
  comment syntax. `~/` is expanded for paths; `$HOME` text is not.
- Templates never copy existing keys and are never overwritten. Filled files
  must stay private; the input is retained for reuse.

### Commands for automation

Before installation, use `./clai` from this checkout. After installation, use
`clai` from any directory:

```bash
clai prepare deepseek
clai setup --env ~/.config/claude-driven-ai-providers/setup/.env-deepseek --dry-run
clai setup --env ~/.config/claude-driven-ai-providers/setup/.env-deepseek
```

| Setup option | Behavior |
| --- | --- |
| `--dry-run` | Validate without writing, deploying, or contacting a provider |
| `--probe` | Discover models using the filled file, without saving settings or deploying; writes only private inventory cache |
| `--no-install` | Save private settings without deploying commands or skills; still run diagnostics |
| `--check-tools` | Also run a bounded live generation/tool check |

Use `clai prepare PROVIDER --out FILE` for a different template location.
Unknown/duplicate fields, unsafe file permissions, invalid settings, and a
conflicting explicit key/environment key are rejected before configuration
changes. Cloud endpoints are pinned to their registered official URLs.

Saving credentials, saving config, and deploying commands are separate steps.
If deployment or diagnostics fail, earlier saved settings can remain; fix the
reported issue and rerun. A blocked provider is not reported as ready for live
generation. Setup does not edit PATH or shell startup files.

## Run and manage

After setup, start the chosen command in your project:

```bash
clds
clcd --continue
cloa --model YOUR_MODEL
```

Claude arguments are forwarded literally. Launcher `--help` shows usage;
managed launchers also show Claude's options. For the complete management
interface, run `clai --help`.

| Command | Purpose |
| --- | --- |
| `clai list` | Show provider IDs, aliases, protocols, and default models |
| `clai doctor` | Inspect configuration and dependencies without network requests |
| `clai doctor openai --network` | Run available discovery/login diagnostics without generation |
| `clai models openai` | Discover models where the provider documents a model-list endpoint |
| `clai check openai --tools` | Require a live text response and tool turn |
| `clai config show openai` | Show stored/default settings, excluding keys |
| `clai config set openai model YOUR_MODEL` | Change a non-secret setting |
| `clai config unset openai model` | Remove an override |
| `clai key set openai` | Store a key using hidden terminal input |

Key storage also accepts `--stdin` for a secret-manager pipeline. Live checks run
in a temporary directory with MCP disabled and no saved Claude session.

### Context, output, and effort

Cloud routes declare **1,000,000 tokens**, with default compaction at **750,000**.
Local routes start at **32,768 / 24,576**. These are Claude's declared windows;
they do not increase a backend's real capacity. Match local settings to the
server's allocated context. Derived compaction is rounded down to an integer.

API bridge output defaults to 4,096 tokens. Native routes retain provider/Claude
defaults unless capped; the existing local DeepSeek gateway keeps its 4,096
default. Subscription `max_tokens` remains advisory. Set `max_output_tokens`
within the selected model's actual limits when needed.

The manager's `effort` setting accepts `low/medium/high/xhigh` for Codex/OpenAI
and `low/medium/high` for Gemini. Other routes reject that manager field. Native
Claude's own `--effort` flag can be forwarded when the provider supports it.

Launch precedence is environment override → private JSON → registry default.
Supported environment names include `CLAI_OPENAI_MODEL` and
`CLAI_LOCAL_DEEPSEEK_CONTEXT`. Legacy `CLCD_*`, `CLDS_MODEL`, and
`CLDLS_*`/`CLLDS_*` overrides retain precedence over their corresponding `CLAI_*`
values. `CLAUDE_CODE_AUTO_COMPACT_WINDOW` overrides launch compaction. Config/key
administration ignores launch-time overrides so they cannot prevent repairs.

## Discover models and map Claude roles

Ask Claude:

> Probe my available models, propose a balanced mapping, show what is unknown,
> and apply the mapping I choose. Keep my provider and billing route.

```bash
clai probe openai
clai map openai --strategy balanced
clai map openai --strategy balanced --apply
```

`probe` returns normalized JSON with model IDs, reported context/output limits,
capabilities, exclusions and observation time. It follows documented pagination
for Codex and Gemini; local discovery uses installed/loaded model metadata.
Providers without a model-list endpoint return `catalog-only`, explicitly
unverified. Unknown capabilities remain `null`. A listed model can still fail
because of access, quota, tool compatibility or server configuration.

| Strategy | Role selection |
| --- | --- |
| `single` | One configured/default model for every role |
| `quality` | One model from the quality tier for every role |
| `balanced` | Opus/Fable → quality; Sonnet/custom → standard; Haiku/subagent → fast |
| `economy` | One model from the fast tier for every role |
| `manual` | Explicit role IDs; unspecified roles use the selected default |

Automatic tiers use provider defaults and model-name hints. They are proposals,
with no measured price, speed or quality ranking. Missing tiers are reported in
`collapsed_tiers`; inspect the proposal and override selections when needed:

```bash
clai map openai --strategy balanced --quality MODEL_ID --standard MODEL_ID --fast MODEL_ID
clai map openai --strategy manual --opus MODEL_ID --sonnet MODEL_ID --haiku MODEL_ID
clai probe openai --model MODEL_ID --check-tools
```

Only `--apply` saves a mapping. Add `--check-tools` to `map` to test each distinct
selected model before saving; these bounded generation/tool calls can incur API
charges. Without checks, the proposal remains `unverified`. Known context/output
limits and common reasoning efforts constrain launches; missing metadata never
establishes that a model supports 1M context. Full Claude family IDs and role
aliases are translated on bridge routes; explicit provider IDs pass through.

Discovery caches are private and scoped to endpoint and credential/account.
`probe --cached` and `map --cached` explicitly use an earlier snapshot; their
observation time remains visible. Codex still checks the logged-in account.
Fresh failures never silently return cached success. A fresh probe resets tool
qualification because it is a new observation.

Prepared setup files support `MAPPING_STRATEGY`, `QUALITY_MODEL`,
`STANDARD_MODEL`, `FAST_MODEL`, and `OPUS_MODEL`, `FABLE_MODEL`, `SONNET_MODEL`,
`HAIKU_MODEL`, `SUBAGENT_MODEL`, `CUSTOM_MODEL`. Blank strategy preserves an
existing mapping. With a strategy, setup discovers and validates before saving;
`--dry-run` stays offline and reports discovery pending. To discover with a new
filled key before saving it, Claude can use `clai setup --env FILE --probe`.
Remove a mapping with `clai config unset PROVIDER mapping`; the last default
model remains configured.

## Local models

Ask Claude to prepare `ollama`, `lmstudio`, or `local` setup using an already
running server and a loaded, tool-capable model. It can discover model IDs with
`clai models PROVIDER`. Model downloads and server startup are separate work.

Ollama and LM Studio use their documented native Anthropic endpoints. For a
custom Chat Completions server, the relevant setup fields are:

```dotenv
PROVIDER=local
LOCAL_API_KEY=
BASE_URL=http://127.0.0.1:8080
PROTOCOL=chat
MODEL=your-loaded-model
CONTEXT_TOKENS=32768
BIN_DIR=~/.local/bin
```

Use a server root for `BASE_URL`; a trailing `/v1` is also accepted for Chat.
Authenticated plain HTTP is restricted to numeric loopback (`127.0.0.1` or
`[::1]`). Remote authenticated servers need HTTPS. Discovery alone does not
establish reliable tool use; run a live tool check against the chosen model.

## Private data and installation

Credentials come from the provider's environment variable, then its private key
file. Private configuration lives under
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-driven-ai-providers/`. Key/config writes
are atomic, using private file permissions. Broadly accessible, foreign-owned,
or symlinked private files are rejected. Keep filled templates at mode `600`;
`.env-*` is ignored by this repository and generated outside it by default.

Run `./clai install` from the checkout to deploy source updates. The default
destination is `~/.local/bin`; `--bin DIRECTORY` selects another directory.
Setup instead uses the template's `BIN_DIR`, detected from existing commands
when preparing it. The installer prints its source: invoking an installed
`clai install` copies that installed bundle, not later checkout edits.

Release bundles live under
`${XDG_DATA_HOME:-$HOME/.local/share}/claude-driven-ai-providers/releases/`.
Each command is replaced atomically. Older bundles remain so active sessions
keep their loaded version; new launches pick up the update.

For older standalone `clds`/`cllds` installations, keep key files private before
migrating. Managed DeepSeek uses the base model name and 1M/750k settings instead
of the old `[1m]` suffix and 786432 compaction. Managed `cldls` replaces the old
blocking `/health` preflight with explicit `clai doctor local-deepseek --network`
diagnostics. The existing private key and local URL files remain supported.

The setup skill is installed under `~/.claude/skills/clai-setup/` and, during
setup, in the selected provider profile. Use `clai skill install --profile ID`
for another profile or `--dir DIRECTORY` for an explicit skill destination.

## How it works and current limits

```text
Claude Code → provider's native Anthropic endpoint
Claude Code → local clcd bridge → Responses endpoint
Claude Code → local clcd bridge + jq adapters → Chat Completions endpoint
```

The [registry](providers.json) selects the route. Codex/OpenAI/Grok use Responses;
Gemini uses Chat compatibility; documented native providers connect directly.
`clcd` remains a standalone Bash file for its default Codex route and the
OpenAI/Grok Responses routes. Gemini/local Chat require the bundled jq adapters.
The full command family is an installed bundle. Source `clds`/`cldls` retain
their legacy standalone fallback with `CLAI_STANDALONE=1`.

Bridge limits include approximate token counting, partial Messages compatibility,
and rejection of unsupported sampling, stop, schema, fixed-thinking-budget, and
hosted-tool controls. Disabling parallel tools is unsupported on Chat routes.
Image round trips, near-limit compaction, quota exhaustion, and sustained
concurrency remain unqualified. Native routes inherit their provider's limits.

Gemini tool replay needs both its Claude history and private signature cache
under `${XDG_CACHE_HOME:-$HOME/.cache}/claude-driven-ai-providers/gemini/`.
Missing metadata fails explicitly. The cache is not automatically pruned because
that could break resumed conversations.

The subscription bridge depends on Codex's current authentication RPC/backend.
Response-header waiting defaults to 120 seconds (`CLCD_HEADER_TIMEOUT=1..600`);
total upstream requests have a 600-second timeout.
