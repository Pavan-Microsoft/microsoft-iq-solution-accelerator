---
description: "Analyze a repository's Bicep infrastructure and generate best-practice GitHub Actions CI/CD workflows for the environments discovered from the Bicep params folder. Ships a Bicep CI workflow (lint, build, format, per-environment what-if validation) and a deploy workflow that promotes through the user-approved discovered stages. Use when users ask to create, add, set up, or scaffold CI/CD, GitHub Actions, deployment pipelines, linting/validation, or release workflows for infrastructure; to build multi-environment infra pipelines; or to add gated infrastructure deployments with a reviewable Bicep what-if plan. Generates the workflows that run existing infrastructure; it does not author Bicep or deploy application code. Always assumes Bicep. Always asks before changing anything in GitHub."
name: "cicd-bicep-workflows"
---

# CI/CD Workflow Generator (Bicep infrastructure)

Generates the GitHub Actions workflows that run **existing** Bicep infrastructure. It does not
author Bicep files and does not deploy application code.

## Use when
The user wants to create, scaffold, or set up CI/CD, GitHub Actions, or deployment pipelines for
infrastructure — especially multi-environment infra pipelines driven by the repo's Bicep params
folder, or gated deployments that show a reviewable `what-if` plan before applying.

## What this skill ships
- **`templates/`** — ready-to-fill workflows: `bicep-ci.yml` (lint/build/format + per-env
  what-if), `bicep-deploy.yml` (promotes through the discovered stages), and the reusable
  `_infra.yml`.
- **`references/`** — `best-practices.md`, `environments-setup.md`, `naming-conventions.md`.
- **`scripts/`** — `check-prereqs.sh`, `inspect-repo.sh`, `setup-github-environments.sh`,
  `validate-workflows.sh`.

## Hard constraints
- **Ask before any mutation.** Confirm with the user (via an interactive input tool when
  available) before writing repo files, changing GitHub environments/variables/branches/PRs, or
  creating Azure resources. Read-only discovery needs no approval.
- **Always Bicep.** Only generate Bicep pipelines (`az deployment`); locate the entrypoint from
  discovery, never hardcode repo/resource/path names.
- **Use the bundled scripts.** Run `scripts/*.sh` in place by absolute path; never copy them into
  the target repo or replace them with inline Python/`node -e`/ad-hoc one-offs. They are portable
  Bash (macOS Bash 3.2 + Windows Git Bash/WSL). Extend a script if a capability is missing.
- **Rely on active sessions.** Use the user's existing `az login` / `gh` sessions; never ask for
  credentials.
- **Temp files under `.agent/tmp/`, always cleaned up.** Write all scratch/intermediate files
  (e.g. `repo-facts.json`) only under `.agent/tmp/` — never in the repo root, `.github/`,
  `infra/`, or the skill folder — and remove them before finishing, even on failure.
