<#
.SYNOPSIS
    Creates a single Azure DevOps YAML pipeline for one specific GitHub repository.

.DESCRIPTION
    Creates one pipeline pointing at a YAML file in the given GitHub repo, authenticated through an
    existing GitHub App service connection (the Azure Pipelines GitHub App installed on the org).

    The repo is named explicitly, so NO GitHub repo-listing API is called. This deliberately avoids
    the GET /user/repos "Resource not accessible by integration" (403) error that a GitHub App token
    hits in the StartRight repo picker. Idempotent: if the pipeline already exists it is skipped.

.EXAMPLE
    ./New-GitHubPipeline.ps1 `
        -OrgUrl "https://dev.azure.com/CSACTOSOL" `
        -Project "CSA Solutioning" `
        -Repo "Pavan-Microsoft/Sample-Repo" `
        -ServiceConnection "github.com_Pavan-Microsoft"

.NOTES
    Requires: Azure CLI + azure-devops extension (az extension add --name azure-devops).
    Auth to Azure DevOps: run `az login` / `az devops login`, or set AZURE_DEVOPS_EXT_PAT.
    Docs:
      az pipelines create - https://learn.microsoft.com/en-us/cli/azure/pipelines#az-pipelines-create
      GitHub App auth     - https://learn.microsoft.com/en-us/azure/devops/pipelines/repos/github?view=azure-devops&tabs=yaml#github-app-authentication
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [string] $OrgUrl,            # https://dev.azure.com/CSACTOSOL
    [Parameter(Mandatory = $true)] [string] $Project,          # "CSA Solutioning"
    [Parameter(Mandatory = $true)] [string] $Repo,             # owner/repo, e.g. Pavan-Microsoft/Sample-Repo
    [Parameter(Mandatory = $true)] [string] $ServiceConnection, # GitHub App service connection name OR id (GUID)

    [string] $PipelineName = "",          # blank = auto "<owner>-<repo>-CI" (e.g. Pavan-Microsoft-Sample-Repo-CI)
    [string] $YmlPath      = "azure-pipelines.yml",
    [string] $Branch       = "main",
    [string] $Folder       = "",          # optional ADO folder path, e.g. "\GitHub"; blank = root
    [switch] $SkipFirstRun = $true
)

$ErrorActionPreference = "Stop"
function Write-Info { param([string]$m) Write-Host "[create] $m" }

if ($Repo -notmatch '^[^/]+/[^/]+$') {
    throw "Repo must be in 'owner/repo' format, e.g. 'Pavan-Microsoft/Sample-Repo'. Got: '$Repo'."
}

# Default the pipeline name to "<owner>-<repo>-CI" so multiple repos are easy to tell apart.
if ([string]::IsNullOrWhiteSpace($PipelineName)) {
    $PipelineName = ($Repo -replace '/', '-') + "-CI"
}

# --- Resolve the service connection name to an id (GUID) if a name was supplied ---
$connectionId = $ServiceConnection
if ($ServiceConnection -notmatch '^[0-9a-fA-F-]{36}$') {
    Write-Info "Resolving service connection '$ServiceConnection' to an id..."
    $connectionId = az devops service-endpoint list --org $OrgUrl --project $Project `
        --query "[?name=='$ServiceConnection'].id | [0]" -o tsv
    if ([string]::IsNullOrWhiteSpace($connectionId)) {
        throw "Could not find a service connection named '$ServiceConnection' in '$Project'."
    }
}
Write-Info "Using service connection id: $connectionId"

# --- Idempotency: skip if a pipeline with this folder + name already exists ---
$folderKey = "$(([string]$Folder).TrimEnd('\'))\$PipelineName"
$existing = az pipelines list --org $OrgUrl --project $Project -o json | ConvertFrom-Json
foreach ($p in $existing) {
    if ("$(($p.path).TrimEnd('\'))\$($p.name)" -eq $folderKey) {
        Write-Info "SKIP: pipeline '$folderKey' already exists (id $($p.id))."
        return
    }
}

# --- Create the pipeline ---
if ($PSCmdlet.ShouldProcess($Repo, "Create pipeline '$PipelineName'")) {
    Write-Info "Creating pipeline '$PipelineName' for '$Repo' (branch '$Branch', yml '$YmlPath')..."
    $createArgs = @(
        "pipelines", "create",
        "--org", $OrgUrl,
        "--project", $Project,
        "--name", $PipelineName,
        "--repository", $Repo,
        "--repository-type", "github",
        "--branch", $Branch,
        "--yml-path", $YmlPath,
        "--service-connection", $connectionId
    )
    if ($Folder)       { $createArgs += @("--folder-path", $Folder) }
    if ($SkipFirstRun) { $createArgs += @("--skip-first-run", "true") }

    az @createArgs
    if ($LASTEXITCODE -ne 0) { throw "az pipelines create failed with exit code $LASTEXITCODE." }
    Write-Info "Done."
}
