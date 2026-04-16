# Camunda AWS & Azure Deployment Runbooks

This repository contains runbooks for TAMs deploying Camunda 8 Self-Managed infrastructure using Terraform on AWS and Azure via the [camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) repository.

> [!CAUTION]
> Cloud resources are costly. Only create infrastructure when you need it and **delete it as soon as you are done.** Use `terraform destroy` to tear down all resources when finished.

## Cloud Provider Runbooks

- [AWS CLI Authentication & Setup](./aws/README.md)
- [Azure CLI Authentication & Setup](./!!!-azure/!!!-README.md)

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

## Overriding Variables

The safest approach is to make all your changes directly in `cluster.tf`. It is the main configuration file for your deployment and is designed to be edited.

For advanced users, `terraform.tfvars` can be used to override root-level variables declared in `variables.tf` without touching `cluster.tf`. However, it will **not** work for module inputs — those must always be set in the module block in `cluster.tf`.

> [!NOTE]
> If you are new to Terraform, stick to editing `cluster.tf` directly. Use `git diff` to see exactly what you have changed from the original.

### Tips for finding where to put variables in `cluster.tf`

1. **Read the comments** — `cluster.tf` usually has inline comments like `# Change this to your desired region` pointing out exactly what to edit
2. **Look at what's already there** — if you see `np_desired_node_count = 4` in the module block, add similar variables alongside it
3. **Check the module's `variables.tf`** — run `cat <path-to-module>/variables.tf` to see every variable the module accepts, with descriptions and default values
4. **Use the module's README** — it usually has a full inputs table listing every available variable
5. **All module inputs go inside the module block** — if you see `module "eks_cluster" { ... }`, everything between the braces is where you add inputs
6. **`terraform plan` is your friend** — if you add a variable that doesn't exist, Terraform will tell you immediately without creating anything in your cloud account

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
