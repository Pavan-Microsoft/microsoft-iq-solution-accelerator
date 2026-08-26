# CI/CD best practices (infrastructure)

Guidance the agent applies when generating GitHub Actions pipelines that deploy
**infrastructure (Bicep)**. The `templates/` are starting points; these rules explain how to
adapt and extend them. This skill generates the **workflows that run existing infrastructure**
— it does not author Bicep and does not deploy application code.

## Core rules (always)

- **Pin every action to a full commit SHA**, with a `# vX.Y.Z` comment. Never use mutable
  tags like `@v4` or `@main`. Resolve a tag to its SHA:
  `gh api repos/<owner>/<action>/git/ref/tags/<tag> --jq '.object.sha'`.
- **Prefer first-party actions** (`actions/*`) and the official `azure/login`. Avoid other
  third-party actions; if unavoidable, pin to SHA and justify it.
- **Least-privilege `permissions`.** Default to `contents: read`. Add `id-token: write` only
  where `azure/login` needs it.
- **`concurrency`** on the deploy workflow (`group: bicep-deploy`) to avoid overlapping
  deploys; do not cancel in-progress deploys (`cancel-in-progress: false`).
- **Reusable workflows** (`workflow_call`) for shared logic; thin caller workflows per
  environment. Keep inputs minimal.
- **No secrets in code or logs.** Read config from GitHub Environment **Variables** (`vars.*`).
  This skill uses no GitHub secrets at all.
- **Everything runs on `ubuntu-latest`** unless a project needs otherwise.

## Authentication (OIDC)

