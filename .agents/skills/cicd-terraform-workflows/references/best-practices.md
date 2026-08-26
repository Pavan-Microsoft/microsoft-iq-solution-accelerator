# Best practices (Terraform CI/CD)

## Actions & auth
- **Pin every action to a full commit SHA** with a `# vX.Y.Z` comment. The templates already do
  this for `actions/checkout`, `azure/login`, `hashicorp/setup-terraform`, and
  `actions/upload-artifact`.
- **OIDC, no secrets.** `azure/login` uses `id-token: write` with the `AZURE_*` Variables; the
  azurerm **provider and backend** both use `ARM_USE_OIDC=true` (plus `ARM_USE_AZUREAD=true` so
  the state Storage account works with shared-key access disabled). No client secret, no storage
  key is ever stored.
- **`terraform_wrapper: false`** on `setup-terraform` — the wrapper otherwise corrupts
  `terraform output -json` (the outputs bridge to post-deploy depends on clean stdout).
- **Least privilege `permissions`.** Workflow-level `contents: read`; `id-token: write` only where
  OIDC is needed. `concurrency` guards serialize `terraform-deploy` so two applies never race the
  same state.

## Plan / apply discipline
- Plan with **`-detailed-exitcode`**: exit `0` = no changes, `2` = changes, other = error. The
  engine surfaces `terraform show` into the job summary for review.
- The PR CI (`terraform-ci.yml`) runs `fmt -check`, `init -backend=false`, and `validate` with no
  cloud state, then a per-environment `plan` bound to the ungated `<stage>-preview` environment so
  PRs never wait on reviewers.
- `terraform-deploy.yml` gates each `apply` behind the reviewer-protected `<stage>` environment.

## Backend files are generated, never committed
The workflow writes `backend.tf` + `backend.<env>.hcl` at runtime. **Add them to `.gitignore`** so
the local (partial) backend config never conflicts with CI:

```gitignore
# Terraform CI-generated backend config
infra_tf/backend.tf
infra_tf/backend.*.hcl
infra_tf/tfplan
infra_tf/.terraform/
```

If the repo commits a static `backend.tf`, drop the runtime write step instead and pass only the
`-backend-config` values.

## Azure identity — one-time setup (manual prerequisite)
Per stage, create an app registration (or user-assigned managed identity) and a **federated
credential per environment** (`<stage>-preview` and `<stage>`):

```bash
# Federated credential subject (repeat for -preview and the gated env)
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "gh-<org>-<repo>-<env>",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<org>/<repo>:environment:<env>",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Role assignments for the deployment identity:
- **Contributor** at the target subscription (or resource group) scope to create/manage infra.
- **Storage Blob Data Contributor** on the state Storage account (see `backend-bootstrap.md`).
- Any data-plane roles the specific resources need (e.g. RBAC for AI/Cosmos) as the solution
  requires.

Use the exact federated subject `azure/login` reports if it flags a mismatch (some orgs use the
ID-based `repository_owner_id:...:repository_id:...:environment:<env>` format).
