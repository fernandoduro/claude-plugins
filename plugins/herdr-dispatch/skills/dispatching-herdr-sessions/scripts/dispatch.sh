#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
dispatch.sh <manifest.tsv> [options]

Manifest: one item per line, tab-separated; blank lines and # comments ignored
  agent_name <TAB> tab_label <TAB> cwd <TAB> prompt_file

Options
  --dry-run                 validate everything, create nothing
  --workspace <id>          target workspace (default: $HERDR_WORKSPACE_ID)
  --kind <kind>             agent kind (default: claude)
  --permission-mode <mode>  passed to the agent (default: bypassPermissions; "" to omit)
  --focus                   focus each new tab as it is created (default: no-focus)
USAGE
}

[ $# -ge 1 ] || { usage; exit 2; }
manifest=$1; shift
dry=0 kind=claude permmode=bypassPermissions focus=--no-focus workspace=${HERDR_WORKSPACE_ID:-}
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --workspace) workspace=$2; shift ;;
    --kind) kind=$2; shift ;;
    --permission-mode) permmode=$2; shift ;;
    --focus) focus=--focus ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ "${HERDR_ENV:-}" = 1 ] || { echo "not running inside Herdr (HERDR_ENV != 1)" >&2; exit 1; }
[ -n "$workspace" ] || { echo "no workspace: pass --workspace" >&2; exit 1; }
[ -f "$manifest" ] || { echo "no such manifest: $manifest" >&2; exit 1; }

# A cwd with no trusted ancestor makes `claude` block at startup on the folder-trust dialog.
trusted() {
  local d=$1 v
  while :; do
    v=$(jq -r --arg d "$d" '.projects[$d].hasTrustDialogAccepted // empty' "$HOME/.claude.json" 2>/dev/null)
    [ "$v" = "true" ] && return 0
    [ "$d" = "/" ] && return 1
    d=$(dirname "$d")
  done
}

names=() labels=() cwds=() prompts=() errs=0 warns=()
while IFS=$'\t' read -r name label cwd prompt _rest; do
  case ${name:-} in ''|\#*) continue ;; esac
  [ -n "${label:-}" ] && [ -n "${cwd:-}" ] && [ -n "${prompt:-}" ] || { echo "row '$name': needs 4 tab-separated columns" >&2; errs=1; continue; }
  [[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "row '$name': agent name must match [a-z][a-z0-9_-]{0,31}" >&2; errs=1; continue; }
  for seen in ${names[@]+"${names[@]}"}; do [ "$seen" = "$name" ] && { echo "row '$name': duplicate agent name" >&2; errs=1; }; done
  [ -d "$cwd" ] || { echo "row '$name': cwd does not exist: $cwd" >&2; errs=1; }
  [ -s "$prompt" ] || { echo "row '$name': prompt file missing or empty: $prompt" >&2; errs=1; }
  [ -d "$cwd" ] && ! trusted "$cwd" && warns+=("$name: '$cwd' has no Claude-trusted ancestor — the session will stop on the folder-trust dialog. Answer it in the tab, or run claude there once first.")
  names+=("$name"); labels+=("$label"); cwds+=("$cwd"); prompts+=("$prompt")
done < "$manifest"

[ ${#names[@]} -gt 0 ] || { echo "manifest has no rows" >&2; exit 1; }

live=$(herdr agent list 2>/dev/null | jq -r '.result.agents[]?.name // empty')
for name in "${names[@]}"; do
  printf '%s\n' "$live" | grep -qxF "$name" && { echo "row '$name': an agent with that name is already live" >&2; errs=1; }
done
[ $errs -eq 0 ] || { echo "aborting: fix the manifest" >&2; exit 1; }

printf '%-14s %-12s %s\n' AGENT LABEL CWD
for i in "${!names[@]}"; do printf '%-14s %-12s %s\n' "${names[$i]}" "${labels[$i]}" "${cwds[$i]}"; done
for w in ${warns[@]+"${warns[@]}"}; do echo "WARNING: $w"; done
if [ $dry -eq 1 ]; then echo; echo "dry run: ${#names[@]} row(s) valid, nothing created"; exit 0; fi

agent_args=()
[ -n "$permmode" ] && agent_args=(-- --permission-mode "$permmode")

echo
failed=0
for i in "${!names[@]}"; do
  name=${names[$i]}
  tab=$(herdr tab create --workspace "$workspace" --cwd "${cwds[$i]}" --label "${labels[$i]}" $focus 2>&1)
  pane=$(printf '%s' "$tab" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  tabid=$(printf '%s' "$tab" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  [ -n "$pane" ] || { echo "$name: tab create failed: $(printf '%s' "$tab" | head -c 200)"; failed=1; continue; }

  start=$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout 120000 ${agent_args[@]+"${agent_args[@]}"} 2>&1)
  if ! printf '%s' "$start" | jq -e '.result.agent' >/dev/null 2>&1; then
    code=$(printf '%s' "$start" | jq -r '.error.code // "unknown"' 2>/dev/null)
    echo "$name: NOT dispatched ($code) — tab $tabid, pane $pane; prompt held back"
    [ "$code" = "agent_not_ready" ] && herdr agent read "$name" --source visible --lines 30 2>/dev/null | grep -vE '^\s*$' | tail -6 | sed 's/^/    | /'
    failed=1; continue
  fi

  send=$(herdr agent prompt "$name" "$(cat "${prompts[$i]}")" 2>&1)
  printf '%s' "$send" | jq -e '.result.agent' >/dev/null 2>&1 || { echo "$name: started but prompt failed: $(printf '%s' "$send" | head -c 200)"; failed=1; continue; }
  echo "$name: dispatched in pane $pane (tab $tabid)"
done

echo
herdr agent list | jq -r --args '.result.agents[] | select(.name as $n | $ARGS.positional | index($n)) | "\(.name)\t\(.pane_id)\t\(.agent_status)"' "${names[@]}" \
  | while IFS=$'\t' read -r n p s; do printf '%-14s %-8s %s\n' "$n" "$p" "$s"; done

exit $failed
