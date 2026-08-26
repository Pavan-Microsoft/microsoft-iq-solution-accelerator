# Post-deploy conventions

How the post-deploy layer runs a solution's post-provision/post-deploy steps in CI **without
editing any Bicep, Terraform, application, or post-provision script** — only workflow files under
`.github/workflows/`. Nothing here is solution-specific: the skill discovers each repo's steps
from its own azd contract and injects them into the generic engine.

## The discovery contract: azd hooks + guides

`azure.yaml` is the generic source of truth. Its `hooks:` block declares the lifecycle scripts a
solution runs (`preprovision` / `postprovision` / `predeploy` / `postdeploy`). `inspect-post-deploy.sh`
reads, for each hook, the **POSIX variant** (`posix.run` / `posix.shell`, or the flat `run`) — CI
is Linux — and classifies:

| `run_mode`     | Meaning                                                                 | Plan treatment |
|----------------|-------------------------------------------------------------------------|----------------|
| `executes`     | The hook invokes a script (`pwsh -File x.ps1`, `bash x.sh`, `./x.sh`).   | Automated step. |
| `prints_only`  | The script name appears only inside `echo`/`printf`/`Write-Host`.       | Intended step, **confirm with user** (the repo expects a human to run it). |

The `runner` for each script is derived from its extension: `.sh` → `bash`, `.ps1` → `pwsh`,
`.py` → `python`.

The **deployment guide(s)** are then parsed: the section under a post-deploy-titled heading is
scanned for additional script references. Those merge into the plan as `source: guide`.

The final `post_deploy_plan.scripts` is the **union** of hook scripts (in hook order, first) and
guide-only scripts, **deduped by normalized filename stem**:

```
sub(".*/";"") | sub("\\.[^.]+$";"") | ascii_downcase | gsub("[^a-z0-9]";"")
```

so `setup-data.sh` and `setup-data.ps1` (the POSIX and Windows variants of one logical step) are
listed once. Toolchain needs are mechanical:

```
needs_bash   = any script path ends in .sh
needs_pwsh   = any script path ends in .ps1
needs_python = any script path ends in .py
```

`reads_azd_env` and `interactive_prompts` are set by scanning the referenced scripts for
azd-env reads and interactive prompts (`Read-Host` / `input(` / `read -p`). **No domain keywords,
scenario names, auth modes, or specific filenames appear anywhere in discovery** — it is a purely
structural read of the azd contract.

## The outputs → azd-env bridge (why no script changes are needed)

A solution's post-deploy scripts read Azure values the way `azd` provides them — via
`azd env get-value` / `azd env get-values`, a generated `.env`, or plain environment variables.
Locally, `azd up` populates those from the deployment. In CI the engine reproduces the same state
from the infra deployment's **outputs**, writing them three ways so a script reading via *any*
mechanism finds them:

1. into the azd environment (`azd env set`),
2. into a repo-root `.env`,
3. into `$GITHUB_ENV` (for later steps in the same job).

```bash
# bicep: read the deployment outputs
az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs -o json > infra-outputs.json

# terraform: outputs already are {name:{value:...}}
terraform output -json > infra-outputs.json

# hydrate: keep scalars, upper-case keys (ARM lowercases them), fan out to azd/.env/$GITHUB_ENV
jq -r '
  to_entries[]
  | select((.value.value | type) as $t | $t=="string" or $t=="number" or $t=="boolean")
  | "\(.key | ascii_upcase)\t\(.value.value | tostring)"
' infra-outputs.json > kv.tsv
```

Key points:
- **Names already match.** azd/Bicep outputs are canonical `UPPER_SNAKE_CASE`, which is what the
  scripts look up — no mapping table is needed.
- **ARM lowercases output keys.** The bridge upper-cases them (`.key | ascii_upcase`) to restore
  the canonical names.
- **Scalars only.** Array/object outputs are skipped so nothing multi-line corrupts `.env` /
  `$GITHUB_ENV`; scripts consume those structural outputs, not as scalar env vars.
- **Both flavors converge.** Bicep (`az deployment group show`) and Terraform (`terraform output
  -json`) both produce the `{name:{value:…}}` shape, so hydration is identical.

