#!/usr/bin/env bash
# Discover the Terraform CI/CD-relevant facts of the repository in the current working directory.
# Emits a single JSON document on stdout. Portable Bash (macOS Bash 3.2 + Git Bash/WSL).
#
# Detection only — this script never modifies the repo. Assumes Terraform (azurerm backend).
# Variable VALUES are never read or printed; only their names. Secrets are never touched.
#
# Usage: run from the target repository root (or pass --root <path>):
#   inspect-repo-tf.sh [--root <path>] [--stages "<stage>,..."] [--environments "<env>,..."] [--gated "<env>,..."] [--no-gh]
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

if [ -z "$ROOT" ]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
    ROOT="$(git rev-parse --show-toplevel)"
  else
    ROOT="$(pwd)"
  fi
fi
cd "$ROOT"

have() { command -v "$1" >/dev/null 2>&1; }

lines_to_json_array() {
  grep -v '^[[:space:]]*$' | LC_ALL=C sort -u | jq -R . | jq -s .
}
csv_to_json_array() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^[[:space:]]*$' | jq -R . | jq -s .
}
join_lines_csv() {
  _out=""
  while IFS= read -r _item; do
    [ -n "$_item" ] || continue
    if [ -z "$_out" ]; then _out="$_item"; else _out="$_out,$_item"; fi
  done
  printf '%s' "$_out"
}
derive_environments_from_stages() {
  _out=""
  _oldifs="$IFS"; IFS=','
  for _stage in $STAGES; do
    _stage="$(printf '%s' "$_stage" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$_stage" ] || continue
    if [ -z "$_out" ]; then _out="$_stage-preview,$_stage"; else _out="$_out,$_stage-preview,$_stage"; fi
  done
  IFS="$_oldifs"; printf '%s' "$_out"
}

find_files() {
  find . \
    \( -name .git -o -name .github -o -name .devcontainer -o -name .agents -o -name node_modules -o -name .terraform -o -name .venv -o -name dist -o -name build \) -prune \
    -o -type f "$@" -print 2>/dev/null | sed 's|^\./||'
}

# ---- default branch ---------------------------------------------------------
default_branch=""
if have git; then
  default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  [ -n "$default_branch" ] || default_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi
[ -n "$default_branch" ] || default_branch="main"

# ---- org/repo slug ----------------------------------------------------------
org_repo=""
if have git; then
  remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  case "$remote_url" in
    *github.com[:/]*) org_repo="$(printf '%s' "$remote_url" | sed -e 's|.*github.com[:/]||' -e 's|\.git$||')" ;;
  esac
fi

# ---- Terraform discovery ----------------------------------------------------
# Locate the Terraform root: prefer a dir named infra_tf, else the dir containing a root main.tf
# that declares provider/terraform blocks (not a module under modules/).
tf_files="$(find_files -name '*.tf')"
tf_root_dir=""
if [ -n "$tf_files" ]; then
  if printf '%s\n' "$tf_files" | grep -qE '^infra_tf/'; then
    tf_root_dir="infra_tf"
  else
    # first main.tf that is not inside a modules/ subtree
    _mt="$(printf '%s\n' "$tf_files" | grep -E '(^|/)main\.tf$' | grep -vE '(^|/)modules/' | head -n 1 || true)"
    [ -n "$_mt" ] || _mt="$(printf '%s\n' "$tf_files" | grep -E '(^|/)main\.tf$' | head -n 1 || true)"
    [ -n "$_mt" ] && tf_root_dir="$(dirname "$_mt")"
  fi
fi
[ -n "$tf_root_dir" ] || tf_root_dir="infra_tf"

tf_entrypoint=""
[ -f "$tf_root_dir/main.tf" ] && tf_entrypoint="$tf_root_dir/main.tf"

