**CAMUNDA 8.9  ·  SELF-MANAGED**

**Permissions, Roles& Tenants with OIDC**

A group-based access guide for administrators using an external identity provider

# **The one thing to know**

When Camunda 8.9 is connected to an external identity provider (Entra ID, Okta, Keycloak, etc.) via OIDC, you do not create users or manage group membership inside Camunda.

Instead, your IdP owns identity. You grant access by creating **mapping rules** that match a claim in the user’s login token and link it to a Camunda **group, role, or tenant.**

| IdP group claim e.g. "groups": \["finance"\] in the JWT token | → | Mapping rule Matches claim name \+ value (you create this) | → | Role / Tenant Rule assigned to a role, group, or tenant |
| :---: | :---: | :---: | :---: | :---: |

|  | ✓  Best practice Map to IdP groups, not individuals. Create one mapping rule per IdP group (e.g. “finance”), then assign that rule to the Camunda roles and tenants the group should have. Adding or removing a person is then done entirely in your IdP — nothing changes in Camunda. |
| :---- | :---- |

# **Two systems, same pattern**

Camunda has two identity systems. Both use mapping rules with OIDC, but they cover different components.

|  | Orchestration Cluster (Admin) | Management Identity |
| :---- | :---- | :---- |
| **Covers** | Zeebe · Operate · Tasklist · REST API | Web Modeler · Console · Optimize |
| **You set** | Groups, roles, authorizations, tenantsfor process execution | Roles and tenants for modeling& reporting tools |
| **Open via** | Cluster URL → Admin tab | Management Identity URL |

|  | ℹ  Note Mapping rules are available only with OIDC authentication. They do not apply to basic authentication. In the Orchestration Cluster, a mapping rule can target a group, role, authorization, or tenant. In Management Identity, a mapping rule can target a role or tenant. |
| :---- | :---- |

# **Before you start**

Confirm your IdP includes a group (or role) claim in the access token, and that Camunda knows where to find it. You need to know two things about your token:

| You need | Example |
| :---- | :---- |
| **The claim name holding group info** | groups,  roles,  or a nested path like user.orggroups |
| **The claim values to match** | finance,  process-admins,  ops-team |

A typical access token payload looks like this:

| {   "sub": "a1b2c3d4",   "name": "Jordan Lee",   "groups": \["finance", "process-admins"\],   "iat": 1516239022 } |
| :---- |

Here the claim name is **groups** and the values you can match are **finance** and **process-admins**.

# **Common tasks**

| 👥  Give a team access to Operate or Tasklist Map an IdP group to a Camunda role |
| :---- |

### **Step 1 — Create the mapping rule**

| 1 | Open Admin | Log in to your cluster → Admin tab → Mapping rules |
| :---: | :---- | :---- |

| 2 | Create mapping rule | Click Create. Give it an ID and name, then set the claim to match: |
| :---: | :---- | :---- |

| Field | Value (example) |
| :---- | :---- |
| **Claim name** | groups |
| **Claim value** | process-operators |

### **Step 2 — Assign the rule to a role**

| 1 | Open the role | Admin → Roles → click the role (e.g. operate) |
| :---: | :---- | :---- |

| 2 | Assign mapping rule | Mapping rules tab → Assign mapping rule → select the rule you created. |
| :---: | :---- | :---- |

| 3 | Done | Anyone whose token contains groups: process-operators now gets the operate role on their next login. |
| :---: | :---- | :---- |

| Built-in role | Grants access to |
| :---- | :---- |
| **admin** | Everything. Map to a small, tightly controlled IdP group only. |
| **operate** | View and manage process & decision instances in Operate. |
| **tasklist** | View and complete user tasks in Tasklist. |
| **task-worker** | For job workers and connectors. Scoped to tasks the worker is responsible for. |
| **optimize** | Read Operate data needed for Optimize dashboards. |
| **connector** | Permissions required by Connector job workers. |

|  | ℹ  Note Need narrower access than a built-in role? Create a custom role (Admin → Roles → Create role), add authorizations to it (Scenario 3), then assign your mapping rule to that role. |
| :---- | :---- |

| 🏢  Isolate process data by team Deploy processes into a tenant, then map the right groups to it |
| :---- |

Tenant isolation has two halves that must line up: a process gets tagged with a tenant when it’s deployed, and a user gets access to that tenant through a mapping rule. A user only sees a process if both point to the same tenant.

| 📦  At deploy time The process is tagged with a tenant ID (e.g. team-finance) when it’s deployed. | mustmatch | 🔑  At access time The user’s mapping rule must link them to the same tenant ID. |
| :---: | :---: | :---: |

|  | ℹ  Note Set up tenants and assignments first, then switch enforcement on. Until checks are enabled, everything stays in the \<default\> tenant and isolation is not applied. |
| :---- | :---- |

### **Step 1 — Create your tenants**

| 1 | Admin → Tenants | Click Create tenant → enter an ID (e.g. team-finance) and name. |
| :---: | :---- | :---- |

