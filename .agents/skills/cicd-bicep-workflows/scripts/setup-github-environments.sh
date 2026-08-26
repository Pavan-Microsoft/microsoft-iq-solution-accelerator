#!/usr/bin/env bash
# Create (idempotently) GitHub Environments with required reviewers and the Azure OIDC login
# config on each. All configuration is stored as non-sensitive environment VARIABLES (the
# identity IDs are OIDC identifiers, not secrets); gated environments get required reviewers.
# This script never reads, sets, or processes GitHub secrets.
#
# Portable Bash (macOS + Git Bash/WSL). Requires: gh (authenticated), jq.
#
# Usage:
#   setup-github-environments.sh [--org-repo "<org>/<repo>"] \
#     --environments "<preview-env>,<gated-env>,..." \
#     --gated "<gated-env>,..." \
#     [--reviewers "login1,org/team-slug,..."] \
#     [--scope "resourceGroup|subscription"] \
#     [--default-value "update-me"] \
#     [--environment-values "<stage-or-environment>:<client-id>,<tenant-id>,<subscription-id>[,<location>]"] \
#     [--variable "AZURE_TENANT_ID=<tenant-id>"] \
#     [--variable "<stage-or-environment>:AZURE_CLIENT_ID=<client-id>"] \
#     [--variable "<stage-or-environment>:AZURE_SUBSCRIPTION_ID=<subscription-id>"]
#
# Environment model: two GitHub Environments per logical stage — an ungated `<stage>-preview`
# (bound by the what-if `plan` job) and a gated `<stage>` with required reviewers (bound by the
# `apply` job). Each environment carries its OWN Azure OIDC identity Variables (env-scoped, not
# repository-level). The target resource group is NOT a variable here — it comes from each
# `.bicepparam` file's `resourceGroupName` parameter.
#
# Behavior:
#   * Creates each environment if missing (idempotent); adds required reviewers to gated ones.
#     If a gated environment cannot get its protection rules (e.g. reviewer plan/limits), it is
#     still created WITHOUT them and a warning is printed — the environment and its variables
#     are never skipped because reviewers failed.
#   * For each required Actions VARIABLE: if a real value was passed on the CLI it is set on
#     every environment; otherwise a missing variable is scaffolded with the default value
#     'update-me' and an existing one is left untouched. No secrets are ever touched.
#   * Does NOT exit on the first failure — it processes every environment and prints a clear
#     per-environment summary at the end, then exits non-zero only if something actually failed.
#
# Defaults come from your active sessions: org/repo from `gh repo view` (or the git remote).
set -eu

ORG_REPO=""
ENVIRONMENTS=""
GATED=""
REVIEWERS=""
SCOPE="resourceGroup"
DEFAULT_VALUE="update-me"
PROVIDED_VALUES=""

append_provided_value() {
  # append_provided_value <scope|all> <AZURE_* variable> <value>
  [ -n "$3" ] || return 0
  PROVIDED_VALUES="${PROVIDED_VALUES}${1}|${2}|${3}
"
}

trim_spaces() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

store_environment_values_arg() {
  # store_environment_values_arg "<stage-or-environment>:<client-id>,<tenant-id>,<subscription-id>[,<location>]"
  local spec="$1" scope values client tenant subscription location extra

  case "$spec" in
    *:*) scope="${spec%%:*}"; values="${spec#*:}" ;;
    *) echo "invalid --environment-values '$spec' (expected <scope>:<client-id>,<tenant-id>,<subscription-id>[,<location>])" >&2; exit 2 ;;
  esac

  scope="$(trim_spaces "$scope")"
  [ -n "$scope" ] || { echo "invalid --environment-values '$spec' (scope is empty)" >&2; exit 2; }

  IFS=',' read -r client tenant subscription location extra <<EOF
$values
EOF

  client="$(trim_spaces "${client:-}")"
  tenant="$(trim_spaces "${tenant:-}")"
  subscription="$(trim_spaces "${subscription:-}")"
  location="$(trim_spaces "${location:-}")"
  extra="$(trim_spaces "${extra:-}")"

  if [ -z "$client" ] || [ -z "$tenant" ] || [ -z "$subscription" ] || [ -n "$extra" ]; then
    echo "invalid --environment-values '$spec' (expected exactly three comma-delimited values: client-id,tenant-id,subscription-id; add location as a fourth value only for subscription scope)" >&2
    exit 2
  fi

  append_provided_value "$scope" "AZURE_CLIENT_ID" "$client"
  append_provided_value "$scope" "AZURE_TENANT_ID" "$tenant"
  append_provided_value "$scope" "AZURE_SUBSCRIPTION_ID" "$subscription"
  if [ -n "$location" ]; then
    append_provided_value "$scope" "AZURE_LOCATION" "$location"
  fi
}