- **Variables only, never secrets.** OIDC identity IDs (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`) are non-sensitive **GitHub Environment Variables** read as `vars.*`.
  Never read/set GitHub secrets, and never print variable *values* (names only). Keep
  environment-specific config in `vars.*`, not inlined in YAML.
- **Don't overwrite existing workflows** without confirming when `github.existing_workflows` is
  non-empty.
- **Best practices** (`references/best-practices.md`): pin actions to a full commit SHA (with a
  `# vX.Y.Z` comment); prefer first-party `actions/*` and official `azure/login`; least-privilege
  `permissions`; `concurrency` guards; OIDC via `azure/login` (`id-token: write`, no client
  secret); reusable workflows.

## Process
1. **Validate tools.** Run `scripts/check-prereqs.sh` (`jq` required; `gh`/`az` from active
   sessions).
2. **Inspect the repo.** Run `scripts/inspect-repo.sh > .agent/tmp/repo-facts.json`. It reports
   the Bicep entrypoint/parameters/scope, params-folder stages, multi-env readiness, existing
   workflows, and (when readable) GitHub Environments and their variable names.
3. **Check multi-env readiness.** Read `infra.multi_env`. A repo is ready when it has a
   per-environment parameters file for every discovered stage (`<infra_dir>/params/<stage>.bicepparam`,
   each with `using '../main.bicep'`). If `ready` is `false`, recommend the missing files from
   `multi_env.missing`/`multi_env.convention` and offer to add one small `.bicepparam` per
   environment. **Confirm before creating any file.**
4. **Ask for deployment order.** Ask the user to order the discovered stages for promotion (offer
   the discovered order as default; require explicit confirmation; each stage exactly once, no
   unknowns). Save as `ordered_stages`. Derive `ordered_environments` from
   `required_setup.environments` (preserving preview/apply pairing) and `ordered_gated_environments`
   by filtering `required_setup.gated_environments` through it.
5. **Set up GitHub Environments by access level.** Read `github.environments_admin`,
   `github.environment_state`, and `required_setup`, then follow one branch:
   - **No admin access** — blocking. Do not proceed. Tell the user everything must be set up
     manually and list, for every `ordered_environments` entry, the exact variable names (all
     Variables, not secrets) from `required_setup.variables_per_environment`: `AZURE_CLIENT_ID`,
     `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (+ `AZURE_LOCATION` for subscription scope), plus
     reviewers on `ordered_gated_environments` and the Azure app registration. The resource group
     is not a variable — it comes from each `params/<env>.bicepparam`'s `resourceGroupName`.
     By default the pipeline **creates** that resource group (idempotent `az group create`), so it
     never needs to pre-exist; this requires a `location` (in the `.bicepparam` or the
     `AZURE_LOCATION` Variable) and the identity to have **subscription-scoped** Contributor (see
     `references/naming-conventions.md`). For repos where the resource group already exists and the
     identity is only resource-group scoped, the user sets `CREATE_RESOURCE_GROUP=false` to skip
     creation.
   - **Admin access, missing envs/variables** — run `scripts/setup-github-environments.sh` (never
     hand-write `gh` commands). First, via an interactive tool: (a) ask the required-reviewers
     value and verify the exact GitHub login (e.g. `gh api users/<login>`); (b) ask whether to
     supply real values now — if yes, collect one comma-delimited string per stage in order
     `AZURE_CLIENT_ID,AZURE_TENANT_ID,AZURE_SUBSCRIPTION_ID` (+ `AZURE_LOCATION` for subscription
     scope) and pass via repeatable `--environment-values "<stage>:..."`; if no, the script
     scaffolds `update-me` placeholders. Run with `--environments` (ordered), `--gated` (ordered),
     `--reviewers`. **Confirm before running.**
   - **Admin access, envs/variables present** — tell the user the workflows reuse the existing
     values; nothing is created or overwritten.
6. **Confirm the plan** — infra directory, `ordered_stages`, `ordered_environments`, reviewers,
   per-env parameters files (each with `resourceGroupName`), and any workflow conflicts. **Get
   explicit approval before writing files.**
7. **Render templates** into `.github/workflows/`:
   - `_infra.yml` — copy verbatim. Pass `template_file` if the entrypoint differs from
     `infra/main.bicep`; pass `parameters_file` if the per-env files don't follow the
     `params/<env>.bicepparam` convention. For subscription scope, switch its `az deployment group`
     to `az deployment sub` + `AZURE_LOCATION`. It also has an "Ensure resource group
     exists" step (idempotent `az group create`) gated by the `CREATE_RESOURCE_GROUP` Variable;
     **on by default** so the resource group is created and never needs to pre-exist (the identity
     needs subscription-scoped Contributor). Set `CREATE_RESOURCE_GROUP=false` to skip creation when
     the resource group already exists.
   - `bicep-ci.yml` / `bicep-deploy.yml` — replace `__DEFAULT_BRANCH__`, `__INFRA_DIR__`,
     `__ENVIRONMENTS_INLINE__`, `__DEPLOY_JOBS__`. `bicep-deploy.yml` holds one reusable
     `plan-<env>`/`apply-<env>` pair; repeat it once per `ordered_stages` entry, substituting
     `<env>` and chaining so each stage's `plan-<env>` has `needs: apply-<previous_env>` (first has
     no `needs`). Keep pairs identical and add no per-job `permissions` — the workflow-level and
     `_infra.yml` permissions define OIDC access.
8. **Guide GitHub/Azure setup** (ask before mutating): run
   `scripts/setup-github-environments.sh` as in step 5 (add `--scope subscription` when needed);
   report its per-environment summary faithfully. The Azure deployment identity + federated OIDC
   credential + role assignment are a manual prerequisite — give the commands from
   `references/best-practices.md` and point to `references/naming-conventions.md`.
9. **Validate.** Run `scripts/validate-workflows.sh` on the rendered workflows; report its result.
10. **Clean up** all files created under `.agent/tmp/` (remove the directory if empty), even if an
    earlier step failed.

## Output
Report, in order:
1. **Detected stack** — entrypoint/scope, default branch, multi-env readiness, stage names,
   approved order, existing workflows/environments.
2. **Multi-env changes** — parameters files added or recommended.
3. **Generated files** — the workflows written and their purpose.
4. **Setup required** — Azure sign-in, GitHub Environments + reviewers, and the exact per-env
   variables. If you lack GitHub permission, say so plainly and list every environment and
   variable name (all Variables, not secrets) the user must create.
5. **Validation** — `scripts/validate-workflows.sh` result.
6. **Cleanup** — confirm `.agent/tmp/` files were removed.