| 2 | Repeat | One tenant per team or business unit. |
| :---: | :---- | :---- |

### **Step 2 — Deploy each process into its tenant**

In Camunda 8, the tenant a process belongs to is set at deploy time. Unlike Camunda 7, the tenant ID must be provided explicitly — there’s no automatic inference.

| Deploying via | How the tenant is set |
| :---- | :---- |
| **Web Modeler** | Select the target tenant in the deployment dialog before deploying. |
| **Desktop Modeler** | Choose the tenant in the deploy dialog (the client must be allowed to access it). |
| **API / job worker** | Set the tenantId on the deploy request. The client’s token must grant access to that tenant. |
| **No tenant given** | The process is deployed to the \<default\> tenant. |

|  | ℹ  Note A user or client can only deploy into a tenant they’re assigned to. Deploying into a tenant you don’t have access to is rejected. The same applies to starting instances — the tenant must be specified and allowed. |
| :---- | :---- |

### **Step 3 — Map each group to its tenant**

| 1 | Open the tenant | Admin → Tenants → click the tenant to open it. |
| :---: | :---- | :---- |

| 2 | Assign mapping rule | Mapping rules tab → Assign mapping rule. Pick the rule matching that team’s IdP group (create one if needed). |
| :---: | :---- | :---- |

| 3 | Repeat per tenant | Each tenant gets the mapping rule for the group that should access it. |
| :---: | :---- | :---- |

### **Step 4 — Enable enforcement**

| camunda:   security:     multiTenancy:       checksEnabled: true |
| :---- |

Once enabled, isolation is automatic: a process tagged with **team-finance** is visible and workable only to users whose token maps them to **team-finance**. Everyone else — in Operate, Tasklist, and the API — simply doesn’t see it.

|  | ⚠  Watch out Finish all tenant mappings before enabling checks. Any user whose token doesn’t match a tenant mapping will see no data once checks are on. |
| :---- | :---- |

| 🔒  Restrict access to specific processes Attach resource permissions to a role, then map a group to it |
| :---- |

Authorizations grant permissions on a specific resource. Put them on a role, then map your IdP group to that role — never to individuals.

| 1 | Create a role | Admin → Roles → Create role (e.g. invoice-starter). |
| :---: | :---- | :---- |

| 2 | Add an authorization | Admin → Authorizations → select Process Definition → Create authorization: |
| :---: | :---- | :---- |

| Field | Value |
| :---- | :---- |
| **Owner type** | ROLE |
| **Owner ID** | invoice-starter |
| **Resource ID** | The process definition ID, or \* for all |
| **Permissions** | READ, START\_PROCESS\_INSTANCE (add UPDATE / DELETE as needed) |

| 3 | Map a group to the role | Admin → Roles → open invoice-starter → Mapping rules tab → Assign mapping rule. |
| :---: | :---- | :---- |

| 4 | Done | Everyone in that IdP group can now act on that process — and only that process. |
| :---: | :---- | :---- |

|  | ⚠  Watch out Authorizations can’t be edited after saving — delete and recreate to change one. Authorizations apply only when authorizations.enabled: true in your cluster config. |
| :---- | :---- |

| 🎨  Give a team Web Modeler or Optimize access Map a group to a role in Management Identity |
| :---- |

Modeling and reporting tools are governed by Management Identity. With OIDC, the same mapping-rule pattern applies — you assign rules to roles, not users.

| 1 | Open Management Identity | Navigate to your Management Identity URL → log in as admin → Mapping rules. |
| :---: | :---- | :---- |

| 2 | Create a mapping rule | Set the claim name and value matching the IdP group (e.g. groups \= process-designers). |
| :---: | :---- | :---- |

| 3 | Assign to a role | Roles tab → open the role → assign your mapping rule. |
| :---: | :---- | :---- |

| Role | Access granted |
| :---- | :---- |
| **Developer** | Full read/write on Web Modeler — for people building processes. |
| **Analyst** | Read-only on Web Modeler — for reviewers. |
| **Optimize Viewer** | Access to Optimize dashboards and reports. |
| **Admin** | Full access to Web Modeler, Console, and Optimize. Map sparingly. |

|  | ℹ  Note Management Identity tenants apply to Optimize only, and take effect only when multi-tenancy checks are enabled on the Orchestration Cluster. Map groups to MI tenants the same way as roles. |
| :---- | :---- |

# **Quick reference**

## **The mapping-rule workflow**

| Step | Orchestration Cluster (Admin) | Management Identity |
| :---- | :---- | :---- |
| **1** | Mapping rules → Create rule | Mapping rules → Create rule |
| **2** | Set claim name \+ value to match the IdP group | Set claim name \+ value to match the IdP group |
| **3** | Assign rule to a group, role, or tenant | Assign rule to a role or tenant |

## **Troubleshooting**

