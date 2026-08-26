#!/usr/bin/env bash
# Validate the rendered GitHub Actions workflow files for this skill.
#
# The agent must NOT hand-write inline Python/one-off scripts to check the YAML — always run
# this script. It prefers `actionlint` (full Actions linting) and otherwise falls back to a
# portable, dependency-free Bash structural check. Never uses Python.
#
# Portable Bash (macOS Bash 3.2 + Windows Git Bash/WSL). Standard tooling only.
#
# Usage:
#   validate-workflows.sh [file ...]
# With no arguments it validates the workflows this skill renders, when present:
#   .github/workflows/{_infra,bicep-ci,bicep-deploy}.yml
set -eu

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve default targets relative to the repo root when no files are passed.
FILES=""
if [ "$#" -gt 0 ]; then
  FILES="$*"
else
  root="."
  if have git && git rev-parse --show-toplevel >/dev/null 2>&1; then
    root="$(git rev-parse --show-toplevel)"
  fi
  for f in _infra bicep-ci bicep-deploy; do
    cand="$root/.github/workflows/$f.yml"
    [ -f "$cand" ] && FILES="$FILES $cand"
  done
  FILES="$(printf '%s' "$FILES" | sed 's/^ *//')"
fi

if [ -z "$FILES" ]; then
  echo "no workflow files to validate (expected .github/workflows/{_infra,bicep-ci,bicep-deploy}.yml)" >&2
  exit 1
fi

# ---- structural sanity check (no external deps, no Python) -------------------
# Catches the most common breakage: tabs used for indentation and unmatched/blatantly wrong
# top-level keys. Not a full YAML parser — actionlint below is authoritative when present.
structural_check() {
  file="$1"
  [ -f "$file" ] || { echo "  MISS  $file (not found)"; return 1; }
  rc=0
  if grep -n "$(printf '^\t')" "$file" >/dev/null 2>&1; then
    echo "  FAIL  $file: tab indentation found (YAML requires spaces)"; rc=1
  fi
  # Every workflow needs a top-level `on:` (or `on ` mapping) and `jobs:`.
  grep -Eq '^on:' "$file" || grep -Eq '^on[[:space:]]' "$file" || {
    echo "  FAIL  $file: missing top-level 'on:' trigger"; rc=1; }
  grep -Eq '^jobs:' "$file" || {
    echo "  FAIL  $file: missing top-level 'jobs:'"; rc=1; }
  [ "$rc" -eq 0 ] && echo "  ok    $file (structural check passed)"
  return "$rc"
}

fail=0

if have actionlint; then
  echo "== actionlint =="
  # shellcheck disable=SC2086
  if actionlint $FILES; then
    echo "  ok    actionlint passed"
  else
    fail=1
  fi
else
  echo "== structural check (actionlint not installed) =="
  echo "note: install actionlint for full GitHub Actions validation."
  for f in $FILES; do
    structural_check "$f" || fail=1
  done
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL: workflow validation reported problems."
  exit 1
fi
echo "OK: workflow validation passed."
