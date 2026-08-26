# CI/CD Post-Deployment (azd-native, solution-agnostic)

Generates the GitHub Actions workflow that runs a solution's **post-deployment steps** after the
infrastructure is provisioned. It is the companion to `cicd-bicep-workflows` (and the Terraform
infra skill): those skills deploy the infrastructure; this one runs the post-deploy steps on top
of it.

The skill contains **no solution-specific knowledge**. Everything about a given repo — which
scripts run, in what order, which toolchains they need, and which steps are manual — is
**discovered at generation time** from the repo's own azd contract (`azure.yaml` hooks) and its
deployment guide, then substituted into a generic engine template. The same skill works unchanged
across any number of azd-based solution accelerators.

## Use when
The user wants to automate the steps that follow `azd up` / an infra deployment — running the
solution's post-provision/post-deploy scripts (building images, seeding data, assigning roles,
etc.) — as a CI/CD job, ideally chained into the same pipeline as the infra deploy so one run
provisions **and** configures the solution.

## What this skill ships
- **`templates/`** — `_post-deploy.yml` (a reusable `workflow_call` engine that reconstructs the
  azd environment and runs the discovered scripts; supports both `bicep` and `terraform` infra
  flavors) and `bicep-deploy.post-deploy-job.yml` (the snippet that chains it after the infra
  deploy).
- **`references/`** — `post-deploy-conventions.md` (the discovery contract, the outputs→azd-env
  bridge, and the render mapping).
- **`scripts/`** — `inspect-post-deploy.sh` (read-only discovery of the repo's azd hooks, guides,
  and the resulting ordered post-deploy plan).

## The discovery contract (how a repo is read generically)
Every azd solution declares its post-deploy work in `azure.yaml` under `hooks:`
(`preprovision` / `postprovision` / `predeploy` / `postdeploy`). For each hook the discovery
script reads the **POSIX variant** (CI is Linux) and classifies its `run_mode`:
- **`executes`** — the hook actually invokes a script (`pwsh -File x.ps1`, `bash x.sh`, `./x.sh`).
  Those scripts are the automated post-deploy steps.
- **`prints_only`** — the script name only appears inside an `echo`/`printf`/`Write-Host`; the
  hook is just telling a human to run it. Those still become plan entries (they are the intended
  post-deploy steps) but are flagged so you confirm them with the user.

The deployment guide (e.g. `documents/DeploymentGuide.md`) is parsed for a post-deploy-titled
section and any additional script references there are merged in. The result is
`post_deploy_plan.scripts` — the union of hook scripts (in hook order) plus guide-only scripts,
**deduped by normalized filename stem** so the `.sh`/`.ps1` variants of the same logical step are
not listed twice. Toolchain needs (`needs_pwsh` / `needs_bash` / `needs_python`) and
`interactive_prompts` / `reads_azd_env` are derived mechanically — never by domain keywords.

## Hard constraints
- **Ask before any mutation.** Confirm with the user (via an interactive input tool when
  available) before writing repo files, changing GitHub environments/variables, or triggering a
  deployment. Read-only discovery needs no approval.
- **No solution-specific content in the skill.** The skill's own files (engine template, docs,
  discovery script) must never name a scenario, domain, auth mode, or specific filename. Anything
  solution-specific is discovered at runtime and injected into the rendered workflow only.
- **No source changes.** Never edit the repo's Bicep/Terraform, application code, or
  post-provision **scripts**. The pipeline adapts to the existing scripts; it does not rewrite
  them. Only workflow files under `.github/workflows/` are authored.
- **azd-native reconstruction (no script edits).** The post-deploy scripts read configuration the
  way `azd` would have written it (`azd env get-values`, a generated `.env`, or plain environment
  variables). The engine reproduces that from the infra deployment's **outputs** and hydrates the
  azd env, a repo-root `.env`, and `$GITHUB_ENV`. See `references/post-deploy-conventions.md`.