# Backend type declared in the root (azurerm expected). Only consider files CI actually checks
# out: skip Terraform override files (*_override.tf / override.tf — a local-dev convention) and any
# untracked/gitignored .tf files. This avoids a false "local backend" detection from an azd-style
# gitignored backend_override.tf, which never reaches CI.
tf_backend="none"
backend_override_ignored=0
if [ -n "$tf_root_dir" ]; then
  _in_git=0
  if have git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then _in_git=1; fi
  for _tf in "$tf_root_dir"/*.tf; do
    [ -e "$_tf" ] || continue
    _base="$(basename "$_tf")"
    _ci_file=1
    case "$_base" in
      *_override.tf|override.tf) _ci_file=0 ;;
    esac
    if [ "$_ci_file" -eq 1 ] && [ "$_in_git" -eq 1 ]; then
      git ls-files --error-unmatch "$_tf" >/dev/null 2>&1 || _ci_file=0
    fi
    if [ "$_ci_file" -eq 0 ]; then
      grep -qsE 'backend[[:space:]]+"[a-z]+"' "$_tf" && backend_override_ignored=1
      continue
    fi
    if grep -qsE 'backend[[:space:]]+"azurerm"' "$_tf"; then
      tf_backend="azurerm"
    elif [ "$tf_backend" = "none" ] && grep -qsE 'backend[[:space:]]+"[a-z]+"' "$_tf"; then
      tf_backend="other"
    fi
  done
fi

# ---- stage discovery from <env>.tfvars --------------------------------------
discover_tfvars_stages() {
  [ -d "$tf_root_dir" ] || return 0
  {
    for _cand in "$tf_root_dir"/*.tfvars; do
      [ -f "$_cand" ] || continue
      _base="$(basename "$_cand")"
      case "$_base" in
        *.auto.tfvars) : ;;  # auto-loaded, not an environment selector
        *.tfvars) printf '%s\n' "${_base%.tfvars}" ;;
      esac
    done
  } | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u
}

if [ -z "$STAGES" ]; then
  discovered_stages="$(discover_tfvars_stages)"
  [ -n "$discovered_stages" ] && STAGES="$(printf '%s\n' "$discovered_stages" | join_lines_csv)"
fi
[ -n "$GATED" ] || GATED="$STAGES"
[ -n "$ENVIRONMENTS" ] || ENVIRONMENTS="$(derive_environments_from_stages)"

find_env_tfvars() {
  _env="$1"
  for cand in "$tf_root_dir/$_env.tfvars" "$tf_root_dir/environments/$_env.tfvars"; do
    if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  printf ''
}
tfvars_json="{}"
multi_env_ready="true"
[ -n "$STAGES" ] || multi_env_ready="false"
_oldifs="$IFS"; IFS=','
for _stage in $STAGES; do
  _stage="$(printf '%s' "$_stage" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$_stage" ] || continue
  _tfv="$(find_env_tfvars "$_stage")"
  if [ -n "$_tfv" ]; then
    tfvars_json="$(printf '%s' "$tfvars_json" | jq --arg k "$_stage" --arg v "$_tfv" '. + {($k): $v}')"
  else
    multi_env_ready="false"
    tfvars_json="$(printf '%s' "$tfvars_json" | jq --arg k "$_stage" '. + {($k): null}')"
  fi
done
IFS="$_oldifs"

# ---- existing workflows -----------------------------------------------------
workflows=""
if [ -d ".github/workflows" ]; then
  workflows="$(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sed 's|^\./||' | sort)"
fi

# ---- coexisting Bicep? ------------------------------------------------------
bicep_present="false"
if find_files -name '*.bicep' | grep -q .; then bicep_present="true"; fi

# ---- GitHub Environments / variables (names only) ---------------------------
gh_available="false"; gh_authenticated="false"; environments_readable="false"; environments_admin="false"
environments_json="[]"; repo_variable_names_json="[]"; environment_state_json="{}"
if [ "$USE_GH" -eq 1 ] && have gh; then
  gh_available="true"
  if gh auth status >/dev/null 2>&1 && [ -n "$org_repo" ]; then
    gh_authenticated="true"
    admin_flag="$(gh api "repos/$org_repo" --jq '.permissions.admin' 2>/dev/null || echo "false")"
    [ "$admin_flag" = "true" ] && environments_admin="true"
    if environments_json="$(gh api "repos/$org_repo/environments" --jq '[.environments[].name]' 2>/dev/null)"; then
      environments_readable="true"
    else
      environments_json="[]"
    fi
    repo_variable_names_json="$(gh api "repos/$org_repo/actions/variables" --paginate --jq '[.variables[].name]' 2>/dev/null || echo '[]')"
    echo "$environments_json" | jq -e . >/dev/null 2>&1 || environments_json="[]"
    for _env in $(printf '%s' "$ENVIRONMENTS" | tr ',' ' '); do
      _exists="false"
      if printf '%s' "$environments_json" | jq -e --arg e "$_env" 'index($e) != null' >/dev/null 2>&1; then _exists="true"; fi
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
echo "$environments_json" | jq -e . >/dev/null 2>&1 || environments_json="[]"
echo "$repo_variable_names_json" | jq -e . >/dev/null 2>&1 || repo_variable_names_json="[]"
echo "$environment_state_json" | jq -e . >/dev/null 2>&1 || environment_state_json="{}"

# ---- assemble JSON ----------------------------------------------------------
jq -n \
  --arg root "$ROOT" \
  --arg org_repo "$org_repo" \
  --arg default_branch "$default_branch" \
  --arg tf_entrypoint "$tf_entrypoint" \
  --arg tf_root_dir "$tf_root_dir" \
  --arg tf_backend "$tf_backend" \
  --arg backend_override_ignored "$backend_override_ignored" \
  --arg bicep_present "$bicep_present" \
  --arg multi_env_ready "$multi_env_ready" \
  --arg gh_available "$gh_available" \
  --arg gh_authenticated "$gh_authenticated" \
  --arg environments_readable "$environments_readable" \
  --arg environments_admin "$environments_admin" \
  --argjson workflows "$(printf '%s' "$workflows" | lines_to_json_array)" \
  --argjson stages "$(csv_to_json_array "$STAGES")" \
  --argjson configured_environments "$(csv_to_json_array "$ENVIRONMENTS")" \
  --argjson gated_environments "$(csv_to_json_array "$GATED")" \
  --argjson tfvars "$tfvars_json" \
  --argjson environments "$environments_json" \
  --argjson environment_state "$environment_state_json" \
  --argjson repo_variable_names "$repo_variable_names_json" \
  '{
    repo_root: $root,
    org_repo: (if $org_repo == "" then null else $org_repo end),
    default_branch: $default_branch,
    infra: {
      flavor: "terraform",
      tf_entrypoint: (if $tf_entrypoint == "" then null else $tf_entrypoint end),
      tf_root_dir: $tf_root_dir,
      backend: $tf_backend,
      backend_local_override_ignored: ($backend_override_ignored == "1"),
      bicep_present: ($bicep_present == "true"),
      multi_env: {
        ready: ($multi_env_ready == "true"),
        convention: ($tf_root_dir + "/<env>.tfvars"),
        tfvars: $tfvars,
        missing: ($tfvars | to_entries | map(select(.value == null) | .key))
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
      variables_per_environment: ["AZURE_CLIENT_ID","AZURE_TENANT_ID","AZURE_SUBSCRIPTION_ID","TF_BACKEND_RESOURCE_GROUP","TF_BACKEND_STORAGE_ACCOUNT","TF_BACKEND_CONTAINER"],
      state_backend_is_prerequisite: true,
      azure: {
        app_registrations_per_stage: $stages,
        federated_credentials_per_app_registration: 2,
        oidc_subjects: (if $org_repo == "" then [] else ($configured_environments | map("repo:" + $org_repo + ":environment:" + .)) end)
      }
    }
  }'
