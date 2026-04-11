# Camunda AWS & Azure Deployment Runbooks

This repository contains runbooks for deploying Camunda 8 Self-Managed infrastructure using Terraform on AWS and Azure.

> [!CAUTION]
> Cloud resources are costly. Only create infrastructure when you need it and **delete it as soon as you are done.** Use `terraform destroy` to tear down all resources when finished.

## Cloud Provider Runbooks

- [AWS CLI Authentication & Setup](./aws-sso-runbook.md)
- [Azure CLI Authentication & Setup](./azure-cli-runbook.md)

---

## Navigating the Infrastructure Repository

All infrastructure code lives in the [camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) repository.

Clone it if you haven't already:

```bash
git clone https://github.com/camunda/camunda-deployment-references.git
cd camunda-deployment-references
```

Browse the available options for your cloud provider:
- [AWS infrastructure options](https://github.com/camunda/camunda-deployment-references/tree/main/aws)
- [Azure infrastructure options](https://github.com/camunda/camunda-deployment-references/tree/main/azure)

Once you have chosen your infrastructure type, navigate into its `terraform` subdirectory — this is where all Terraform commands must be run from. For example:

```bash
# AWS
cd aws/kubernetes/eks-single-region/terraform/cluster

# Azure
cd azure/kubernetes/aks-single-region/terraform/cluster
```

To confirm you are in the right place, check for a `config.tf` file:

```bash
ls config.tf
```

If the file is not there, you are in the wrong directory.

> [!WARNING]
> All `terraform` commands must be run from within the `terraform` subdirectory of your chosen infrastructure type, not from the repo root.

---

## Terraform State

Terraform tracks all the infrastructure it creates in a **state file**. This file is stored remotely (S3 for AWS, Azure Storage Account for Azure) so that:
- Multiple team members can work on the same infrastructure without conflicts
- The state is preserved between sessions and machines
- Terraform can detect and manage changes to existing infrastructure

> [!WARNING]
> The state storage must exist before running `terraform init` — if it doesn't, the backend configuration will fail.

> [!WARNING]
> Never delete the state storage while infrastructure is running. Terraform will lose track of what it created, making it very difficult to manage or destroy resources.

See your cloud-specific runbook for instructions on creating state storage.

---

## Overriding Variables with `terraform.tfvars`

Rather than editing the module files directly, you can override any Terraform variable by creating a `terraform.tfvars` file in your infrastructure directory. This keeps your customisations separate from the original code and makes it easy to see what you changed with `git diff`.

```bash
touch terraform.tfvars
```

Add any variables you want to override, for example:

```hcl
availability_zones    = ["us-west-1a", "us-west-1c"]
np_desired_node_count = 2
single_nat_gateway    = true
```

Terraform automatically picks up `terraform.tfvars` when you run `plan` or `apply` — no extra flags needed.

> [!NOTE]
> Check the `variables.tf` file in your chosen infrastructure directory for a full list of variables you can override.

---

## Running Terraform

These commands are the same regardless of cloud provider.

```bash
terraform init
```
Downloads and installs the required providers and modules. Run this once when you first set up, or when dependencies change.

```bash
terraform plan
```
Previews what Terraform *will* do before making any changes — what will be created, modified, or destroyed. Nothing in your cloud account is touched.

```bash
terraform apply
```
Actually creates the infrastructure. Shows the plan one more time and asks you to type `yes` to confirm before proceeding.

```bash
terraform destroy
```
Tears down **all infrastructure** managed by Terraform in the current directory. Shows a list of everything that will be deleted and asks you to type `yes` to confirm.

> [!WARNING]
> This is irreversible. All cloud resources will be permanently deleted. Make sure you have backups of any important data before running this.