Workflows authenticate to Azure with the official `azure/login` action using **OIDC** — the
recommended, most secure method (see the action's
[Login with OpenID Connect (OIDC)](https://github.com/marketplace/actions/azure-login#login-with-openid-connect-oidc-recommended)
docs). The job requests a short-lived GitHub-issued token (`permissions: id-token: write`)
that Azure trusts via a **federated credential**. **No Azure client secret is stored.**

The identity IDs are OIDC **identifiers, not secrets**, so they are stored as non-sensitive
**GitHub Environment Variables** and read as `vars.*`:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: azure/login@532459ea530d8321f2fb9bb10d1e0bcf23869a43 # v3.0.0
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

The generated workflows **assume the following prerequisites are already in place** — the
skill does not create them:

- An **Azure app registration** (or user-assigned managed identity) with **federated
  credentials** trusting this repository's GitHub **Environment-bound** OIDC subjects. Because
  every plan/apply job binds a GitHub Environment, Azure receives an `environment:<name>`
  subject for each environment, not `pull_request` or `ref`. Create one federated credential
  per discovered GitHub Environment (`<stage>-preview` and `<stage>` for every params-folder stage). The
  common default subject format is `repo:<org>/<repo>:environment:<environment>`. Some
  organizations customize the subject template to use stable IDs, for example
  `repository_owner_id:<owner-id>:repository_id:<repo-id>:environment:<environment>`; in that
  case, use the exact subject shown in the failed `azure/login` log. In the Azure portal's
  "GitHub Actions deploying Azure resources" form, click **Edit** beside **Subject
  identifier** and paste the exact `azure/login` subject if the generated value differs from
  the log. The issuer is `https://token.actions.githubusercontent.com` and the audience is
  `api://AzureADTokenExchange`.
- The identity holds the minimum Azure role at the narrowest scope that still works. Because the
  pipeline **creates the resource group by default** (`CREATE_RESOURCE_GROUP` unset or not `false`),
  the identity needs **Contributor at the subscription scope**, since creating a resource group is a
  subscription-level operation. **Exception:** when the resource group already exists you may set
  `CREATE_RESOURCE_GROUP=false` to skip creation and scope the assignment down to that
  resource group (least privilege).
- The **GitHub Environment Variables** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
  `AZURE_SUBSCRIPTION_ID` are set on every generated environment. The **resource group is not
  a variable** — it comes from each `.bicepparam`'s `resourceGroupName`.

If any prerequisite is missing, tell the user exactly what to create (see
`naming-conventions.md`); do not attempt to provision it silently.

If `azure/login` reports **"No subscriptions found"**, OIDC matched successfully but the
identity has no Azure RBAC assignment in the target subscription. Assign the identity a
least-privilege role at the target resource group (or subscription for subscription-scoped
Bicep), and verify `AZURE_SUBSCRIPTION_ID` points to that subscription.

## Environments, gating & promotion

- Use **two GitHub Environments per stage**: an ungated `<stage>-preview` (bound by the
  what-if `plan` job) and a gated `<stage>` with **required reviewers** (bound by the `apply`
  job). Declaring `environment: <stage>` on the apply job makes GitHub enforce approval before
  it runs; the plan job binds `<stage>-preview` so the what-if runs without a gate. Binding an
  environment is also what brings its env-scoped identity Variables into scope for
  `azure/login`, and it changes the OIDC subject Azure must trust to that environment name.
- **One deploy workflow** promotes through all stages: a chain of `plan` (preview) → gated
  `apply` jobs (`needs:`), one pair per stage. The logical stage name selects the matching
  `params/<env>.bicepparam`; the target resource group comes from that file's
  `resourceGroupName` — no separate per-env workflow files.
- Promotion: a PR shows the plan for every env → merging to the default branch runs
  `bicep-deploy.yml`, which previews+applies each discovered stage in order.
- `scripts/setup-github-environments.sh` creates the discovered environments + reviewers and
  scaffolds the Azure OIDC identity **Variables** (default value `update-me`). It needs repo
  **admin**; if the user lacks it, relay the manual environment + variable requirements it
  prints and make clear everything must be set up manually.

## Multi-environment parameters

Deploying multiple environments from one template requires a per-environment parameters
file. Preferred: `<infra_dir>/params/<env>.bicepparam` (each with `using '../main.bicep'`).
`inspect-repo.sh` reports `infra.multi_env.ready`; if a repo isn't ready, recommend adding
the minimal per-env files before generating `bicep-deploy.yml` (see `naming-conventions.md`).
## Two workflows: CI and deploy

- **`bicep-ci.yml`** (pull requests) — validates changes before they merge:
  - `lint-build` job (no Azure creds): `az bicep lint`, `az bicep build` (compile each
    template), `az bicep build-params` (compile each `.bicepparam`), and an `az bicep format`
    diff check. These catch syntax, linter, and formatting issues cheaply and fast.
  - `plan` job (`needs: lint-build`): a cloud `what-if` per environment (via `_infra.yml`),
    so reviewers see what would change. Requires OIDC + the environment variables.
- **`bicep-deploy.yml`** (push to the default branch) — promotes through the discovered stages.

Linter severity is configured in `bicepconfig.json`; set rules to `error` there to make
`bicep-ci.yml` fail on them. Offer to add a `bicepconfig.json` if the repo lacks one.

## Infrastructure pipelines (Bicep)

Covered by the templates. Principles:

- **Plan before apply.** Run `az deployment ... what-if` and publish it to the job's **check
  summary** so it is reviewable for every environment — including before the gated
  environment approvals.
- **Gate the apply** behind the gated `<stage>` environment. Because the apply job's steps
  only run after approval, use a separate `plan` job bound to the ungated `<stage>-preview`
  environment so the what-if is visible *before* the reviewer approves.
- Resource-group scope uses `az deployment group`; subscription scope uses
  `az deployment sub` + `AZURE_LOCATION`.
- **Name each deployment** (`--name "gh-<run_id>-<run_attempt>"`) so it is easy to find,
  audit, and roll back in the Azure portal and ties back to the workflow run.
- Trigger the PR CI on `paths:` under the infra directory to avoid unrelated runs.

## Config the agent should expect

Per GitHub Environment, all stored as non-sensitive **Variables** (`vars.*`) — no secrets:

- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
  (+ `AZURE_LOCATION` for subscription scope). The resource group is **not** a variable — it
  is read from each `.bicepparam`'s `resourceGroupName`.

See `naming-conventions.md`.
