---
name: clai-setup
description: Prepare or apply private .env-provider setup files for the clai Claude Code provider command family, deploying launchers to the user's existing PATH directory. Use for clcd/clds/cloa/clgm/clgr/local provider setup, not general shell or API application setup.
---

<!-- managed-by: claude-driven-ai-providers -->

# Provider setup for the user

The user delegates configuration and deployment to Claude. Carry out the
authorized setup; do not leave them a list of commands to perform manually.

Find `clai` on PATH and inspect `clai --help` and `clai list`. If a checkout was
provided, use its `./clai` to deploy updated code; an installed clai snapshots its
own bundle. Keep the chosen provider and subscription/API billing route explicit.

For a new setup, run `clai prepare PROVIDER`. It prints the private `.env-PROVIDER`
path and fills the existing command directory/model/context defaults. It never
copies keys. Tell the user to fill only missing values in that file. Blank key
fields reuse existing environment/private credentials, so do not require them
to reenter a working key. Open the file in their editor when the tool is
available. Never ask them to paste credentials in chat.
If the template already exists, preserve it and reuse
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-driven-ai-providers/setup/.env-PROVIDER`
(or the user's explicit path). Open it without reading its contents into chat;
do not overwrite it or ask the user to repeat completed setup work.

When the user supplies a filled file, do not Read/cat/source it or include it in
a prompt. Check ownership/type/permissions using metadata only; tighten a
user-owned regular file to mode 600 when needed. Do not follow a symlink or
change a foreign-owned file. Run `clai setup --env ABSOLUTE_FILE --dry-run`, then apply with
`clai setup --env ABSOLUTE_FILE`. The latter imports private settings, deploys
into BIN_DIR, installs this skill for normal and selected-profile Claude, and
runs non-generation network diagnostics. This request authorizes those routine
steps. Use `--no-install` only when the user requests configuration alone.

For model selection, use `clai probe PROVIDER` and `clai map PROVIDER
--strategy balanced` to inspect current normalized metadata and a proposal.
With an unsaved filled key use `clai setup --env ABSOLUTE_FILE --probe`, keeping
the file opaque. Report missing capabilities, catalog-only evidence and
collapsed tiers. Name hints are advisory, never measured cost/quality claims.
Choose single/quality/balanced/economy/manual according to the user's preference;
show the proposed role IDs before applying. `clai map PROVIDER --strategy ...
--apply` saves it. Use tier overrides (--quality/--standard/--fast) or manual
role overrides (--opus/--fable/--sonnet/--haiku/--subagent/--custom) when needed.
For prepared-file setup, set the corresponding non-secret MAPPING_STRATEGY,
QUALITY_MODEL/STANDARD_MODEL/FAST_MODEL or role MODEL fields with an atomic
transformation. Blank strategy preserves existing mapping; dry-run reports
pending discovery. Never guess that an unknown model supports tools or 1M.
Fresh probes do not silently fall back to old caches; --cached is explicit.

Use `--check-tools` when tool verification is requested; it makes a bounded live
model call and can incur API charges. A mapping check tests every distinct
selected model, and a failed check leaves verification unresolved. Otherwise report only the observed
configuration/reachability status. Region/billing/login failures are unresolved
provider conditions, not a successful live qualification; do not bypass them or
switch providers. For missing models use `clai models PROVIDER`; for missing
local servers ask which already running server/model to use. Do not silently
download weights, start services, create accounts or change billing.

If input fails validation, report the field/line error without displaying the
file. Let the user edit secret fields privately. Correct non-secret defaults
with clai config before preparing a file. If a filled file needs a non-secret
correction, use a data-only shell transformation with an atomic mode-600
replacement, without displaying the source or passing credentials as arguments.
An obsolete effort override can be removed with `clai config unset
PROVIDER effort`. Environment overrides can still affect future launches; report
any conflict and resolve the launch environment explicitly without printing it.

Summarize provider, installed command/destination, credential source (never its
value), diagnostics and whether tool use was measured. Preserve the private
input for reuse. Do not commit or upload filled setup files. Do not commit source
changes, push, rotate keys or restart another project session without a request.
