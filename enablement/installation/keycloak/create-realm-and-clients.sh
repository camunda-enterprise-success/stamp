#!/bin/bash
# Creates the "camunda-platform" realm, all its OIDC clients, the "operator"/"task-user" realm
# roles, and example users - consumed by ../with_permissions.yaml (+ ../with_optimize.yaml +
# ../with_identity_webmodeler.yaml). No LDAP federation (deliberately not configured) - these are
# standalone Keycloak-local accounts. Runs kcadm.sh (bundled in the Keycloak image) inside the
# Keycloak pod via `kubectl exec` - no port-forward needed. Idempotent - safe to re-run.
#
# Every client below is always created, regardless of which track (RDBMS-only, or Elasticsearch +
# Optimize + Identity + Web Modeler) you end up deploying with - unused clients are harmless, and a
# single always-the-same realm means either track can be layered on top without re-running this
# script differently. Follows Camunda's own "Option 1: prepare an existing realm" pattern for
# external Keycloak -
# https://docs.camunda.io/docs/self-managed/deployment/helm/configure/authentication-and-authorization/external-keycloak/#configure-components-using-oidc -
# every OIDC client Management Identity would otherwise need is created explicitly, up front, by
# this script - rather than relying on Identity's own startup-time self-provisioning
# (KeycloakPresetInitializer) for anything beyond its own client lookup. That self-provisioning path
# was tried first and found to be non-idempotent in this repo's testing: it always attempts to
# CREATE its resource-server clients unconditionally (no existence check), so it 409-crashes on
# every restart after the first success, and even a from-scratch attempt intermittently produced a
# client with authorizationServicesEnabled=true that a later step then refuses to manage. Explicit
# client preparation (this script) plus identity.env's KEYCLOAK_REALM/IDENTITY_CLIENTID (see
# ../with_identity_webmodeler.yaml) sidesteps that path entirely per Camunda's documented Option 1.
#
# Clients created:
#   - orchestration    -> the Orchestration Cluster's OIDC client (interactive login for
#                         Operate/Tasklist + the audience every token must carry). Matches the
#                         chart's own default clientId/audience for
#                         orchestration.security.authentication.oidc. Its secret is written to the
#                         K8s secret camunda-keycloak-client-secrets/orchestration-secret.
#   - benchmark-client -> a service-account (client_credentials) client used by
#                         ../../utils/deploy-bpmn.sh and create-process-instances.sh (via a
#                         `c8ctl add profile` with --clientId/--clientSecret) to authenticate
#                         against the v2 API. Gets its own audience mapper so its tokens are
#                         accepted by the orchestration cluster (aud: $ORCHESTRATION_AUDIENCE).
#   - camunda-identity -> Management Identity's own client. Confidential, service account roles
#                         on, Authorization explicitly OFF - exactly the settings Camunda's own
#                         "connect to an existing Keycloak" guide specifies for this client:
#                         https://docs.camunda.io/docs/next/self-managed/components/management-identity/configuration/connect-to-an-existing-keycloak/
#   - optimize         -> Optimize's own client. Audience is "optimize-api" (chart default,
#                         global.identity.auth.optimize.audience) - a resource-server identifier,
#                         not this client's own clientId, so it needs a "custom" audience mapper.
#   - web-modeler      -> Web Modeler's own client. PUBLIC (no secret) - Web Modeler authenticates
#                         via the browser (PKCE), never as a confidential backend client.
# camunda-identity/optimize/orchestration's secrets (plus the Keycloak admin password and the
# "admin" first-user password) are written into a single consolidated K8s Secret,
# "camunda-credentials" in the camunda namespace, using the exact key names Camunda's own
# external-Keycloak example uses - see ../with_optimize.yaml and ../with_identity_webmodeler.yaml
# for where each key is consumed.
#
# Redirect URIs are registered explicitly per client - the real callback path(s) each Camunda web
# app actually uses, scoped under that app's own contextPath (see ../with_optimize.yaml /
# ../with_identity_webmodeler.yaml for the contextPath each *_URL below must match), rather than a
# blanket http://host:port/* wildcard. Sourced from Camunda's generic-oidc-provider doc -
# https://docs.camunda.io/docs/self-managed/deployment/helm/configure/authentication-and-authorization/generic-oidc-provider/ -
# and cross-checked against the chart's own KeycloakPresetInitializer preset (visible via
# `helm template ... camunda/camunda-platform`, in the rendered camunda-identity-configuration
# ConfigMap's component-presets block).
#
# Prerequisites: ../postgresql/postgresql-cluster.yaml and keycloak-instance.yaml already applied and ready.
#
# Every credential below is a simple, hardcoded username=password (or clientId=secret) pair,
# inlined directly in this script for easier initial understanding - swap them for real
# generated values before this becomes anything but a local/dev cluster:
#   - operator      / operator      -> realm role "operator"   (Operate: full process access)
#   - tasklist-user / tasklist-user -> realm role "task-user"  (Tasklist: user tasks only)
#   - admin         / admin         -> no realm role; matches defaultRoles.admin.users in
#                                      ../with_permissions.yaml, so gets Camunda's built-in admin.
#                                      Also reused as Management Identity's first user
#                                      (identity.firstUser, username overridden from the chart
#                                      default "demo" to "admin" for a consistent login across
#                                      this whole guide).
#   - orchestration    / orchestration    -> the interactive OIDC client's ID/secret pair
#   - benchmark-client / benchmark-client -> the service-account client's ID/secret pair
#                                            (matches the `c8ctl add profile` example in
#                                            ../ENABLEMENT_FULL_INSTALLATION_README.MD)
#   - camunda-identity / camunda-identity -> Management Identity's own client ID/secret pair
#   - optimize         / optimize         -> Optimize's client ID/secret pair
#   - web-modeler      / (n/a, public)     -> Web Modeler's client ID (no secret)

