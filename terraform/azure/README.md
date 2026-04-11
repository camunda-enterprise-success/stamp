# Azure CLI Authentication Runbook (SSO via Okta)

> **Prerequisites**
> - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
> - Access to Azure via Okta — if you don't have an Azure AD Dev Tenant tile, ask IT to add it
> - [Terraform](https://developer.hashicorp.com/terraform/install) CLI installed

---

## 1. Log in

Run the following, using the Camunda tenant ID:

```bash
az login --tenant cbd46654-4f74-4332-a490-69f0f071ba9f
```

This opens a browser window — authenticate with your Camunda Okta credentials. Once logged in, you will see a list of available subscriptions in your terminal. Press **Enter** to accept the default, or type the number of the subscription you want to use.

---

## 2. Verify credentials

```bash
az account show
```

You should see your subscription name, subscription ID, and tenant ID. If this fails, re-run `az login`.

---

## 3. Set your region

Azure resources are region-bound. Choose a region close to you — see the full list at [Azure regions](https://azure.microsoft.com/en-us/explore/global-infrastructure/geographies/).

```bash
export AZURE_REGION=eastus  # replace with your preferred region
```

Common options:

| Region | Location |
|---|---|
| `eastus` | Virginia, USA |
| `westus` | California, USA |
| `westeurope` | Netherlands |
| `northeurope` | Ireland |
| `southeastasia` | Singapore |
| `australiaeast` | New South Wales, Australia |

---

## 4. Navigate to the correct infrastructure directory

Clone the [camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) repository if you haven't already:

```bash
git clone https://github.com/camunda/camunda-deployment-references.git
cd camunda-deployment-references
```

Create a fresh branch before making any changes — this keeps the original code intact and makes it easy to `git diff` against `main` to see exactly what you changed:

```bash
git checkout -b my-azure-deployment
```

Browse the available Azure infrastructure options here: [azure/ directory](https://github.com/camunda/camunda-deployment-references/tree/main/azure)

Once you have chosen your infrastructure type, navigate into its `terraform` subdirectory — this is where all Terraform commands must be run from. For example, for a standard single-region AKS cluster:

```bash
cd azure/kubernetes/aks-single-region/terraform/cluster
```

To confirm you are in the right place, check for a `config.tf` file:

```bash
ls config.tf
```

If the file is not there, you are in the wrong directory.

> ⚠️ All `terraform` commands (`init`, `plan`, `apply`, `destroy`) must be run from within the `terraform` subdirectory of your chosen infrastructure type, not from the repo root.

---

## 5. Create a Storage Account for Terraform State

Terraform tracks all the infrastructure it creates in a **state file**. For Azure, this is stored in an Azure Storage Account (the Azure equivalent of an S3 bucket) so that:
- Multiple team members can work on the same infrastructure without conflicts
- The state is preserved between sessions and machines
- Terraform can detect and manage changes to existing infrastructure

> [!WARNING]
> The storage account must exist before running `terraform init` — if it doesn't, the backend configuration will fail.

Create a resource group and storage account:

```bash
# Create a resource group for Terraform state
az group create --name terraform-state-rg --location $AZURE_REGION

# Create a storage account (name must be globally unique, lowercase, 3-24 chars)
az storage account create \
  --name yourterraformstate \
  --resource-group terraform-state-rg \
  --location $AZURE_REGION \
  --sku Standard_LRS

# Create a container inside the storage account
az storage container create \
  --name tfstate \
  --account-name yourterraformstate
```

Then update the `config.tf` file in your chosen infrastructure directory to reference your storage account:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "terraform-state-rg"
    storage_account_name = "yourterraformstate"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }
}
```

> [!WARNING]
> Never delete the storage account or state file while infrastructure is running. Terraform will lose track of what it created, making it very difficult to manage or destroy resources.

---

## 6. Run Terraform

```bash
terraform init
```
Downloads and installs the required providers and modules. Run this once when you first set up, or when dependencies change.

```bash
terraform plan
```
Previews what Terraform *will* do before making any changes — what will be created, modified, or destroyed. Nothing in Azure is touched.

```bash
terraform apply
```
Actually creates the infrastructure in Azure. Shows the plan one more time and asks you to type `yes` to confirm before proceeding.

```bash
terraform destroy
```
Tears down **all infrastructure** managed by Terraform in the current directory. Shows a list of everything that will be deleted and asks you to type `yes` to confirm.

> [!WARNING]
> This is irreversible. All Azure resources (AKS cluster, databases, networking, etc.) will be permanently deleted. Make sure you have backups of any important data before running this.

---

## Refreshing an expired session

Azure CLI sessions expire periodically. When you see an authentication error, simply re-login:

```bash
az login --tenant cbd46654-4f74-4332-a490-69f0f071ba9f
```

Unlike AWS SSO, you do not need to re-export credentials — the Azure CLI handles this automatically and Terraform picks it up directly.

---

## Troubleshooting

| Error | Fix |
|---|---|
| `Please run 'az login'` | Run `az login --tenant cbd46654-4f74-4332-a490-69f0f071ba9f` |
| `Subscription not found` | Run `az account set --subscription 497cbebf-c7f6-49d2-a36b-5a59a8a1ce21` |
| `No such file: config.tf` | You are in the wrong directory — navigate to the `terraform` subdirectory of your chosen infrastructure |
| `Backend config missing` | Check your `config.tf` has the correct `storage_account_name` and `container_name` |
| `AuthorizationFailed` | Your account lacks the required permissions — ask your Azure admin to assign you the `Contributor` role on the subscription |