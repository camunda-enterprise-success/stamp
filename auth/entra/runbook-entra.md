# Entra OIDC Configuration Runbook

## Overview

 This runbook covers how to configure management and orchestration cluster to use Entra as an OIDC provider. 

---

## Prerequisites

- Access to the Azure AD Dev Tenant via Okta. Reach out to IT if you do not have access.
- `kubectl` access to your target cluster.

---

## Step 1: Retrieve the Client Secret

A client (app registration) has already been created in Entra for STAMP. You need to generate a client secret from it.

1. Sign in to Okta and navigate to the **Azure AD Dev Tenant**.
2. Navigate to **Applications → App registrations**.
3. Find and select the `tam-stamp-client` app registration (Client ID: `a6c00e10-77d0-48cc-a817-2bac3d1e782c`).


4. In the left-hand menu, select **Certificates & secrets**.
5. Under the **Client secrets** tab, click **+ New client secret**.
6. Enter a description (e.g. `your-name-secret`) and choose an expiry period, then click **Add**.
7. **Copy the secret value immediately** — it will not be shown again after you leave this page.

---

## Step 2: Find Your Entra User OID

The initial admin user is identified by their Entra Object ID (OID). To find your OID:

1. In the Azure AD Dev Tenant, navigate to **Users → All users**.
2. Search for and select your user account.
3. On your profile page, copy the **Object ID** field.

Alternatively, if you have the Azure CLI installed:

```bash
az ad signed-in-user show --query id -o tsv
```

---

## Step 3: Create the Kubernetes Secret

The client secret is mounted into the cluster via a Kubernetes secret. Create it using the value retrieved in Step 1:

```bash
kubectl create secret generic entra-client-credentials \
  --from-literal=client-secret='<your-client-secret>'
```

> This secret is referenced as `entra-client-credentials` with key `client-secret` throughout `entra-oidc-values.yaml`.

---

## Step 4: Set the Admin OID in `entra-oidc-values.yaml`

Open `entra-oidc-values.yaml` and replace both `<your-entra-user-oid>` placeholders with the OID retrieved in Step 2.

There are two locations to update:

**1. Under `global.identity.auth.identity`:**
```yaml
initialClaimValue: <your-entra-user-oid>
```

**2. Under `orchestration.security.initialization.defaultRoles.admin.users`:**
```yaml
- <your-entra-user-oid>
```

Also update the `redirectUrl` fields across all components to reflect your actual domain, replacing `camunda.example.com` if that is not the domain you are using.

---

## Step 5: Deploy

Apply the values file to your Helm release:

```bash
helm upgrade --install camunda camunda/camunda-platform \
  -f ../../base-values/orchestration-and-management-cluster-values.yaml \
  -f ../../base-values/values-local-tls.yaml \
  -f entra-oidc-values.yaml 
```

---

## Notes

- **Groups/Roles:** Entra outputs group memberships under the `roles` claim. This is non-default behaviour in Entra — you must enable **"Add groups claim"** in the app registration's **Token configuration** section and ensure app roles are assigned to users.

## References

- [Helm chart OIDC provider setup – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/installation-methods/helm/configure/connect-to-an-oidc-provider/)
- [Connect Management Identity to an OIDC provider – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/components/management-identity/configuration/connect-to-an-oidc-provider/)
- [Configure OAuth with Microsoft Entra – Camunda 8 Docs](https://docs.camunda.io/docs/8.7/guides/oauth-entra/)
- [Identity configuration variables – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/identity/miscellaneous/configuration-variables/)