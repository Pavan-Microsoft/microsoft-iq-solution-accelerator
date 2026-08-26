# Terraform state backend — one-time bootstrap (manual prerequisite)

The generated Terraform pipeline stores state in an **Azure Storage** backend, authenticated with
the same OIDC identity as the deployments (no storage keys). Terraform **cannot create its own
state backend** — that is a chicken-and-egg problem — so provisioning the backend is a **one-time
manual prerequisite** the user runs once per repository, before the pipeline is dispatched. The
CI/CD skill never creates Azure resources.

## What the backend needs

A single Storage account + blob container that holds one state file **per environment**
(`key = <env>.tfstate`). The workflow writes `backend.tf` + `backend.<env>.hcl` at runtime from
these GitHub **Environment Variables** (names only; all are non-secret):

| Variable                       | Description                                             |
|--------------------------------|---------------------------------------------------------|
| `TF_BACKEND_RESOURCE_GROUP`    | Resource group holding the state Storage account        |
| `TF_BACKEND_STORAGE_ACCOUNT`   | Storage account name (globally unique)                  |
| `TF_BACKEND_CONTAINER`         | Blob container name (e.g. `tfstate`)                    |

The state **key is derived automatically** as `<environment>.tfstate`, so stages never share
state even when they share one container.

## Bootstrap commands (run once, per repo)

Uses the caller's existing `az login`. Idempotent — safe to re-run. Grants the deployment identity
**Storage Blob Data Contributor** on the state account so `use_azuread_auth = true` works without
storage keys.

```bash
# --- values you choose -------------------------------------------------------
LOCATION="eastus2"
BACKEND_RG="rg-tfstate"
BACKEND_SA="sttfstate$RANDOM$RANDOM"   # 3-24 lowercase alphanumerics, globally unique
BACKEND_CT="tfstate"
DEPLOYER_OBJECT_ID="<object-id of the AZURE_CLIENT_ID app/SP>"  # az ad sp show --id <client-id> --query id -o tsv

# --- resource group + storage account ---------------------------------------
az group create --name "$BACKEND_RG" --location "$LOCATION" --only-show-errors --output none

az storage account create \
  --name "$BACKEND_SA" --resource-group "$BACKEND_RG" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --allow-blob-public-access false \
  --only-show-errors --output none

# --- RBAC for the deployment identity (Entra ID auth, no keys) ---------------
SA_ID="$(az storage account show --name "$BACKEND_SA" --resource-group "$BACKEND_RG" --query id -o tsv)"
az role assignment create \
  --assignee-object-id "$DEPLOYER_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID" \
  --only-show-errors --output none

# --- blob container (Entra ID auth) -----------------------------------------
az storage container create \
  --name "$BACKEND_CT" \
  --account-name "$BACKEND_SA" \
  --auth-mode login \
  --only-show-errors --output none

echo "TF_BACKEND_RESOURCE_GROUP=$BACKEND_RG"
echo "TF_BACKEND_STORAGE_ACCOUNT=$BACKEND_SA"
echo "TF_BACKEND_CONTAINER=$BACKEND_CT"
```

Set the three printed values as **Environment Variables** on every generated GitHub Environment
(both `<stage>-preview` and `<stage>`), alongside `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
`AZURE_SUBSCRIPTION_ID`.

## First-run note

On the very first dispatch against an empty backend, `terraform output` is empty until the first
`apply` succeeds. The post-deploy stage reads outputs from state, so run the infra `apply` (the
`terraform-deploy` workflow) before—or in the same run as—the post-deploy stage.