store_variable_arg() {
  # store_variable_arg "[<stage-or-environment>:]AZURE_<NAME>=<value>"
  local spec="$1" left scope var value

  case "$spec" in
    *=*) ;;
    *) echo "invalid --variable '$spec' (expected [scope:]AZURE_NAME=value)" >&2; exit 2 ;;
  esac
  left="${spec%%=*}"
  value="${spec#*=}"

  case "$left" in
    *:*) scope="${left%%:*}"; var="${left#*:}" ;;
    *) scope="all"; var="$left" ;;
  esac

  case "$var" in
    AZURE_CLIENT_ID|AZURE_TENANT_ID|AZURE_SUBSCRIPTION_ID|AZURE_LOCATION) ;;
    *) echo "unsupported --variable name '$var'" >&2; exit 2 ;;
  esac

  append_provided_value "$scope" "$var" "$value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --org-repo) ORG_REPO="${2:-}"; shift 2 ;;
    --environments) ENVIRONMENTS="${2:-}"; shift 2 ;;
    --gated) GATED="${2:-}"; shift 2 ;;
    --reviewers) REVIEWERS="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --default-value) DEFAULT_VALUE="${2:-}"; shift 2 ;;
    --environment-values) store_environment_values_arg "${2:-}"; shift 2 ;;
    --variable) store_variable_arg "${2:-}"; shift 2 ;;
    -h|--help) sed -n '/^#/ { s/^# \{0,1\}//; /^!\/usr\/bin\/env bash$/d; p; }' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Required Actions variables per environment (scaffolded with $DEFAULT_VALUE when missing).
# The resource group is intentionally NOT here — it is read from each .bicepparam file's
# `resourceGroupName` at deploy time.
REQUIRED_VARS="AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID"
if [ "$SCOPE" = "subscription" ]; then
  REQUIRED_VARS="$REQUIRED_VARS AZURE_LOCATION"
fi

# stage_for_env <ENVIRONMENT> -> logical stage. Preview environments map to their gated stage.
stage_for_env() {
  case "$1" in
    *-preview) printf '%s' "${1%-preview}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# provided_value_for <VAR_NAME> <ENVIRONMENT> -> the real value passed on the CLI, or empty.
provided_value_for() {
  local wanted_var="$1" wanted_env="$2" wanted_stage fallback="" stage_value="" line stage var value
  wanted_stage="$(stage_for_env "$2")"

  while IFS='|' read -r stage var value; do
    [ -n "$stage" ] || continue
    [ "$var" = "$wanted_var" ] || continue
    if [ "$stage" = "$wanted_env" ]; then
      printf '%s' "$value"
      return 0
    fi
    if [ "$stage" = "$wanted_stage" ]; then
      stage_value="$value"
    fi
    if [ "$stage" = "all" ]; then
      fallback="$value"
    fi
  done <<EOF
$PROVIDED_VALUES
EOF

  if [ -n "$stage_value" ]; then
    printf '%s' "$stage_value"
    return 0
  fi
  printf '%s' "$fallback"
}

command -v gh >/dev/null 2>&1 || { echo "gh is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated (run: gh auth login)" >&2; exit 1; }

# Fill from active sessions when not provided.
if [ -z "$ORG_REPO" ]; then
  if gh repo view --json nameWithOwner -q .nameWithOwner >/dev/null 2>&1; then
    ORG_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  else
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    case "$remote_url" in
      *github.com[:/]*) ORG_REPO="$(printf '%s' "$remote_url" | sed -e 's|.*github.com[:/]||' -e 's|\.git$||')" ;;
    esac
  fi
fi
[ -n "$ORG_REPO" ] || { echo "could not detect --org-repo; pass it explicitly" >&2; exit 2; }
echo "==> Repository: $ORG_REPO"

ORG="${ORG_REPO%%/*}"