set -euo pipefail

KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE:-keycloak}
CAMUNDA_NAMESPACE=${CAMUNDA_NAMESPACE:-camunda}
KEYCLOAK_POD=${KEYCLOAK_POD:-keycloak-0}
REALM=${REALM:-camunda-platform}
CLIENT_ID=${CLIENT_ID:-orchestration}
CLIENT_SECRET=${CLIENT_SECRET:-orchestration}
BENCHMARK_CLIENT_ID=${BENCHMARK_CLIENT_ID:-benchmark-client}
BENCHMARK_CLIENT_SECRET=${BENCHMARK_CLIENT_SECRET:-benchmark-client}
# Orchestration's contextPath is "/" (root) - see ../minimal_setup.yaml / ../minimal_setup_elasticsearch.yaml.
ORCHESTRATION_URL=${ORCHESTRATION_URL:-http://localhost:8080}
# benchmark-client's tokens carry aud: $CLIENT_ID by default, i.e. "orchestration".
ORCHESTRATION_AUDIENCE=${ORCHESTRATION_AUDIENCE:-$CLIENT_ID}

IDENTITY_CLIENT_ID=${IDENTITY_CLIENT_ID:-camunda-identity}
IDENTITY_CLIENT_SECRET=${IDENTITY_CLIENT_SECRET:-camunda-identity}
IDENTITY_AUDIENCE=${IDENTITY_AUDIENCE:-camunda-identity-resource-server}
# Matches identity.contextPath: "/identity" in ../with_identity_webmodeler.yaml.
IDENTITY_URL=${IDENTITY_URL:-http://localhost:8084/identity}
OPTIMIZE_CLIENT_ID=${OPTIMIZE_CLIENT_ID:-optimize}
OPTIMIZE_CLIENT_SECRET=${OPTIMIZE_CLIENT_SECRET:-optimize}
OPTIMIZE_AUDIENCE=${OPTIMIZE_AUDIENCE:-optimize-api}
# Matches optimize.contextPath: "/optimize" in ../with_optimize.yaml.
OPTIMIZE_URL=${OPTIMIZE_URL:-http://localhost:8083/optimize}
WEBMODELER_CLIENT_ID=${WEBMODELER_CLIENT_ID:-web-modeler}
# Matches webModeler.contextPath: "/modeler" in ../with_identity_webmodeler.yaml.
WEBMODELER_URL=${WEBMODELER_URL:-http://localhost:8070/modeler}
FIRSTUSER_USERNAME=${FIRSTUSER_USERNAME:-admin}
FIRSTUSER_PASSWORD=${FIRSTUSER_PASSWORD:-admin}

KCADM="/opt/keycloak/bin/kcadm.sh"
kc_exec() { kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- "$KCADM" "$@"; }

# For a real deployment, read these from the Secret instead (matches keycloak-admin-credentials
# in keycloak-instance.yaml):
#   ADMIN_USER=$(kubectl get secret keycloak-admin-credentials -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
#   ADMIN_PASS=$(kubectl get secret keycloak-admin-credentials -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
ADMIN_USER=admin
ADMIN_PASS=admin

echo "Authenticating kcadm.sh against http://localhost:18080/auth (in-pod) ..."
kc_exec config credentials \
  --server http://localhost:18080/auth \
  --realm master \
  --user "$ADMIN_USER" \
  --password "$ADMIN_PASS"

echo "Creating realm '$REALM' ..."
kc_exec create realms -s realm="$REALM" -s enabled=true \
  || echo "  -> realm '$REALM' already exists, skipping"

echo "Creating realm roles 'operator' and 'task-user' ..."
for ROLE in operator task-user; do
  kc_exec create roles -r "$REALM" -s name="$ROLE" \
    || echo "  -> role '$ROLE' already exists, skipping"
done

# Adds an audience mapper to a client. Two modes: "client" targets an existing CLIENT's own
# clientId as the audience (`included.client.audience`) - used below for orchestration/
# benchmark-client, whose audience equals their own clientId by chart convention/default. "custom"
# targets an arbitrary, non-client audience string (`included.custom.audience`) - used below for
# camunda-identity ("camunda-identity-resource-server") and optimize ("optimize-api"), whose
# audiences are resource-server identifiers, not registered clients.
add_audience_mapper() {
  local client_uuid=$1
  local mode=$2
  local audience=$3
  local audience_config
  if [[ "$mode" == "custom" ]]; then
    audience_config="{\"included.custom.audience\":\"$audience\",\"access.token.claim\":\"true\"}"
  else
    audience_config="{\"included.client.audience\":\"$audience\",\"access.token.claim\":\"true\"}"
  fi
  kc_exec create "clients/$client_uuid/protocol-mappers/models" -r "$REALM" \
    -s name=aud-mapper \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s "config=$audience_config" \
    || echo "  -> audience mapper already exists, skipping"
}

echo "Creating client '$CLIENT_ID' (secret: '$CLIENT_SECRET') ..."
kc_exec create clients -r "$REALM" \
  -s clientId="$CLIENT_ID" \
  -s secret="$CLIENT_SECRET" \
  -s enabled=true \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s serviceAccountsEnabled=true \
  -s authorizationServicesEnabled=false \
  -s "redirectUris=[\"$ORCHESTRATION_URL/sso-callback\",\"$ORCHESTRATION_URL/login/oauth2/code/$CLIENT_ID\"]" \
  -s 'webOrigins=["+"]' \
  || echo "  -> client '$CLIENT_ID' already exists, skipping"

OC_CLIENT_UUID=$(kc_exec get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')

echo "Adding an audience mapper to '$CLIENT_ID' so tokens carry 'aud: $CLIENT_ID' ..."
add_audience_mapper "$OC_CLIENT_UUID" client "$CLIENT_ID"

echo "Writing the client secret to '$CAMUNDA_NAMESPACE/camunda-keycloak-client-secrets' (key: orchestration-secret) ..."
# For a real deployment, generate the client secret above instead of hardcoding it, and
# retrieve it here rather than writing back the known literal:
#   CLIENT_SECRET=$(kc_exec get "clients/$OC_CLIENT_UUID/client-secret" -r "$REALM" --fields value --format csv --noquotes | tr -d '\r')
kubectl create secret generic camunda-keycloak-client-secrets \
  --namespace "$CAMUNDA_NAMESPACE" \
  --from-literal=orchestration-secret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Creating service-account client '$BENCHMARK_CLIENT_ID' (secret: '$BENCHMARK_CLIENT_SECRET') ..."
# client_credentials only - no interactive login, so standard flow is off. Used by a c8ctl
# profile (see ../ENABLEMENT_FULL_INSTALLATION_README.MD) to authenticate the utility scripts
# under ../../utils against the v2 API.
kc_exec create clients -r "$REALM" \
  -s clientId="$BENCHMARK_CLIENT_ID" \
  -s secret="$BENCHMARK_CLIENT_SECRET" \
  -s enabled=true \
  -s publicClient=false \
  -s standardFlowEnabled=false \
  -s serviceAccountsEnabled=true \
  -s authorizationServicesEnabled=false \
  || echo "  -> client '$BENCHMARK_CLIENT_ID' already exists, skipping"

BENCHMARK_CLIENT_UUID=$(kc_exec get clients -r "$REALM" -q clientId="$BENCHMARK_CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')

echo "Adding an audience mapper to '$BENCHMARK_CLIENT_ID' so its tokens carry 'aud: $ORCHESTRATION_AUDIENCE' ..."
add_audience_mapper "$BENCHMARK_CLIENT_UUID" client "$ORCHESTRATION_AUDIENCE"

create_example_user() {
  local username=$1 password=$2 role=$3

  kc_exec create users -r "$REALM" -s username="$username" -s enabled=true \
    || echo "  -> user '$username' already exists, skipping creation"

  kc_exec set-password -r "$REALM" --username "$username" --new-password "$password" >/dev/null

  if [[ -n "$role" ]]; then
    kc_exec add-roles -r "$REALM" --uusername "$username" --rolename "$role" \
      || echo "  -> role '$role' already assigned to '$username', skipping"
  fi
}

echo "Creating example user 'operator' / 'operator' (role: operator) ..."
create_example_user operator operator operator

echo "Creating example user 'tasklist-user' / 'tasklist-user' (role: task-user) ..."
create_example_user tasklist-user tasklist-user task-user

echo "Creating example user 'admin' / 'admin' (matches defaultRoles.admin.users, no realm role) ..."
create_example_user admin admin ""

echo "Creating client '$IDENTITY_CLIENT_ID' (Management Identity's own client) ..."
kc_exec create clients -r "$REALM" \
  -s clientId="$IDENTITY_CLIENT_ID" \
  -s secret="$IDENTITY_CLIENT_SECRET" \
  -s enabled=true \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s serviceAccountsEnabled=true \
  -s authorizationServicesEnabled=false \
  -s "redirectUris=[\"$IDENTITY_URL/auth/login-callback\"]" \
  -s 'webOrigins=["+"]' \
  || echo "  -> client '$IDENTITY_CLIENT_ID' already exists, skipping"

IDENTITY_CLIENT_UUID=$(kc_exec get clients -r "$REALM" -q clientId="$IDENTITY_CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')

echo "Adding an audience mapper to '$IDENTITY_CLIENT_ID' so its tokens carry 'aud: $IDENTITY_AUDIENCE' ..."
add_audience_mapper "$IDENTITY_CLIENT_UUID" custom "$IDENTITY_AUDIENCE"

# Management Identity's client needs these three realm-management client roles on its OWN
# service account (not just the master-realm admin user configured via
# global.identity.keycloak.auth.adminUser) to manage users/clients/roles in the target realm at
# runtime - without them, Identity authenticates fine but every subsequent admin call 403s. Per
# Camunda's connect-to-an-existing-keycloak guide:
# https://docs.camunda.io/docs/next/self-managed/components/management-identity/configuration/connect-to-an-existing-keycloak/
echo "Granting realm-management service-account roles (manage-clients, manage-realm, manage-users) to '$IDENTITY_CLIENT_ID' ..."
kc_exec add-roles -r "$REALM" \
  --uusername "service-account-$IDENTITY_CLIENT_ID" \
  --cclientid realm-management \
  --rolename manage-clients \
  --rolename manage-realm \
  --rolename manage-users \
  || echo "  -> roles already assigned, skipping"

echo "Creating client '$OPTIMIZE_CLIENT_ID' (secret: '$OPTIMIZE_CLIENT_SECRET') ..."
kc_exec create clients -r "$REALM" \
  -s clientId="$OPTIMIZE_CLIENT_ID" \
  -s secret="$OPTIMIZE_CLIENT_SECRET" \
  -s enabled=true \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s serviceAccountsEnabled=true \
  -s authorizationServicesEnabled=false \
  -s "redirectUris=[\"$OPTIMIZE_URL/api/authentication/callback\"]" \
  -s 'webOrigins=["+"]' \
  || echo "  -> client '$OPTIMIZE_CLIENT_ID' already exists, skipping"

OPTIMIZE_CLIENT_UUID=$(kc_exec get clients -r "$REALM" -q clientId="$OPTIMIZE_CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')

echo "Adding an audience mapper to '$OPTIMIZE_CLIENT_ID' so its tokens carry 'aud: $OPTIMIZE_AUDIENCE' ..."
add_audience_mapper "$OPTIMIZE_CLIENT_UUID" custom "$OPTIMIZE_AUDIENCE"

echo "Creating public client '$WEBMODELER_CLIENT_ID' (no secret - browser/PKCE login) ..."
kc_exec create clients -r "$REALM" \
  -s clientId="$WEBMODELER_CLIENT_ID" \
  -s enabled=true \
  -s publicClient=true \
  -s standardFlowEnabled=true \
  -s serviceAccountsEnabled=false \
  -s authorizationServicesEnabled=false \
  -s "redirectUris=[\"$WEBMODELER_URL/login-callback\"]" \
  -s 'webOrigins=["+"]' \
  || echo "  -> client '$WEBMODELER_CLIENT_ID' already exists, skipping"

echo "Writing '$CAMUNDA_NAMESPACE/camunda-credentials' (Camunda's own external-Keycloak secret naming - see ../with_optimize.yaml and ../with_identity_webmodeler.yaml) ..."
kubectl create secret generic camunda-credentials \
  --namespace "$CAMUNDA_NAMESPACE" \
  --from-literal=identity-keycloak-admin-password="$ADMIN_PASS" \
  --from-literal=identity-firstuser-password="$FIRSTUSER_PASSWORD" \
  --from-literal=identity-client-secret="$IDENTITY_CLIENT_SECRET" \
  --from-literal=identity-orchestration-client-token="$CLIENT_SECRET" \
  --from-literal=identity-optimize-client-token="$OPTIMIZE_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Creating first user '$FIRSTUSER_USERNAME' / '$FIRSTUSER_PASSWORD' (Management Identity login, matches identity.firstUser.username override) ..."
create_example_user "$FIRSTUSER_USERNAME" "$FIRSTUSER_PASSWORD" ""

echo ""
echo "Done - realm: $REALM"
echo "  clients: $CLIENT_ID / $CLIENT_SECRET (interactive), $BENCHMARK_CLIENT_ID / $BENCHMARK_CLIENT_SECRET (service account, aud: $ORCHESTRATION_AUDIENCE), $IDENTITY_CLIENT_ID, $OPTIMIZE_CLIENT_ID, $WEBMODELER_CLIENT_ID (public)"
echo "  camunda-credentials secret keys: identity-keycloak-admin-password, identity-firstuser-password, identity-client-secret, identity-orchestration-client-token, identity-optimize-client-token"
echo "  roles: operator, task-user"
echo "  example users (all username=password): operator, tasklist-user, admin"
