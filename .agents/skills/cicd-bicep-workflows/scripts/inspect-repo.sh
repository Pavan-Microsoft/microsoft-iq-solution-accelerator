#!/usr/bin/env bash
# Discover the CI/CD-relevant facts of the repository in the current working directory.
# Emits a single JSON document on stdout. Portable Bash (macOS Bash 3.2 + Git Bash/WSL).
#
# Detection only — this script never modifies the repo. Always assumes Bicep.
# Variable VALUES are never read or printed; only their names. Secrets are never touched.
#
# Usage: run from the target repository root (or pass --root <path>):
#   inspect-repo.sh [--root <path>] [--stages "<stage>,..."] [--environments "<env>,..."] [--gated "<env>,..."] [--no-gh]
set -eu

ROOT=""
USE_GH=1
STAGES=""
ENVIRONMENTS=""
GATED=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --stages) STAGES="${2:-}"; shift 2 ;;
    --environments) ENVIRONMENTS="${2:-}"; shift 2 ;;
    --gated) GATED="${2:-}"; shift 2 ;;
    --no-gh) USE_GH=0; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Resolve repo root.
if [ -z "$ROOT" ]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
    ROOT="$(git rev-parse --show-toplevel)"
  else
    ROOT="$(pwd)"
  fi
fi
cd "$ROOT"

have() { command -v "$1" >/dev/null 2>&1; }

# lines_to_json_array: read stdin (one item per line) -> JSON array of unique, sorted, non-empty strings.
lines_to_json_array() {
  grep -v '^[[:space:]]*$' | LC_ALL=C sort -u | jq -R . | jq -s .
}

csv_to_json_array() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^[[:space:]]*$' | jq -R . | jq -s .
}

derive_environments_from_stages() {
  _out=""
  _oldifs="$IFS"
  IFS=','
  for _stage in $STAGES; do
    _stage="$(printf '%s' "$_stage" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$_stage" ] || continue
    if [ -z "$_out" ]; then
      _out="$_stage-preview,$_stage"
    else
      _out="$_out,$_stage-preview,$_stage"
    fi
  done
  IFS="$_oldifs"
  printf '%s' "$_out"
}

# find_files <pattern> ... : print matching files (relative), skipping heavy dirs.
find_files() {
  # shellcheck disable=SC2016
  find . \
    \( -name .git -o -name .github -o -name .devcontainer -o -name .agents -o -name node_modules -o -name .terraform -o -name .venv -o -name dist -o -name build \) -prune \
    -o -type f "$@" -print 2>/dev/null | sed 's|^\./||'
}

# ---- default branch ---------------------------------------------------------
default_branch=""
if have git; then
  default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  if [ -z "$default_branch" ]; then
    default_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
fi
[ -n "$default_branch" ] || default_branch="main"

# ---- org/repo slug ----------------------------------------------------------
org_repo=""
if have git; then
  remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  case "$remote_url" in
    *github.com[:/]*)
      org_repo="$(printf '%s' "$remote_url" | sed -e 's|.*github.com[:/]||' -e 's|\.git$||')"
      ;;
  esac
fi

# ---- Bicep discovery (this skill always assumes Bicep) ----------------------
bicep_files="$(find_files -name '*.bicep')"

# Resolve the Bicep entrypoint (prefer infra/main.bicep, then any main.bicep, then first).
bicep_entrypoint=""
if [ -n "$bicep_files" ]; then
  bicep_entrypoint="$(printf '%s\n' "$bicep_files" | grep -E '(^|/)infra/main\.bicep$' | head -n 1 || true)"
  [ -n "$bicep_entrypoint" ] || bicep_entrypoint="$(printf '%s\n' "$bicep_files" | grep -E '(^|/)main\.bicep$' | head -n 1 || true)"
  [ -n "$bicep_entrypoint" ] || bicep_entrypoint="$(printf '%s\n' "$bicep_files" | head -n 1)"
fi
# Bicep parameters file next to the entrypoint, if any.
bicep_params=""
if [ -n "$bicep_entrypoint" ]; then
  dir="$(dirname "$bicep_entrypoint")"
  for cand in "$dir/main.parameters.json" "$dir/main.bicepparam"; do
    if [ -f "$cand" ]; then bicep_params="$cand"; break; fi
  done
fi

# Bicep deployment scope (resource group vs subscription).
bicep_scope="resourceGroup"
if [ -n "$bicep_entrypoint" ] && grep -qiE "targetScope[[:space:]]*=[[:space:]]*'subscription'" "$bicep_entrypoint" 2>/dev/null; then
  bicep_scope="subscription"
