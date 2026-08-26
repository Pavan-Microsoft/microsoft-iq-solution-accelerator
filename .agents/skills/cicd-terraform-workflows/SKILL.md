# CI/CD Workflow Generator (Terraform infrastructure)

Generates the GitHub Actions workflows that run **existing** Terraform infrastructure (azurerm
provider + azurerm remote state). It does not author `.tf` files and does not deploy application
code. It is the Terraform sibling of `cicd-bicep-workflows` and **coexists** with it — it never
replaces a Bicep pipeline.

## Use when
The user wants to create, scaffold, or set up CI/CD, GitHub Actions, or deployment pipelines for
**Terraform** infrastructure — especially multi-environment infra pipelines driven by
per-environment `<env>.tfvars`, or gated deployments that show a reviewable `terraform plan` before
applying. If the repo has both `infra/` (Bicep) and `infra_tf/` (Terraform), generate both and let
them coexist.

## What this skill ships
- **`templates/`** — `terraform-ci.yml` (fmt/validate + per-env plan on PRs), `terraform-deploy.yml`
  (promotes through the discovered stages), and the reusable `_infra_tf.yml` engine.
- **`references/`** — `best-practices.md`, `backend-bootstrap.md` (the state-backend prerequisite),
  `naming-conventions.md`.
- **`scripts/`** — `check-prereqs.sh`, `inspect-repo-tf.sh`, `validate-workflows.sh`.

## Hard constraints
- **Ask before any mutation.** Confirm before writing repo files, changing GitHub
  environments/variables/branches/PRs, or creating Azure resources. Read-only discovery needs no
  approval.
- **Always Terraform; coexist, never replace.** Only generate Terraform pipelines (`terraform
  plan/apply`). Locate the root from discovery, never hardcode paths. If a Bicep pipeline exists,
  leave it untouched — path filters (`infra/**` vs `<infra_tf_dir>/**`) keep them independent.
- **Never author or edit `.tf` sources.** Only `.github/workflows/` files are authored, plus a
  `.gitignore` entry for the runtime backend files, plus per-env `<env>.tfvars` **values** if the
  user asks. The pipeline adapts to the existing Terraform.
- **State backend is a manual prerequisite.** Terraform cannot bootstrap its own state store. Never
  create it automatically — give the user `references/backend-bootstrap.md` and confirm the
  `TF_BACKEND_*` Variables exist before wiring the pipeline.
- **Use the bundled scripts.** Run `scripts/*.sh` in place by absolute path; never copy them into
  the target repo or replace them with inline Python/`node -e`. On Windows, run them through Git
  Bash with `jq` on `PATH`.
- **Rely on active sessions.** Use the user's existing `az login` / `gh`; never ask for credentials.
- **Temp files under `.agent/tmp/`, always cleaned up.** Write scratch (e.g. `repo-facts-tf.json`)
  only there; remove it before finishing, even on failure.
- **Variables only, never secrets.** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
  `TF_BACKEND_RESOURCE_GROUP`, `TF_BACKEND_STORAGE_ACCOUNT`, `TF_BACKEND_CONTAINER` are non-sensitive
  **GitHub Environment Variables** read as `vars.*`. Never read/set secrets; never print values.
- **Don't overwrite existing workflows** without confirming when `github.existing_workflows` already
  contains the Terraform workflow names.
- **Best practices** (`references/best-practices.md`): pin actions to a full SHA;
  `terraform_wrapper: false`; OIDC for provider **and** backend (`ARM_USE_OIDC`/`ARM_USE_AZUREAD`);
  least-privilege `permissions`; `concurrency` guards; `-detailed-exitcode` plan; gitignore the
  runtime backend files.

## Process
1. **Validate tools.** Run `scripts/check-prereqs.sh` (`jq` required; `terraform`/`gh`/`az` from
   active sessions/installs).
2. **Inspect the repo.** Run `scripts/inspect-repo-tf.sh > .agent/tmp/repo-facts-tf.json`. It
   reports the Terraform root/entrypoint, backend type, `bicep_present` (coexistence),
   `<env>.tfvars` stages, multi-env readiness, existing workflows, and (when readable) GitHub
   Environments + variable names. **Trust `infra.backend`** (the committed backend CI sees): it is
   derived only from git-tracked, non-override `.tf`. If `infra.backend_local_override_ignored` is
   `true`, the repo has a gitignored/untracked `*_override.tf` (e.g. `backend_override.tf` with a
   `local` backend — the standard azd local-dev pattern). **Do not treat that as a conflict or a
   blocker:** `actions/checkout` pulls only committed files, so it never reaches CI. Never edit or
   ask to remove it.
