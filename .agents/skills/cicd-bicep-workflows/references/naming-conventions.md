# Naming conventions & variables

The generated workflows authenticate to Azure with **OIDC** (`azure/login`, no stored client
secret) and read the identity configuration from **GitHub Environment Variables**. There are
**two environments per logical stage discovered from `<infra_dir>/params/`** — an ungated
`<stage>-preview` (used by the what-if `plan` job) and a gated `<stage>` (used by the `apply`
job). **No GitHub secrets are used** — the identity IDs are OIDC identifiers, not sensitive
values, so everything is a Variable read as `vars.*`.

## Required per environment

All stored as **Variables** (read as `vars.*`), on each generated GitHub Environment:

| Variable                | Description                                  |
|-------------------------|----------------------------------------------|
| `AZURE_CLIENT_ID`       | Deployment identity (client) ID              |
| `AZURE_TENANT_ID`       | Entra tenant ID                              |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID                       |

The **resource group is not a GitHub Variable** — it is read at deploy time from the
`resourceGroupName` parameter in each `<infra_dir>/params/<env>.bicepparam` file, so Bicep
config is the single source of truth for the deployment target.

Subscription-scoped Bicep also needs the `AZURE_LOCATION` variable (and `_infra.yml` switched
to `az deployment sub`).

## The pipeline creates the resource group by default

By default the pipeline **creates** the target resource group (idempotent `az group create`), so it
never needs to pre-exist. This is the standard behaviour for this accelerator, where a fresh
resource group is provisioned per deployment. It requires the deployment identity to have
**subscription-scoped** Contributor. To opt out — when the resource group already exists and the
identity is only resource-group scoped (least privilege) — set one **Variable** per environment:

| Variable                 | Value     | Effect                                                      |
|--------------------------|-----------|-------------------------------------------------------------|
| `CREATE_RESOURCE_GROUP`  | `false`   | Skips the `az group create` step; the resource group must already exist. Unset/any other value keeps the default "create the resource group" behaviour. |

When the resource group is created (the default), the step needs a **location**, resolved in this
order:

1. a `location` parameter set in `<infra_dir>/params/<env>.bicepparam` (Bicep config wins), else
2. the `AZURE_LOCATION` Environment Variable.

If neither is present the run fails with a clear error. The `az group create` is idempotent, so
it is safe to run on both the `plan` (what-if) and `apply` passes — this is also what makes the
what-if work against a brand-new resource group.

**Permission impact:** creating a resource group is a **subscription-level** operation, so by
default the deployment identity needs **Contributor at the subscription scope** (not just on a
pre-existing resource group). Set `CREATE_RESOURCE_GROUP=false` to fall back to the narrower
resource-group-scoped role when the group already exists. See `best-practices.md` for the
role-assignment commands.

When the skill scaffolds any missing variable it sets the placeholder value **`update-me`**;
update each with its real value afterward. Existing variables are reused unless you explicitly
provide replacement values during setup.

The workflows **assume** these — plus an Azure app registration with federated credentials
trusting the GitHub **Environment-bound** subjects for all generated environments — are already
in place. The default subject format is `repo:<org>/<repo>:environment:<environment>`, but some
organizations customize it to an ID-based format such as
`repository_owner_id:<owner-id>:repository_id:<repo-id>:environment:<environment>`. Use the
exact subject shown by `azure/login` if it reports a federated-credential mismatch. See
`best-practices.md`.

## Access-based environment handling

`inspect-repo.sh` reports `github.environments_admin` (can you manage environments?) and
`github.environment_state` (per-env existence + existing variable **names**). The skill
follows one of three branches:

1. **No admin access** (`environments_admin: false`) — a blocking prerequisite; the skill
   makes no mutation and states plainly that **everything must be set up manually**. Ask an
   admin to create, under **Settings > Environments** and **Settings > Secrets and variables >
   Actions** (the **Variables** tab), every environment listed in
   `required_setup.environments` (required reviewers on `required_setup.gated_environments`)
   and the variables above on each.
2. **Admin, but missing** — the skill asks for the required-reviewers value (and whether to
   supply real variable values). When supplying values, it asks once per logical stage for a
   comma-delimited string in the order `AZURE_CLIENT_ID,AZURE_TENANT_ID,AZURE_SUBSCRIPTION_ID`
   (plus `AZURE_LOCATION` as a fourth value for subscription scope), then runs
   `setup-github-environments.sh` to create the environments and any missing **variables with
   the value `update-me`** for you to update later.
3. **Admin, already present** — existing variables that match what's needed are **reused
   as-is**; nothing is created or overwritten.

## Multi-environment parameters files

One deploy workflow serves every stage: the reusable `_infra.yml` selects the parameters
file **by the logical stage name** discovered from the params folder and passed as the
`environment` input — distinct from the bound GitHub Environment. The convention is one small
`.bicepparam` per stage:

```
<infra_dir>/
  main.bicep
  params/
    <stage>.bicepparam
```

Each file links to the template and sets only the values that differ per environment,
including the **`resourceGroupName`** that targets the deployment:

```bicep
// infra/params/<stage>.bicepparam
using '../main.bicep'

param solutionName = '<solution-name>-<stage>'
param resourceGroupName = 'rg-<solution-name>-<stage>'
// ...only what changes per environment
```

`inspect-repo.sh` reports `infra.multi_env.ready` and which stages already have a file. If a
repo is not ready, add the missing `params/<stage>.bicepparam` files (keep them minimal) so
the single `bicep-deploy.yml` can promote through all discovered stages. A repo with a different
existing convention (for example `main.parameters.<stage>.json`) is also detected as ready — in that
case pass `parameters_file` overrides instead of adding new files.

## Template placeholders

The caller templates (`bicep-ci.yml`, `bicep-deploy.yml`) contain a small set of placeholders
the generator replaces from `inspect-repo.sh` output:

| Placeholder                 | Source (repo-facts.json)                         | Example       |
|-----------------------------|--------------------------------------------------|---------------|
| `__DEFAULT_BRANCH__`        | `.default_branch`                                | `main`        |
| `__INFRA_DIR__`             | dir of `.infra.bicep_entrypoint`                 | `infra`       |
| `__ENVIRONMENTS_INLINE__`   | `.recommended.stages` rendered as YAML inline    | `dev, prd`    |
| `__DEPLOY_JOBS__`           | single `plan-<env>`/`apply-<env>` pair repeated per stage | `plan-dev`... |

`bicep-deploy.yml` ships one reusable `plan-<env>`/`apply-<env>` job pair. Render `__DEPLOY_JOBS__`
by repeating that pair once per ordered stage, substituting `<env>` with the stage name and
chaining stages so the next stage's `plan-<env>` has `needs: apply-<previous_env>` (the first
stage's plan has no `needs`). Keep every pair identical to the template and do not add
`permissions` inside a job; the workflow-level permissions and `_infra.yml` reusable workflow
permissions define OIDC access.

`_infra.yml` defaults the template to `infra/main.bicep` and the parameters to
`<template_dir>/params/<env>.bicepparam`. If the repo's entrypoint or per-env parameters
differ, pass `template_file` / `parameters_file` as inputs from the caller. `_infra.yml`
itself has no placeholders — copy it verbatim.