- **Confirm the plan; don't blindly transcribe the guide.** Present the discovered
  `post_deploy_plan.scripts` (with `source` = hook or guide, and each hook's `run_mode`) and the
  `guides` list, then **read the guides and confirm with the user** which steps CI should run and
  which are manual/interactive — before generating anything. Steps flagged
  `interactive_prompts` or `prints_only` need explicit user confirmation.
- **Prefer running steps in CI; default rather than exclude.** A post-deploy step is not
  developer-only just because it takes a mode/scenario/config selector or shows a simple
  confirmation prompt. When such a step has a **documented or neutral default** and a
  non-interactive invocation, **include it** and run it unattended with that default — pass the
  default selector as a `run_step` argument and pipe stdin for simple "press enter" prompts —
  confirming the chosen default with the user. Classify a step three ways:
  - **run in CI** (default) — build/setup/data/role steps that can run unattended, using defaults
    where inputs are unspecified.
  - **developer-only** (exclude) — genuinely interactive local **validation/smoke** steps with no
    unattended path and no deployment effect (e.g. an interactive test/chat runner, IDE
    onboarding).
  - **manual post-step** (reminder only) — steps requiring **privileged interactive setup** that CI
    must not perform unattended: creating app registrations/secrets, granting API permissions,
    admin consent, or portal-only auth. These stay reminders even when a default exists.
- **Manual steps come from the guides, surfaced as reminders.** The skill does not guess manual
  steps with heuristics. Read the guides, agree the manual list with the user, and emit them as a
  run-summary reminder in the workflow — they are not executed by CI.
- **Depends on the infra deploy.** This workflow runs after a successful infra deployment and
  needs the **deployment name** and target **resource group** (bicep) or Terraform **state**
  (terraform) to read outputs. When chained after the infra skill, consume the `deployment_name`
  job output; otherwise the engine resolves the latest succeeded deployment in the resource group.
- **Use the bundled script.** Run `scripts/inspect-post-deploy.sh` in place by absolute path;
  never copy it into the target repo or replace it with inline Python/ad-hoc one-offs. Extend it
  if a capability is missing.
- **Rely on active sessions.** Use the user's existing `az login` / `gh` sessions; never ask for
  credentials.
- **Temp files under `.agent/tmp/`, always cleaned up.** Write all scratch/intermediate files
  (e.g. `post-deploy-facts.json`) only under `.agent/tmp/` — never in the repo root, `.github/`,
  `infra/`, or the skill folder — and remove them before finishing, even on failure.
- **Variables only, never secrets.** Reuse the same OIDC identity Variables as the infra skill
  (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`; plus `AZURE_LOCATION` and the
  `TF_BACKEND_*` variables for Terraform). Never read/set GitHub secrets and never print variable
  *values*.
- **Best practices** (shared with the infra skill): pin actions to a full commit SHA (with a
  `# vX.Y.Z` comment); prefer first-party `actions/*` and official `azure/login`; least-privilege
  `permissions`; OIDC via `azure/login` (`id-token: write`, no client secret); reusable workflows.

## Process
1. **Validate tools.** Confirm `jq` is available and the user has active `az`/`gh` sessions
   (reuse the infra skill's `check-prereqs.sh` when present).
2. **Inspect the repo.** Run `scripts/inspect-post-deploy.sh <repo_root> > .agent/tmp/post-deploy-facts.json`.
   It reports: `infra_kind`; the `azd` block (`present`, `name`, `infra_provider`, and per-hook
   `run_mode` + `scripts`); the `guides` list and any `guide_post_deploy` scripts; and the derived
   `post_deploy_plan` (`scripts:[{path,runner,source}]`, `requirements`, `reads_azd_env`,
   `interactive_prompts`, `needs_pwsh`/`needs_bash`/`needs_python`) plus `notes`.
3. **Read the guides and confirm the plan with the user.** Open each path in `guides`, then
   present `post_deploy_plan.scripts` and agree: which steps CI runs (and their order), which are
   interactive/`prints_only` and must be confirmed, and which are **manual post-steps** (surfaced
   as reminders only). Do not infer any of this from keywords — it comes from the guide text and
   the user. **Get explicit approval before writing files.**
4. **Resolve the infra flavor and outputs source.** Determine `bicep` vs `terraform` from
   `infra_kind`. For bicep, confirm the deployment-name source (infra-skill job output, or "latest
   succeeded deployment in the resource group"). For terraform, confirm the `working_directory`
   and the `TF_BACKEND_*` Variables. Note any values the scripts need that are **not** infra
   outputs (e.g. preprovision-generated secrets) — those cannot be reconstructed and must be
   surfaced as required Variables/reminders (see the limitation below).
5. **Render `_post-deploy.yml`** into `.github/workflows/` (copy the engine from `templates/` and
   substitute the placeholders — no other edits):
   - `__NEEDS_PYTHON__` → `true`/`false` from `post_deploy_plan.needs_python`.
   - `__PY_VERSION__` → the repo's Python version (from `.python-version`/pyproject/guide, else a
     sensible default).
   - `__REQUIREMENTS__` → `post_deploy_plan.requirements` (leave a harmless placeholder when
     `needs_python` is false; the step is gated off).
   - `__POST_DEPLOY_STEPS__` → one `run_step <runner> <path>` line per confirmed script, in order,
     each indented 10 spaces (`runner` ∈ `bash`|`pwsh`|`python` from each entry's `runner`). Append
     arguments only for a step that needs a non-interactive default selector
     (e.g. `run_step python path/to/step.py --<selector> <default>`), and prefix `printf '\n' | `
     for a step with a simple confirmation prompt.
   - `__MANUAL_POST_STEPS__` → the agreed manual steps as markdown bullets, or a "none" note.
   - `__TF_VERSION__` → the Terraform version (terraform flavor only).
6. **Chain into the infra pipeline (optional but preferred).** Add a `post-deploy-<env>` job to
   the infra skill's `bicep-deploy.yml` (or the Terraform deploy workflow) that `needs:` the gated
   `apply-<env>` job and calls `_post-deploy.yml`, passing `deployment_name`
   (and `infra_flavor: terraform` + `working_directory` for Terraform). Use
   `templates/bicep-deploy.post-deploy-job.yml` as the snippet, one per stage that should run
   post-deploy — so one push provisions **and** configures the solution behind a single approval.
   Confirm before modifying the deploy workflow.
7. **Validate.** Lint/parse the rendered workflow (reuse the infra skill's `validate-workflows.sh`,
   or `actionlint` + a YAML parse) and report the result.
8. **Clean up** all files created under `.agent/tmp/` (remove the directory if empty), even if an
   earlier step failed.

## Output
Report, in order:
1. **Detected post-deploy plan** — infra flavor, azd hooks used and their `run_mode`, the guides,
   the ordered scripts (with runner + source), toolchain needs, and any interactive-prompt flag.
2. **Confirmed split** — the CI-run steps (and order) and the manual/interactive steps, as agreed
   with the user after reading the guides.
3. **Generated files** — `_post-deploy.yml` and any change to the infra deploy workflow.
4. **Setup required** — reused OIDC/Terraform Variables, and any non-output values the scripts
   need that CI cannot reconstruct (surfaced as required Variables/reminders).
5. **Validation** — the workflow lint/parse result.
6. **Cleanup** — confirm `.agent/tmp/` files were removed.

## Known limitation (surface to the user; not a code change)
- **Preprovision-generated values are not deployment outputs.** Some solutions generate secrets or
  IDs during a `preprovision` hook (not emitted as infra outputs). The engine reconstructs the azd
  env from **outputs only**, so such values cannot be reproduced automatically. Discovery flags
  the relevant hook; surface these as required GitHub Variables the user must set, or as a manual
  reminder.
