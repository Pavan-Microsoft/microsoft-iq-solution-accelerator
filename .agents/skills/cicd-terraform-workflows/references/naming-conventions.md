# Naming conventions & variables (Terraform)

The generated workflows authenticate to Azure with **OIDC** (`azure/login` + the `ARM_USE_OIDC`
provider/backend flags, no stored client secret) and read all configuration from **GitHub
Environment Variables**. There are **two environments per logical stage discovered from the
`<infra_tf_dir>/<stage>.tfvars` files** — an ungated `<stage>-preview` (used by the `plan` job)
and a gated `<stage>` (used by the `apply` job). **No GitHub secrets are used.**

## Required per environment

All stored as **Variables** (read as `vars.*`), on each generated GitHub Environment:

| Variable                       | Description                                             |
|--------------------------------|---------------------------------------------------------|
| `AZURE_CLIENT_ID`              | Deployment identity (client) ID                         |
| `AZURE_TENANT_ID`              | Entra tenant ID                                         |
| `AZURE_SUBSCRIPTION_ID`        | Target subscription ID                                 |
| `TF_BACKEND_RESOURCE_GROUP`    | Resource group of the Terraform state Storage account   |
| `TF_BACKEND_STORAGE_ACCOUNT`   | Terraform state Storage account name                    |
| `TF_BACKEND_CONTAINER`         | Terraform state blob container                          |

The **state backend is a one-time manual prerequisite** — see `backend-bootstrap.md`. The state
**key is derived automatically** as `<environment>.tfstate`, isolating each stage.

The subscription ID is also exported to Terraform as `TF_VAR_subscription_id` so a
`variable "subscription_id"` in the root is populated without duplicating it in tfvars.

When the skill scaffolds a missing variable it sets the placeholder value **`update-me`**; update
each with its real value afterward. Existing variables are reused unless you provide replacements.

The workflows **assume** these — plus an Azure app registration with federated credentials trusting
the GitHub **Environment-bound** subjects for all generated environments — are already in place. The
default subject format is `repo:<org>/<repo>:environment:<environment>`; use the exact subject shown
by `azure/login` if it reports a federated-credential mismatch.

## Multi-environment tfvars files

One deploy workflow serves every stage: the reusable `_infra_tf.yml` selects the var-file **by the
logical stage name** passed as the `environment` input. The convention is one `<stage>.tfvars` per
stage in the Terraform root:

```
<infra_tf_dir>/
  main.tf
  variables.tf
  outputs.tf
  <stage>.tfvars      # e.g. dev.tfvars, prod.tfvars
  modules/
```

`*.auto.tfvars` files are treated as always-applied shared config, **not** as environment
selectors. `inspect-repo-tf.sh` reports `infra.multi_env.ready` and which stages already have a
file; add the missing `<stage>.tfvars` (minimal, only what differs per environment) so the single
`terraform-deploy.yml` can promote through all discovered stages.

## Coexistence with Bicep

This skill **adds** the Terraform pipeline alongside any existing Bicep pipeline — it never
replaces it. `inspect-repo-tf.sh` reports `infra.bicep_present`. Path filters keep the two CI
workflows independent: `bicep-ci.yml` fires on `infra/**`, `terraform-ci.yml` on
`<infra_tf_dir>/**`. The user chooses which flavor to deploy; both can be wired to the shared
post-deploy stage via its `infra_flavor` input.

## Template placeholders

The caller templates contain a small set of placeholders the generator replaces from
`inspect-repo-tf.sh` output:

| Placeholder                 | Source (repo-facts-tf.json)                      | Example       |
|-----------------------------|--------------------------------------------------|---------------|
| `__DEFAULT_BRANCH__`        | `.default_branch`                                | `main`        |
| `__INFRA_TF_DIR__`          | `.infra.tf_root_dir`                             | `infra_tf`    |
| `__ENVIRONMENTS_INLINE__`   | `.recommended.stages` rendered as YAML inline    | `dev, prd`    |
| `__TF_VERSION__`            | pinned Terraform version (ask the user; default `1.9.x`) | `1.9.x` |
| `__DEPLOY_JOBS__`           | single `plan-<env>`/`apply-<env>` pair repeated per stage | `plan-dev`... |

`terraform-deploy.yml` ships one reusable `plan-<env>`/`apply-<env>` job pair. Render by repeating
that pair once per ordered stage, substituting `<env>` with the stage name and chaining stages so
the next stage's `plan-<env>` has `needs: apply-<previous_env>` (the first stage's plan has no
`needs`). Keep every pair identical and do not add per-job `permissions`; the workflow-level and
`_infra_tf.yml` permissions define OIDC access.

`_infra_tf.yml` defaults the working directory to `infra_tf` and the var-file to
`<env>.tfvars`. If the repo differs, pass `working_directory` / `var_file` inputs from the caller.
`_infra_tf.yml` has no placeholders except `__INFRA_TF_DIR__`/`__TF_VERSION__` in its defaults —
otherwise copy it verbatim.
