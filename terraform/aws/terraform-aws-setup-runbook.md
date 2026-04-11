# AWS CLI Authentication Runbook (SSO via Okta)

> **Prerequisites**
> - [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed
> - Access to AWS via Okta — if you don't have an AWS tile, ask IT to add it
> - [Terraform](https://developer.hashicorp.com/terraform/install) CLI installed

---

## 1. Configure SSO (one-time setup)

Open `~/.aws/config` and add the following, replacing the placeholder values:

```ini
[default]
sso_start_url = https://d-9967231e9d.awsapps.com/start
sso_region = eu-central-1
sso_account_id = YOUR_ACCOUNT_ID
sso_role_name = SystemAdministrator
region = YOUR_REGION
output = json
```
The `sso_region` is ALWAYS `eu-central-1`
You can choose your own [default region](https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html) to create resources in.

> **Finding your Account ID:**
> 1. Log in to AWS via your Okta dashboard
> 2. Once in the AWS console, click your **username in the top-right corner**
> 3. Your 12-digit Account ID is shown in the dropdown (e.g. `655394773887`)
> 4. Alternatively, it is visible on the [AWS access portal](https://d-9967231e9d.awsapps.com/start) next to your assigned account name

---

## 2. Log in

```bash
aws sso login
```

This opens a browser window — authenticate with your Camunda Okta credentials.

---

## 3. Verify credentials

```bash
aws sts get-caller-identity
```

You should see your account ID, user ID, and ARN. If this fails, re-run `aws sso login`.

---

## 4. Export credentials for Terraform

Terraform doesn't natively support the SSO session config format, so you need to export your credentials as environment variables before running any Terraform commands:

```bash
aws configure export-credentials --format env
```

Copy and paste the three exported lines into your terminal. They look like:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
```

Also set your [region](https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html) (us-west-1 is an example, you can change it to a region near you):

```bash
export AWS_REGION=us-west-1
```

---

## 5. Navigate to the correct infrastructure directory

Clone the [camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) repository if you have not already:

```bash
git clone https://github.com/camunda/camunda-deployment-references.git
cd camunda-deployment-references
```

Browse the available AWS infrastructure options here: [aws/ directory](https://github.com/camunda/camunda-deployment-references/tree/main/aws)

Once you have chosen your infrastructure type, navigate into its `terraform` subdirectory — this is where all Terraform commands must be run from. For example, for a standard single-region EKS cluster:

```bash
cd aws/kubernetes/eks-single-region/terraform/cluster
```

> ⚠️ All `terraform` commands (`init`, `plan`, `apply`, `destroy`) must be run from within the `terraform` subdirectory of your chosen infrastructure type, not from the repo root.

To confirm you are in the right place, check for a `config.tf` file:

```bash
ls config.tf
```

If the file is not there, you are in the wrong directory.

---

## 6. Create an S3 Bucket for Terraform State

Terraform tracks all the infrastructure it creates in a **state file**. This file is stored in an S3 bucket so that:
- Multiple team members can work on the same infrastructure without conflicts
- The state is preserved between sessions and machines
- Terraform can detect and manage changes to existing infrastructure

> ⚠️ **The S3 bucket must exist before running `terraform init`** — if it doesn't, the backend configuration will fail.

Create the bucket (choose a unique name):

```bash
aws s3api create-bucket \
  --bucket your-terraform-state-bucket \
  --region us-west-1 \
  --create-bucket-configuration LocationConstraint=us-west-1
```

Then enable versioning so you can recover previous state files if something goes wrong:

```bash
aws s3api put-bucket-versioning \
  --bucket your-terraform-state-bucket \
  --versioning-configuration Status=Enabled
```

Then update the `config.tf` file in your chosen infrastructure directory to reference your bucket:

```hcl
terraform {
  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "terraform.tfstate"
    region = "us-west-1"
  }
}
```

> ⚠️ **Never delete the S3 bucket or state file** while infrastructure is running. Terraform will lose track of what it created, making it very difficult to manage or destroy resources.

---

## 7. Run Terraform

```bash
terraform init
```
Downloads and installs the required providers and modules. Run this once when you first set up, or when dependencies change.

```bash
terraform plan
```
Previews what Terraform *will* do before making any changes — what will be created, modified, or destroyed. Nothing in AWS is touched.

```bash
terraform apply
```
Actually creates the infrastructure in AWS. Shows the plan one more time and asks you to type `yes` to confirm before proceeding.

```bash
terraform destroy
```
Tears down **all infrastructure** managed by Terraform in the current directory. Shows a list of everything that will be deleted and asks you to type `yes` to confirm.

> ⚠️ This is irreversible. All AWS resources (EKS cluster, databases, networking, etc.) will be permanently deleted. Make sure you have backups of any important data before running this.

---

## Refreshing an expired session

SSO sessions expire after a few hours. When you see a `403` or `InvalidClientTokenId` error, refresh by repeating steps 2 and 4:

```bash
aws sso login
aws configure export-credentials --format env
# paste the exported lines
export AWS_REGION=us-west-1
```

---

## Troubleshooting

| Error | Fix |
|---|---|
| `profile could not be found` | Check `~/.aws/config` exists and has a `[default]` block. Run `unset AWS_PROFILE`. |
| `NoCredentialProviders` | You haven't logged in yet. Run `aws sso login`. |
| `InvalidClientTokenId 403` | Session expired. Re-run `aws sso login` and re-export credentials. |
| `Missing region value` | Run `export AWS_REGION=us-west-1`. |
| `sso_region / sso_start_url missing` | Add both fields directly to the `[default]` profile in `~/.aws/config`. |