fi

# ---- multi-environment readiness --------------------------------------------
# A repo supports multi-env deploys when it has a per-environment parameters file for each
# stage. Preferred convention: <infra_dir>/params/<env>.bicepparam. Also accept common
# alternatives so we don't nag repos that already do this a different way.
infra_dir="infra"
[ -n "$bicep_entrypoint" ] && infra_dir="$(dirname "$bicep_entrypoint")"

discover_param_stages() {
  _params_dir="$infra_dir/params"
  [ -d "$_params_dir" ] || return 0

  {
    for _cand in "$_params_dir"/*.bicepparam "$_params_dir"/*.parameters.json; do
      [ -f "$_cand" ] || continue
      _base="$(basename "$_cand")"
      case "$_base" in
        *.parameters.json) printf '%s\n' "${_base%.parameters.json}" ;;
        *.bicepparam) printf '%s\n' "${_base%.bicepparam}" ;;
      esac
    done
  } | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u
}

join_lines_csv() {
  _out=""
  while IFS= read -r _item; do
    [ -n "$_item" ] || continue
    if [ -z "$_out" ]; then _out="$_item"; else _out="$_out,$_item"; fi
  done
  printf '%s' "$_out"
}

if [ -z "$STAGES" ]; then
  discovered_stages="$(discover_param_stages)"
  if [ -n "$discovered_stages" ]; then
    STAGES="$(printf '%s\n' "$discovered_stages" | join_lines_csv)"
  fi
fi
[ -n "$GATED" ] || GATED="$STAGES"
[ -n "$ENVIRONMENTS" ] || ENVIRONMENTS="$(derive_environments_from_stages)"

find_env_param() {
  _env="$1"
  for cand in \
    "$infra_dir/params/$_env.bicepparam" \
    "$infra_dir/params/$_env.parameters.json" \
    "$infra_dir/main.$_env.bicepparam" \
    "$infra_dir/main.parameters.$_env.json"; do
    if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  printf ''
}
params_json="{}"
multi_env_ready="true"
if [ -z "$STAGES" ]; then
  multi_env_ready="false"
fi
_oldifs="$IFS"
IFS=','
for _stage in $STAGES; do
  _stage="$(printf '%s' "$_stage" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$_stage" ] || continue
  _param="$(find_env_param "$_stage")"
  if [ -n "$_param" ]; then
    params_json="$(printf '%s' "$params_json" | jq --arg k "$_stage" --arg v "$_param" '. + {($k): $v}')"
  else
    multi_env_ready="false"
    params_json="$(printf '%s' "$params_json" | jq --arg k "$_stage" '. + {($k): null}')"
  fi
done
IFS="$_oldifs"

# ---- existing workflows -----------------------------------------------------
workflows=""
if [ -d ".github/workflows" ]; then
  workflows="$(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sed 's|^\./||' | sort)"
fi

# ---- GitHub Environments / variables (names only; secrets are never touched) ----
gh_available="false"
gh_authenticated="false"
environments_readable="false"
environments_admin="false"
environments_json="[]"
repo_variable_names_json="[]"
environment_state_json="{}"
if [ "$USE_GH" -eq 1 ] && have gh; then
  gh_available="true"
  if gh auth status >/dev/null 2>&1 && [ -n "$org_repo" ]; then
    gh_authenticated="true"
    # Repository admin is required to create/manage Environments and variables.
    admin_flag="$(gh api "repos/$org_repo" --jq '.permissions.admin' 2>/dev/null || echo "false")"
    [ "$admin_flag" = "true" ] && environments_admin="true"
    # Environments require admin/write; a read failure means the user lacks permission.
    if environments_json="$(gh api "repos/$org_repo/environments" --jq '[.environments[].name]' 2>/dev/null)"; then
      environments_readable="true"
    else
      environments_json="[]"
    fi
    repo_variable_names_json="$(gh api "repos/$org_repo/actions/variables" --paginate --jq '[.variables[].name]' 2>/dev/null || echo '[]')"

    # Per-environment state (variable names only; secrets are never read or processed) for the
    # preview and gated environments. This lets the agent tell which required variables already
    # exist and can be reused as-is.
    echo "$environments_json" | jq -e . >/dev/null 2>&1 || environments_json="[]"
    for _env in $(printf '%s' "$ENVIRONMENTS" | tr ',' ' '); do
      _exists="false"
      if printf '%s' "$environments_json" | jq -e --arg e "$_env" 'index($e) != null' >/dev/null 2>&1; then
        _exists="true"
      fi
      _vars_json="[]"
      if [ "$_exists" = "true" ]; then
        _vars_json="$(gh api "repos/$org_repo/environments/$_env/variables" --paginate --jq '[.variables[].name]' 2>/dev/null || echo '[]')"
        echo "$_vars_json" | jq -e . >/dev/null 2>&1 || _vars_json="[]"
      fi
      environment_state_json="$(printf '%s' "$environment_state_json" | jq \
        --arg e "$_env" \
        --argjson exists "$( [ "$_exists" = "true" ] && echo true || echo false )" \
        --argjson vars "$_vars_json" \
        '. + {($e): {exists: $exists, variables: $vars}}')"
    done
  fi
fi
# Guard against empty/invalid JSON from gh.
echo "$environments_json" | jq -e . >/dev/null 2>&1 || environments_json="[]"
echo "$repo_variable_names_json" | jq -e . >/dev/null 2>&1 || repo_variable_names_json="[]"
echo "$environment_state_json" | jq -e . >/dev/null 2>&1 || environment_state_json="{}"

# ---- assemble JSON ----------------------------------------------------------
jq -n \
  --arg root "$ROOT" \
  --arg org_repo "$org_repo" \
  --arg default_branch "$default_branch" \
  --arg bicep_entrypoint "$bicep_entrypoint" \
  --arg bicep_params "$bicep_params" \
  --arg bicep_scope "$bicep_scope" \
  --arg infra_dir "$infra_dir" \
  --arg multi_env_ready "$multi_env_ready" \
  --arg gh_available "$gh_available" \
  --arg gh_authenticated "$gh_authenticated" \
  --arg environments_readable "$environments_readable" \
  --arg environments_admin "$environments_admin" \
  --argjson workflows "$(printf '%s' "$workflows" | lines_to_json_array)" \
  --argjson stages "$(csv_to_json_array "$STAGES")" \
  --argjson configured_environments "$(csv_to_json_array "$ENVIRONMENTS")" \
  --argjson gated_environments "$(csv_to_json_array "$GATED")" \
  --argjson params "$params_json" \
  --argjson environments "$environments_json" \
  --argjson environment_state "$environment_state_json" \
  --argjson repo_variable_names "$repo_variable_names_json" \
  '{
    repo_root: $root,
    org_repo: (if $org_repo == "" then null else $org_repo end),
    default_branch: $default_branch,
    infra: {
      bicep_entrypoint: (if $bicep_entrypoint == "" then null else $bicep_entrypoint end),
      bicep_parameters: (if $bicep_params == "" then null else $bicep_params end),
      bicep_scope: $bicep_scope,
      infra_dir: $infra_dir,
      multi_env: {
        ready: ($multi_env_ready == "true"),
        convention: ($infra_dir + "/params/<env>.bicepparam"),
        parameters: $params,
        missing: ($params | to_entries | map(select(.value == null) | .key))
      }
    },
    github: {
      cli_available: ($gh_available == "true"),
      authenticated: ($gh_authenticated == "true"),
      environments_readable: ($environments_readable == "true"),
      environments_admin: ($environments_admin == "true"),
      existing_workflows: $workflows,
      environments: $environments,
      environment_state: $environment_state,
      repo_variable_names: $repo_variable_names
    },
    recommended: {
      auth: "oidc",
      stages: $stages,
      promotion_order: $stages
    },
    required_setup: {
      can_create: ($environments_admin == "true"),
      manual_setup_required: ($environments_admin != "true"),
      default_variable_value: "update-me",
      environments: $configured_environments,
      gated_environments: $gated_environments,
      variables_per_environment: (if $bicep_scope == "subscription"
        then ["AZURE_CLIENT_ID","AZURE_TENANT_ID","AZURE_SUBSCRIPTION_ID","AZURE_LOCATION"]
        else ["AZURE_CLIENT_ID","AZURE_TENANT_ID","AZURE_SUBSCRIPTION_ID"] end),
      resource_group_from_params: true,
      azure: {
        app_registrations_per_stage: $stages,
        federated_credentials_per_app_registration: 2,
        oidc_subjects: (if $org_repo == "" then [] else ($configured_environments | map("repo:" + $org_repo + ":environment:" + .)) end)
      }
    }
  }'
