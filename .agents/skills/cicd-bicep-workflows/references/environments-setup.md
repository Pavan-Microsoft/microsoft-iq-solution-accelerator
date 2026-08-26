# GitHub Environments setup

The promotion model uses **two GitHub Environments per stage** — an ungated `<stage>-preview`
for the what-if, and a gated `<stage>` for the apply:

| Environment         | Bound by             | Gate               | Purpose                              |
|---------------------|----------------------|--------------------|--------------------------------------|
| `<stage>-preview`   | `<stage>` plan job   | none               | run + publish what-if for review     |
| `<stage>`           | `<stage>` apply job  | required reviewers | reviewer approves, then deploys      |

The apply jobs bind `environment: <stage>`, so GitHub enforces the environment's protection
rules (required reviewers) **before** the job runs. The plan jobs bind the ungated
`<stage>-preview`, so the what-if runs and is published **without** waiting on a reviewer.
Each environment carries its own OIDC identity Variables (env-scoped), so binding the
environment also brings those variables into scope for `azure/login`. The what-if is visible
before approval in the check summary of each stage's `plan` job.

## Automated

```bash
.agents/skills/cicd-bicep-workflows/scripts/setup-github-environments.sh \
  --environments "<stage-a>-preview,<stage-a>,<stage-b>-preview,<stage-b>" \
  --gated "<stage-a>,<stage-b>" \
  --reviewers "alice,myorg/platform-approvers"
```

To supply the real Azure identity values up front (the skill asks whether you want to), ask
for one comma-delimited string per logical stage discovered from `infra.multi_env.parameters`
only, in this order: `AZURE_CLIENT_ID,AZURE_TENANT_ID,AZURE_SUBSCRIPTION_ID`. Anything
omitted is scaffolded as `update-me`. Do not ask separately for preview environments — the
script automatically uses the matching stage values for each preview environment:

```bash
.agents/skills/cicd-bicep-workflows/scripts/setup-github-environments.sh \
  --environments "<stage-a>-preview,<stage-a>,<stage-b>-preview,<stage-b>" \
  --gated "<stage-a>,<stage-b>" --reviewers "alice" \
  --environment-values "<stage-a>:<stage-a-client-id>,<stage-a-tenant-id>,<stage-a-subscription-id>" \
  --environment-values "<stage-b>:<stage-b-client-id>,<stage-b-tenant-id>,<stage-b-subscription-id>"
```

For subscription-scoped Bicep, add `AZURE_LOCATION` as a fourth comma-delimited value for each
stage and pass `--scope subscription`.

Reviewers accept both usernames (`alice`) and team slugs (`myorg/platform-approvers`) — the
skill asks you for this value (via an interactive tool when available) and verifies the login
before running. By default the script detects `--org-repo` from your `gh`/git session. Pass
`--environments` from `required_setup.environments`; the script creates those environments. It scaffolds
the required Actions **variables with the value `update-me`** (`AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`; add `AZURE_LOCATION` as the fourth
comma-delimited value with `--scope subscription`) unless you provide a value via the flags
above. Preview environments reuse the corresponding stage values automatically — all as
non-sensitive **Variables**, never secrets. Existing variables are reused unless you
explicitly provide replacement values during setup. The resource
group is **not** a variable — it comes from each `.bicepparam`'s `resourceGroupName`. The
script processes **every** environment (it never stops after the first failure) and, if
required reviewers can't be applied to a gated environment, it still creates the environment
without them and warns you; it prints a per-environment summary at the end.
**Environment management needs repository admin** — if you lack it, the script prints exactly
which environments and variables to create manually and makes clear everything must be set up
by hand (see `naming-conventions.md`).

Note: the skill always confirms with you before running this script or making any change in
GitHub.

## Manual equivalent

Create/patch a gated environment with a required reviewer:

```bash
gh api -X PUT repos/myorg/myrepo/environments/<stage> --input - <<'JSON'
{
  "wait_timer": 0,
  "prevent_self_review": true,
  "reviewers": [{"type": "User", "id": 123456}],
  "deployment_branch_policy": null
}
JSON

# The matching ungated preview environment (no reviewers):
gh api -X PUT repos/myorg/myrepo/environments/<stage>-preview --input - <<'JSON'
{ "deployment_branch_policy": null }
JSON

# All config is a non-sensitive VARIABLE (the identity IDs are OIDC identifiers, not secrets).
# Set the same three on BOTH <stage>-preview and <stage>:
gh variable set AZURE_CLIENT_ID       --env <stage> --repo myorg/myrepo --body "<client-id>"
gh variable set AZURE_TENANT_ID       --env <stage> --repo myorg/myrepo --body "<tenant-id>"
gh variable set AZURE_SUBSCRIPTION_ID --env <stage> --repo myorg/myrepo --body "<subscription-id>"
```

## After setup

Ensure one Azure app registration per discovered stage, with federated credentials (OIDC)
trusting each matching environment-bound subject. The default subject format is
`repo:myorg/myrepo:environment:<environment>`, but
some organizations use an ID-based subject template; use the exact subject shown by
`azure/login` if it reports a mismatch. In the Azure portal, click **Edit** beside **Subject
identifier** and replace the generated value when needed. Set the remaining per-environment
variables and each `.bicepparam`'s `resourceGroupName` — see `naming-conventions.md` and
`best-practices.md`.

Validate the rendered workflows with the skill's Bash script (never hand-write an inline
Python/YAML check):

```bash
.agents/skills/cicd-bicep-workflows/scripts/validate-workflows.sh
```