| Problem | Fix |
| :---- | :---- |
| **User logs in but has no access** | No mapping rule matches their token. Check the claim name and value match exactly (case-sensitive). |
| **Whole team lost access** | An IdP group name changed. Update the claim value on the mapping rule to match. |
| **User can’t see one process (tenants on)** | The process was deployed to a different tenant than the user is mapped to. Both must point to the same tenant. |
| **Deployment rejected** | The deploying user or client isn’t assigned to the target tenant. Map them to it, or deploy to a tenant they can access. |
| **User sees no data at all (tenants on)** | Their token doesn’t match any tenant mapping rule. Add or fix the rule on the tenant. |
| **Authorization not taking effect** | Confirm authorizations.enabled: true and API protection is on. |
| **Mapping rule ignored entirely** | Mapping rules need OIDC. They’re inactive under basic authentication. |
| **Not sure what’s in the token** | Capture and decode the user’s token — see “Inspecting a login token” below. |
| **Need to change an authorization** | Delete the existing one, then recreate — they’re immutable. |
| **Need to change a tenant** | Delete and recreate — tenants are immutable after creation. |

## **Inspecting a login token**

Mapping rules match the claims in a user’s access token, so when access doesn’t behave as expected, the first thing to check is what’s actually in that token. There are two ways to get one, depending on whether you’re troubleshooting a person or a machine client.

### **Option A — A real user’s token (from the browser)**

Use this when a person logs in but doesn’t get the access you expect. It shows the exact token Camunda received for them.

| 1 | Open dev tools | In the user’s browser, open Developer Tools (F12) → Network tab, then keep it open. |
| :---: | :---- | :---- |

| 2 | Log in | Have the user log in to Operate, Tasklist, or the Admin UI as normal. |
| :---: | :---- | :---- |

| 3 | Find the token | In the Network tab, look for the token response from your IdP (or a request carrying an Authorization: Bearer header). Copy the token value. |
| :---: | :---- | :---- |

| 4 | Decode it | Paste it into a JWT decoder (see below) and read the claims. |
| :---: | :---- | :---- |

### **Option B — A client (M2M) token (from the token endpoint)**

Use this for job workers, connectors, or API clients. Request a token directly with the client’s credentials:

| curl \-X POST 'https://your-idp.example.com/oauth/token' \\   \-H 'Content-Type: application/x-www-form-urlencoded' \\   \-d 'client\_id=\<your-client-id\>' \\   \-d 'client\_secret=\<your-client-secret\>' \\   \-d 'grant\_type=client\_credentials' |
| :---- |

The response contains an access\_token field — that value is the JWT to decode.

### **Decoding the token**

A JWT has three dot-separated parts; the middle part holds the claims. Decode just that part on the command line:

| echo "\<access-token\>" | cut \-d'.' \-f2 | base64 \-d | jq |
| :---- |

Or paste the token into an online decoder such as **jwt.io**. In the decoded payload, find your group claim (e.g. **groups**) and confirm its values match what your mapping rules expect — names are case-sensitive.

|  | ⚠  Watch out Access tokens are credentials. Only paste tokens from test or development environments into online tools, and never share a production user’s token. The command-line method keeps the token local. |
| :---- | :---- |

## **Authorization resource types**

| Resource type | Common permissions | Use case |
| :---- | :---- | :---- |
| **PROCESS\_DEFINITION** | READ, START\_PROCESS\_INSTANCE | Who can see or launch a process |
| **PROCESS\_INSTANCE** | READ, UPDATE, DELETE\_PROCESS\_INSTANCE | Who can manage running instances |
| **USER\_TASK** | READ\_USER\_TASK, COMPLETE\_USER\_TASK,ASSIGN\_USER\_TASK | Task visibility and completion |
| **DECISION\_DEFINITION** | READ | Access to DMN decision tables |
| **DEPLOYMENT** | CREATE, READ, DELETE | Who can deploy process files |
| **SYSTEM** | READ | Required to access the Admin UI |

## **Security checklist**

* Access is granted by mapping IdP groups to roles — never by mapping individuals.

* The admin role maps to one small, tightly governed IdP group.

* Group and tenant membership is managed in your IdP, not in Camunda.

* Each process is deployed into its intended tenant, and that tenant is mapped to the right group.

* Deploying clients are assigned only to the tenants they should deploy into.

* API protection enabled: authentication.unprotected-api: false

* Authorizations enabled: authorizations.enabled: true

* All group-to-tenant mappings are in place before enabling multi-tenancy checks.

* Claim names and values on mapping rules exactly match what your IdP issues.

## **Useful links**

* Mapping rules concept: https://docs.camunda.io/docs/components/concepts/access-control/mapping-rules/

* Connect Admin to an IdP: https://docs.camunda.io/docs/self-managed/components/orchestration-cluster/admin/connect-external-identity-provider/

* Authorizations: https://docs.camunda.io/docs/components/admin/authorization/

* Tenants: https://docs.camunda.io/docs/components/admin/tenant/

* Management Identity: https://docs.camunda.io/docs/self-managed/components/management-identity/overview/

Camunda 8.9  •  Access Control with OIDC  •  June 2026