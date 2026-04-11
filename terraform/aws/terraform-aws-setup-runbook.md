# AWS CLI Authentication Runbook (SSO via Okta)

> **Prerequisites**
> - [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed
> - Access to AWS via Okta — if you don't have an AWS tile, ask IT to add it
> - [Terraform](https://developer.hashicorp.com/terraform/install)

---

## 1. Configure SSO (one-time setup)

Open `~/.aws/config` and add the following, replacing the placeholder values:

```ini
[default]
sso_start_url = https://d-9967231e9d.awsapps.com/start
sso_region = eu-central-1
sso_account_id = YOUR_ACCOUNT_ID
sso_role_name = SystemAdministrator
region = us-west-1
output = json
```

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

## 5. Run Terraform

```bash
terraform init
terraform plan
terraform apply
```

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