### Values that are inputs, not outputs

Some values a script needs are **not** infra outputs — most importantly anything a `preprovision`
hook *generates* (a created API key, a random secret, an ID minted before deployment). The bridge
reconstructs from outputs only, so it cannot reproduce these. Discovery flags the relevant hook;
surface them to the user as **required GitHub Variables** (values only, never secrets in plaintext)
or as a manual reminder. This is a documented limitation, not something the skill can synthesize.

## Confirming the plan (agent + user, from the guides)

The skill never decides which steps are "developer-only" or "manual" from heuristics. After
discovery:

1. Read every path in `guides`.
2. Present `post_deploy_plan.scripts` (each with `runner`, `source`, and — for hook scripts — the
   hook's `run_mode`) and the `interactive_prompts` flag.
3. Agree with the user which scripts CI runs (and in what order), which are interactive/`prints_only`
   and should be confirmed or excluded, and which are **manual post-steps** surfaced as reminders.

**Prefer running steps in CI; default rather than exclude.** A step is not developer-only just
because it takes a mode/scenario/config selector or a simple confirmation prompt. Classify by
nature, not by the mere presence of an input:

| Category | CI? | What it is |
|----------|-----|------------|
| **run in CI** (default) | Yes | Build/setup/data/role steps that can run unattended. Where an input is unspecified, supply the **documented or neutral default** (as a `run_step` argument) and feed stdin for "press enter" prompts. Confirm the default with the user. |
| **developer-only** | No (excluded) | Genuinely interactive local **validation/smoke** steps with no unattended path and no deployment effect (interactive test/chat runner, IDE onboarding). |
| **manual post-step** | No (reminder) | **Privileged interactive setup** CI must not do unattended: creating app registrations/secrets, granting API permissions, admin consent, portal-only auth. Stays a reminder even if a default exists. |

Interactive prompts (`Read-Host` / `input(` / `read -p`) do **not** by themselves force exclusion:
if the step is otherwise a run-in-CI category and the prompt is a simple confirmation or has a
default, run it unattended (pass the default selector, pipe stdin). Only exclude when there is no
non-interactive path. Decide with the user; never edit the script.

## Rendering the confirmed plan into `_post-deploy.yml`

The engine is generic; the confirmed plan is injected via placeholders (no other edits):

| Placeholder             | Filled from                                                                 |
|-------------------------|-----------------------------------------------------------------------------|
| `__NEEDS_PYTHON__`      | `post_deploy_plan.needs_python` (`true`/`false`).                            |
| `__PY_VERSION__`        | repo Python version (`.python-version`/pyproject/guide, else default).       |
| `__REQUIREMENTS__`      | `post_deploy_plan.requirements` (unused when `needs_python` is false).       |
| `__POST_DEPLOY_STEPS__` | one `run_step <runner> <path> [args...]` line per confirmed script, in order, indented 10 spaces. |
| `__MANUAL_POST_STEPS__` | the agreed manual steps as markdown bullets (or a "none" note).              |
| `__TF_VERSION__`        | Terraform version (terraform flavor only).                                  |

By default the engine passes **no arguments** — each script reads its configuration from the
reconstructed azd env / `.env` / environment. `run_step` accepts optional trailing arguments, so a
step that needs a non-interactive default selector is rendered as
`run_step python path/to/step.py --<selector> <default>`; prefix `printf '\n' | ` for a step with a
simple confirmation prompt. There is no manifest file; the plan lives in the rendered workflow.

## Authentication in CI

The scripts resolve Azure via the `azure/login` OIDC session (`AzureCliCredential` /
`DefaultAzureCredential`), i.e. they run as the **service principal** — no interactive user token.
Reuse the infra skill's OIDC identity Variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`; plus `AZURE_LOCATION` and `TF_BACKEND_*` for Terraform).

Any capability that a service principal cannot perform unattended (for example an external API
that requires a tenant admin to enable service-principal access, or a portal-only auth step) is a
**manual post-step** — confirm it from the guide and emit it as a run-summary reminder, don't try
to automate it.
