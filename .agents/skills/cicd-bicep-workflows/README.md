# CI/CD Workflow Generator (Bicep)

Generates GitHub Actions infrastructure pipelines for existing **Bicep** repos.

## What it creates

- `bicep-ci.yml`: PR lint/build/format plus per-environment `what-if`.
- `_infra.yml`: reusable workflow for Bicep `what-if` and deploy.
- `bicep-deploy.yml`: gated promotion flow through the params-folder stages.

The workflows use OIDC with `azure/login`, GitHub Environment Variables, pinned actions,
least-privilege permissions, reusable workflows, and environment approval gates.

## How it works

1. Runs `scripts/check-prereqs.sh`.
2. Runs `scripts/inspect-repo.sh` from the target repo root.
3. Confirms the plan before writing workflows or changing GitHub.
4. Renders templates from `templates/` into `.github/workflows/`.
5. Optionally runs `scripts/setup-github-environments.sh` to create/update each discovered
   stage and its matching `<stage>-preview` environment.
6. Runs `scripts/validate-workflows.sh`.

Run scripts in place from this skill folder; do not copy them into the target repo.

## Requirements

- Existing Bicep entrypoint and per-env params in `infra/params/<stage>.bicepparam`.
- `bash`, `jq`, `git`, `grep`/`find`.
- Authenticated `gh` and `az` sessions for GitHub/Azure setup.

## Configuration model

Azure needs **one app registration per stage** discovered from the params folder. Each app
registration needs **two federated credentials**: one for the stage's preview environment
(`<stage>-preview`) and one for its gated deploy environment (`<stage>`).

Each GitHub Environment stores these **Variables**:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

When the setup flow asks for real values, provide one comma-delimited string per logical
stage in that order, for example
`fbf9d98e-766f-405b-8505-eed6686c76af,0e5f8916-b0a3-4c22-8255-9d2f60bde187,f079e81a-26ea-4b26-842b-59c76b431658`.

The resource group is not a GitHub variable; it comes from each `.bicepparam` file's
`resourceGroupName`.

## Contents

```text
scripts/      discovery, GitHub Environment setup, validation
templates/    workflow templates rendered into .github/workflows/
references/   best practices, environment setup, naming conventions
```
