# Post-deploy conventions (Azure DevOps)

How the post-deploy stage runs a solution's post-provision/post-deploy steps and tests in Azure
DevOps **without editing any Bicep, Terraform, application, or post-provision script** — only the
pipeline YAML. Nothing here is solution-specific: the skill discovers each repo's steps from its
own azd contract and test tooling and injects them into the generic stage.

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

The **deployment guide(s)** are then parsed: every **deployment / post-deployment section**
(a level-2+ heading whose text contains "deploy" — e.g. "Deployment Steps", "Deploying with AZD",
"Post Deployment Steps") is scanned for additional script references, and **relative markdown
links** from those sections into sibling docs are followed one level so a step documented in a
linked guide (a separate doc referenced from the section) is captured too. Those merge into the plan as
`source: guide`.

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

`reads_azd_env` and `interactive_prompts` are set by scanning the referenced scripts for azd-env
reads and interactive prompts (`Read-Host` / `input(` / `read -p`). **No domain keywords, scenario
names, auth modes, or specific filenames appear anywhere in discovery** — it is a purely structural
read of the azd contract.

## The resource-group → azd-env bridge (why no script changes are needed)

A solution's post-deploy scripts read Azure values the way `azd` provides them — via
`azd env get-value` / `azd env get-values`, a generated `.env`, or plain environment variables.
Locally, `azd up` populates those from the deployment. The stage reproduces the same state by
reading the deployment outputs **back from the provisioned resource group via `az`** — not by
passing outputs between stages:

```bash
# find the latest succeeded ARM deployment in the RG, then read its outputs
DEP="$(az deployment group list --resource-group "$RG" \
  --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name" \
  -o tsv)"
az deployment group show --resource-group "$RG" --name "$DEP" \
  --query properties.outputs -o json > infra-outputs.json

# hydrate: keep scalars, upper-case keys (ARM lowercases them), fan out to azd env / .env / pipeline
jq -r '
  to_entries[]
  | select((.value.value | type) as $t | $t=="string" or $t=="number" or $t=="boolean")
  | "\(.key | ascii_upcase)\t\(.value.value | tostring)"
' infra-outputs.json > kv.tsv
```

Each row is written three ways so a script reading via *any* mechanism finds it: `azd env set`,
a repo-root `.env`, and an ADO pipeline variable (`##vso[task.setvariable]`).

Key points:
- **`azd provision` creates the ARM deployment** whose outputs are read. Because it is a real ARM
  deployment in the RG, `az deployment group show` returns the same canonical outputs `azd` stored.
- **Names already match.** azd/Bicep outputs are canonical `UPPER_SNAKE_CASE`, which is what the
  scripts look up — no mapping table is needed.
- **ARM lowercases output keys.** The bridge upper-cases them (`.key | ascii_upcase`) to restore
  the canonical names.
- **Scalars only.** Array/object outputs are skipped so nothing multi-line corrupts `.env` /
  pipeline variables; scripts consume those structural outputs directly, not as scalar env vars.
- **Empty fallback.** If no succeeded deployment is found, the stage falls back to an empty output
  set and continues, so scripts that read nothing from outputs still run.

### The Terraform (raw `terraform apply`) case

A raw Terraform deploy creates the RG and resources but leaves **no ARM deployment** in the RG, so
`az deployment group show` returns nothing. The Terraform provision template therefore captures
`terraform output -json` (same `{name:{value:…}}` shape as ARM outputs) and **publishes it as an
`infra-outputs` pipeline artifact**. The post-deploy stage's hydration step downloads that artifact
(optional, `continueOnError`) and, when present and non-empty, hydrates from it instead of reading
the RG. Bicep/azd publishes no such artifact, so its path falls through to the RG read. Both flavors
converge on the identical hydration jq, so post-deploy scripts see the same env either way.

**The resource group name is captured from state, not assumed.** After apply, the Terraform
provision template reads the group that was *actually* created straight from `terraform show -json`
(`select(.type=="azurerm_resource_group") | .values.name`) and merges it into the outputs artifact
as `AZURE_RESOURCE_GROUP`. This is repo-agnostic: a solution may build its own group name (e.g.
`rg-<project>-<random_suffix>`) and ignore any injected `resource_group_name` var. Because the real
name rides in the artifact, the post-deploy hydration fans it out (so scripts target the real group)
and the deploy pipeline's Cleanup stage deletes exactly that group — falling back to the generated
name only if the capture is empty. The capture step runs `succeededOrFailed()` so a partially
created group is still torn down.

### Values that are inputs, not outputs

Some values a script needs are **not** deployment outputs — most importantly anything a
`preprovision` hook *generates* (a created API key, a random secret, an ID minted before
deployment). The bridge reconstructs from outputs only, so it cannot reproduce these. Discovery
flags the relevant hook; surface them to the user as **required variables** (values only, never
secrets in plaintext) or as a manual reminder. This is a documented limitation, not something the
skill can synthesize.

## Confirming the plan (agent + user, from the guides)