3. **Check multi-env readiness.** Read `infra.multi_env`. Ready when every discovered stage has an
   `<infra_tf_dir>/<stage>.tfvars`. If `ready` is `false`, recommend the missing files from
   `multi_env.missing` and offer to add one minimal `<stage>.tfvars` each. **Confirm first.**
4. **Confirm the state backend prerequisite.** Terraform needs an existing azurerm state backend.
   Point the user to `references/backend-bootstrap.md`; confirm the `TF_BACKEND_*` Variables are
   set (or will be) before proceeding. Never create the backend automatically.
5. **Ask for the Terraform version to pin** (`__TF_VERSION__`; offer `1.9.x` as default) and the
   deployment order of the discovered stages (offer the discovered order as default; each stage
   once; save as `ordered_stages`). Derive `ordered_environments` (preview+gated per stage) and
   `ordered_gated_environments`.
6. **Set up GitHub Environments by access level.** Read `github.environments_admin` and
   `required_setup`. Same three branches as the Bicep skill:
   - **No admin access** — blocking. Make no mutation; list, for every `ordered_environments` entry,
     the exact Variable names from `required_setup.variables_per_environment` (`AZURE_CLIENT_ID`,
     `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `TF_BACKEND_RESOURCE_GROUP`,
     `TF_BACKEND_STORAGE_ACCOUNT`, `TF_BACKEND_CONTAINER`), plus reviewers on the gated
     environments and the Azure app registration + federated credentials.
   - **Admin, missing** — ask the reviewers value (verify the login), then create environments and
     any missing Variables (placeholder `update-me`). You may reuse the Bicep skill's
     `setup-github-environments.sh` for the environments + `AZURE_*` trio, then add the three
     `TF_BACKEND_*` Variables the same way. **Confirm before running.**
   - **Admin, present** — reuse existing values; create/overwrite nothing.
7. **Confirm the plan** — Terraform root, `ordered_stages`, `ordered_environments`, reviewers, TF
   version, tfvars files, backend readiness, and any workflow conflicts. **Get explicit approval
   before writing files.**
8. **Render templates** into `.github/workflows/`:
   - `_infra_tf.yml` — replace `__INFRA_TF_DIR__` and `__TF_VERSION__` in its defaults; otherwise
     copy verbatim. Its "Write backend configuration" step auto-detects an existing
     `backend "azurerm"` block in the repo's `*.tf` and, when present, skips writing `backend.tf`
     (supplying the backend settings from the per-env `.hcl` at init) so Terraform never sees a
     duplicate backend configuration; it only writes `backend.tf` for repos that declare no backend.
   - `terraform-ci.yml` — replace `__DEFAULT_BRANCH__`, `__INFRA_TF_DIR__`, `__TF_VERSION__`,
     `__ENVIRONMENTS_INLINE__`.
   - `terraform-deploy.yml` — replace `__DEFAULT_BRANCH__`; expand the single `plan-<env>`/
     `apply-<env>` pair once per `ordered_stages` entry, chaining each stage's `plan-<env>` with
     `needs: apply-<previous_env>` (first has none).
   - Add the gitignore entries from `best-practices.md` for the runtime backend files.
9. **Wire post-deploy (if present).** If the repo has post-provision/post-deploy steps and the
   `cicd-post-deploy` skill's `_post-deploy.yml` is in use, chain an `post-deploy-<env>` job after
   each `apply-<env>` and pass `infra_flavor: terraform` (plus `working_directory` if not
   `infra_tf`). The engine then resolves the resource group and bridges outputs via
   `terraform output -json` instead of `az deployment group show`.
10. **Validate.** Run `scripts/validate-workflows.sh` on the rendered workflows; report the result.
11. **Clean up** all files created under `.agent/tmp/` (remove the directory if empty), even on
    failure.

## Output
Report, in order:
1. **Detected stack** — Terraform root/entrypoint, backend type, whether Bicep also present
   (coexistence), default branch, multi-env readiness, stage names, approved order, TF version,
   existing workflows/environments.
2. **Backend prerequisite** — whether the state backend + `TF_BACKEND_*` Variables are confirmed;
   otherwise the bootstrap steps still required.
3. **Multi-env changes** — tfvars files added or recommended.
4. **Generated files** — the workflows written (+ gitignore entry) and their purpose.
5. **Setup required** — Azure sign-in, GitHub Environments + reviewers, and the exact per-env
   Variables (all six). If you lack GitHub permission, say so plainly and list every environment and
   Variable name.
6. **Validation** — `scripts/validate-workflows.sh` result.
7. **Cleanup** — confirm `.agent/tmp/` files were removed.