is_gated() {
  # is_gated <env> -> 0 if env is in the gated list
  case ",$GATED," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# Resolve a reviewer login/team-slug to a JSON reviewer object, or empty on failure.
reviewer_json() {
  local ref="$1"
  case "$ref" in
    */*)
      local slug="${ref#*/}"
      local id
      id="$(gh api "orgs/$ORG/teams/$slug" --jq '.id' 2>/dev/null || true)"
      [ -n "$id" ] && printf '{"type":"Team","id":%s}' "$id"
      ;;
    *)
      local id
      id="$(gh api "users/$ref" --jq '.id' 2>/dev/null || true)"
      [ -n "$id" ] && printf '{"type":"User","id":%s}' "$id"
      ;;
  esac
}

build_reviewers_array() {
  # -> JSON array of reviewer objects from the comma list in $REVIEWERS
  local out="[]" obj OLDIFS="$IFS"
  IFS=','
  for r in $REVIEWERS; do
    r="$(printf '%s' "$r" | tr -d '[:space:]')"
    [ -n "$r" ] || continue
    obj="$(reviewer_json "$r")"
    if [ -n "$obj" ]; then
      out="$(printf '%s' "$out" | jq --argjson o "$obj" '. + [$o]')"
    else
      echo "    warn: could not resolve reviewer '$r'" >&2
    fi
  done
  IFS="$OLDIFS"
  printf '%s' "$out"
}

REVIEWERS_ARRAY="[]"
if [ -n "$REVIEWERS" ]; then
  REVIEWERS_ARRAY="$(build_reviewers_array)"
fi

# Work with a space-separated environment list so the default IFS drives all word-splitting
# (a global IFS="," would break the space-separated $REQUIRED_VARS loops).
[ -n "$ENVIRONMENTS" ] || { echo "--environments is required; pass the environments discovered from the Bicep params folder" >&2; exit 2; }
ENV_LIST="$(printf '%s' "$ENVIRONMENTS" | tr ',' ' ')"

print_manual_requirements() {
  echo
  echo "======================================================================"
  echo "MANUAL SETUP REQUIRED"
  echo "----------------------------------------------------------------------"
  echo "The current gh session could not manage Environments on '$ORG_REPO'"
  echo "(repository admin or org policy). EVERYTHING BELOW MUST BE SET UP"
  echo "MANUALLY — ask an admin to create it, or set it yourself in: Settings >"
  echo "Environments and Settings > Secrets and variables > Actions (Variables tab)."
  echo
  echo "Environments (create each):"
  for e in $ENV_LIST; do
    e="$(printf '%s' "$e" | tr -d '[:space:]')"; [ -n "$e" ] || continue
    if is_gated "$e"; then
      echo "  - $e   (add Required reviewers: ${REVIEWERS:-<reviewers>})"
    else
      echo "  - $e"
    fi
  done
  echo
  echo "Variables on EACH environment (all non-sensitive — set as VARIABLES, not secrets;"
  echo "placeholder value '$DEFAULT_VALUE' until you fill in the real value):"
  for v in $REQUIRED_VARS; do
    echo "  $v = $DEFAULT_VALUE"
  done
  echo
  echo "Also required (outside GitHub): an Azure app registration with federated credentials"
  echo "trusting each GitHub Environment-bound OIDC subject:"
  for e in $ENV_LIST; do
    e="$(printf '%s' "$e" | tr -d '[:space:]')"; [ -n "$e" ] || continue
    echo "  - repo:$ORG_REPO:environment:$e"
  done
  echo "If your org uses a custom OIDC subject template, use the exact subject shown by"
  echo "azure/login instead (for example, repository_owner_id:<id>:repository_id:<id>:environment:<env>)."
  echo "In the Azure portal, click Edit beside Subject identifier and paste that exact value."
  echo "Also create the Azure role assignment."
  echo "======================================================================"
}

# Preflight: environment management normally needs repo admin, but the `.permissions.admin`
# flag can be a false negative (e.g. some org/role setups). So we only WARN here and let the
# real API calls below be the source of truth — never block on this flag alone.
can_admin="$(gh api "repos/$ORG_REPO" --jq '.permissions.admin' 2>/dev/null || echo "unknown")"
if [ "$can_admin" != "true" ]; then
  echo "note: gh does not report you as an admin of '$ORG_REPO'; attempting anyway and will" >&2
  echo "      report exactly what (if anything) fails." >&2
fi

OK_ENVS=""       # created/updated successfully (with reviewers if requested)
PARTIAL_ENVS=""  # created, but required reviewers could not be applied
FAILED_ENVS=""   # could not be created at all