The skill never decides which steps are "developer-only" or "manual" from heuristics. After
discovery:

1. Read every path in `guides`.
2. Present `post_deploy_plan.scripts` (each with `runner`, `source`, and — for hook scripts — the
   hook's `run_mode`) and the `interactive_prompts` flag.
3. Agree with the user which scripts CI runs (and in what order) and which are **manual reminders**
   (steps the guide documents that have no script to invoke). Any step with a runnable script runs
   in CI; `prints_only`/`interactive_prompts` steps are confirmed and run with defaults, not
   excluded because of what the script does.

**Every discovered script runs in CI.** A step is not developer-only because it takes a
selector or a confirmation prompt, and it is **not** a reminder because of the kind of work it
performs. If a mandatory step has a runnable script, run it — let any failure surface in the logs
to debug. Classify by nature:

| Category | CI? | What it is |
|----------|-----|------------|
| **run in CI** (default) | Yes | Every discovered script, **whatever it does**. Where an input is unspecified, supply the **documented or neutral default** (as a `run_step` argument) and feed stdin for "press enter" prompts. Confirm the default with the user. |
| **manual reminder** | No (reminder) | **Only steps with no script** — actions the guide documents that a person performs by hand and that CI cannot script. Surfaced as a run-summary reminder. |
| **developer-only** | No (excluded) | Genuinely interactive local **validation/smoke** steps with no unattended path and no deployment effect (interactive test/chat runner, IDE onboarding). |

Interactive prompts (`Read-Host` / `input(` / `read -p`) do **not** by themselves force exclusion:
if the step is otherwise a run-in-CI category and the prompt is a simple confirmation or has a
default, run it unattended (pass the default selector, pipe stdin). Only exclude when there is no
non-interactive path. Decide with the user; never edit the script.

## Test discovery (`discover-tests.sh`)

Purely structural, no solution knowledge:

| Category | Detected from | Rendered job |
|----------|---------------|--------------|
| `unit_frontend` | a `package.json` with a real `test` script | `unit_frontend` |
| `unit_backend.pytest` | a `pytest.ini`/`pyproject`/`tox.ini` or a `tests/` dir with `test_*.py` | `unit_backend_pytest` |
| `unit_backend.dotnet` | a `*.Tests.csproj` / test project | `unit_backend_dotnet` |
| `playwright` | a Playwright config (`playwright.config.*`) or Python `playwright.sync_api` usage; `language` = node/python | `playwright` |

Only present categories are rendered. **Fix `dependsOn`:** after deleting absent unit-test jobs,
the `playwright` job must depend only on the unit jobs that remain, or on `post_deploy` if none
remain.

## Rendering the confirmed plan into the stage template

The stage is generic; the confirmed plan is injected via placeholders (no other edits):

| Placeholder             | Filled from                                                                 |
|-------------------------|-----------------------------------------------------------------------------|
| `__NEEDS_PYTHON__`      | `post_deploy_plan.needs_python` — keep or delete the marked Python block.    |
| `__PY_VERSION__`        | repo Python version (`.python-version`/pyproject/guide, else default).       |
| `__REQUIREMENTS__`      | `post_deploy_plan.requirements` (unused when `needs_python` is false).       |
| `__POST_DEPLOY_STEPS__` | one `run_step <runner> <path> [args...]` line per confirmed script, in order. |
| `__MANUAL_POST_STEPS__` | the agreed manual steps as markdown bullets (or a "none" note).              |
| `__FE_DIR__`/`__FE_INSTALL__`/`__FE_TEST__` | frontend unit-test directory + install/test commands.   |
| `__PYTEST_DIR__`/`__PYTEST_REQS__` | pytest working dir + requirements.                               |
| `__DOTNET_DIR__`        | dotnet test project directory.                                              |
| `__PW_DIR__`/`__PW_REQS__` | Playwright working dir + requirements (keep the node **or** python block per `language`). |

By default the engine passes **no arguments** — each script reads its configuration from the
reconstructed azd env / `.env` / pipeline variables. `run_step` accepts optional trailing
arguments, so a step that needs a non-interactive default selector is rendered as
`run_step python path/to/step.py --<selector> <default>`; prefix `printf '\n' | ` for a step with a
simple confirmation prompt. There is no manifest file; the plan lives in the rendered stage.

## Azure sign-in in CI

The scripts resolve Azure via the **Azure Resource Manager service connection**
(`AzureCLI@2` with `addSpnToEnvironment: true` → `azd auth login` as the service principal) — no
interactive user token. The stage reuses the infra deploy pipeline's service connection; no extra
identity is created.

Every discovered script **runs in CI** under that service connection, whatever it does. If the
service principal lacks a permission a script needs, the step **fails and the error surfaces in the
logs** to debug — it is not pre-emptively downgraded to a reminder. Only a step the guide documents
that has **no script** to invoke (an action a person performs by hand that CI cannot script) is
emitted as a run-summary reminder; confirm those from the guide and don't try to automate them.
