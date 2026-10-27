def canonical: if $inventory[0].provider=="gemini" then sub("^models/";"") else . end;
def version: [scan("[0-9]+")|tonumber];
def pick($tier;$pool):
  ($pool|map(select(.tier_hint==$tier))) as $matched |
  (if ($matched|length)==0 then $pool else $matched end)|sort_by([(.tier_hint==$tier),(.id==$cfg.model or .is_default),(.id|version),.id])|last|.id;
($inventory[0]) as $inv |
if ($strategy|IN("single","quality","balanced","economy","manual")|not) then error("Unknown mapping strategy") else . end |
[$inv.models[]|select(.eligible)] as $pool |
if ($pool|length)==0 then error("No eligible text/tool models; inspect probe exclusions") else . end |
([ $pool[]|select(.id==$cfg.model or .is_default) ][0].id // pick("standard";$pool)) as $base |
($choices.standard // (if $strategy=="single" or $strategy=="manual" then ($choices.model//$cfg.model|select(.!="")) else null end) // $base |canonical) as $standard |
($choices.quality // pick("quality";$pool)|canonical) as $quality |
($choices.fast // pick("fast";$pool)|canonical) as $fast |
(if $strategy=="quality" then $quality elif $strategy=="economy" then $fast else $standard end) as $default |
{opus:(if $strategy=="balanced" then $quality else $default end),fable:(if $strategy=="balanced" then $quality else $default end),
 sonnet:$default,haiku:(if $strategy=="balanced" then $fast else $default end),subagent:(if $strategy=="balanced" then $fast else $default end),custom:$default} |
if $strategy=="manual" then .+($choices|with_entries(select(.key|IN("opus","fable","sonnet","haiku","subagent","custom")))|map_values(canonical)) else . end |
. as $roles | ([$roles[]]|unique) as $ids |
[$ids[] as $id|$pool[]|select(.id==$id)] as $selected |
if ($selected|length)!=($ids|length) then error("Mapping contains an unlisted or ineligible model") else . end |
([$selected[]|.input_tokens|select(.!=null)]|if length==0 then null else min end) as $context |
([$selected[]|.output_tokens|select(.!=null)]|if length==0 then null else min end) as $output |
([$selected[]|.reasoning_efforts|select(.!=null)]) as $known_efforts |
(if ($cfg.effort_levels//[]|length)==0 or ($known_efforts|length)==0 then null
 else reduce $known_efforts[] as $levels ($cfg.effort_levels; [.[]|select(. as $v|$levels|index($v)!=null)]) end) as $efforts |
if $efforts!=null and ($efforts|length)==0 then error("Selected models share no bridge-supported reasoning effort") else . end |
{strategy:$strategy,models:$roles,bounds:{context_tokens:$context,output_tokens:$output,effort_levels:$efforts},
 default_effort:(if $efforts==null then null elif ($efforts|index("medium"))!=null then "medium" else $efforts[0] end),
 observed_at:$inv.observed_at,inventory_scope:$inv.scope,inventory_state:$inv.state,
 verification:(if all($selected[];.checks.tools=="passed") then "tool-verified" else "unverified" end),
 selection_basis:"Provider defaults, explicit overrides and model-name hints; no measured price, latency or quality ranking",
 collapsed_tiers:(["quality","standard","fast"]|map(. as $tier|select(any($pool[];.tier_hint==$tier)|not))),
 unknown_capabilities:[$selected[]|select(.capabilities.tools==null or .input_tokens==null)|.id]}