put_env() {
  # put_env <env> <body> -> 0 on success; on failure sets PUT_ERR to the first error line.
  PUT_ERR=""
  if err="$(printf '%s' "$2" | gh api -X PUT "repos/$ORG_REPO/environments/$1" --input - 2>&1 >/dev/null)"; then
    return 0
  fi
  PUT_ERR="$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | head -n 1)"
  return 1
}

for env in $ENV_LIST; do
  env="$(printf '%s' "$env" | tr -d '[:space:]')"
  [ -n "$env" ] || continue

  gated=0; is_gated "$env" && gated=1
  want_reviewers=0
  [ "$gated" -eq 1 ] && [ "$REVIEWERS_ARRAY" != "[]" ] && want_reviewers=1

  created=0
  reviewers_applied=0

  # Try with required reviewers first when requested; fall back to a plain environment so a
  # reviewer/plan limitation never prevents the environment (and its variables) from existing.
  if [ "$want_reviewers" -eq 1 ]; then
    echo "==> Environment '$env' (gated, required reviewers)"
    body="$(jq -n --argjson r "$REVIEWERS_ARRAY" \
      '{wait_timer:0, prevent_self_review:true, reviewers:$r, deployment_branch_policy:null}')"
    if put_env "$env" "$body"; then
      created=1; reviewers_applied=1; echo "    ready (required reviewers set)"
    else
      echo "    warn: could not set required reviewers on '$env': $PUT_ERR" >&2
      echo "          creating it without reviewers — add them manually afterward." >&2
    fi
  fi

  if [ "$created" -eq 0 ]; then
    [ "$want_reviewers" -eq 0 ] && [ "$gated" -eq 1 ] && \
      echo "==> Environment '$env' (gated, no reviewers resolved — add them later)"
    [ "$gated" -eq 0 ] && echo "==> Environment '$env'"
    if put_env "$env" '{"deployment_branch_policy":null}'; then
      created=1
      if [ "$want_reviewers" -eq 1 ]; then
        echo "    ready (WITHOUT required reviewers — add them manually)"
      else
        echo "    ready"
      fi
    else
      echo "    error: could not create environment '$env': $PUT_ERR" >&2
      FAILED_ENVS="$FAILED_ENVS $env"
      continue
    fi
  fi

  # Variables: set provided real values on every environment; otherwise scaffold a missing
  # variable with the placeholder and leave existing ones untouched. No secrets are touched.
  existing_vars="$(gh api "repos/$ORG_REPO/environments/$env/variables" --paginate --jq '[.variables[].name] | join(" ")' 2>/dev/null || echo "")"
  for v in $REQUIRED_VARS; do
    pv="$(provided_value_for "$v" "$env")"
    if [ -n "$pv" ]; then
      if gh variable set "$v" --env "$env" --repo "$ORG_REPO" --body "$pv" >/dev/null 2>&1; then
        echo "    set variable $v (provided value for $(stage_for_env "$env"))"
      else
        echo "    warn: could not set variable $v on '$env' (set it manually)." >&2
      fi
    elif printf ' %s ' "$existing_vars" | grep -q " $v "; then
      echo "    using existing variable $v"
    elif gh variable set "$v" --env "$env" --repo "$ORG_REPO" --body "$DEFAULT_VALUE" >/dev/null 2>&1; then
      echo "    created variable $v = $DEFAULT_VALUE (update it with the real value)"
    else
      echo "    warn: could not create variable $v on '$env' (create it manually)." >&2
    fi
  done

  if [ "$want_reviewers" -eq 1 ] && [ "$reviewers_applied" -eq 0 ]; then
    PARTIAL_ENVS="$PARTIAL_ENVS $env"
  else
    OK_ENVS="$OK_ENVS $env"
  fi
done

echo
echo "Summary"
echo "-------"
[ -n "$OK_ENVS" ]      && echo "  created/updated:$OK_ENVS"
[ -n "$PARTIAL_ENVS" ] && echo "  created WITHOUT required reviewers (add them manually):$PARTIAL_ENVS"
[ -n "$FAILED_ENVS" ]  && echo "  FAILED to create:$FAILED_ENVS"

if [ -n "$FAILED_ENVS" ]; then
  echo
  echo "One or more environments could not be created (permissions or org policy). The items"
  echo "below must be set up MANUALLY."
  print_manual_requirements
  exit 1
fi

echo
echo "Done. Variables without a provided value were created as '$DEFAULT_VALUE' — update each"
echo "with its real value, and ensure the Azure app registration has federated credentials"
echo "for each GitHub Environment-bound subject plus a role assignment. See"
echo "references/naming-conventions.md and references/best-practices.md."
