#!/bin/bash
# Creates the "camunda-platform" realm, its OIDC clients, the "operator"/"task-user" realm
# roles, and three example users - consumed by ../with_permissions.yaml. No LDAP federation
# (deliberately not configured) - these are standalone Keycloak-local accounts. Runs kcadm.sh
# (bundled in the Keycloak image) inside the Keycloak pod via `kubectl exec` - no port-forward
# needed. Idempotent - safe to re-run.
#
# Clients created:
#   - oc-client         -> the Orchestration Cluster's OIDC client (interactive login for
#                          Operate/Tasklist + the audience every token must carry). Its secret
#                          is written to the K8s secret camunda-keycloak-client-secrets/oc-secret.
#   - benchmark-client  -> a service-account (client_credentials) client used by
#                          ../../utils/deploy-bpmn.sh and create-process-instances.sh (via a
#                          `c8ctl add profile` with --clientId/--clientSecret) to authenticate
#                          against the v2 API. Gets its own audience mapper so its tokens are
#                          accepted by the orchestration cluster (aud: oc-client).
#
# Prerequisites: ../postgresql/postgresql-cluster.yaml and keycloak-instance.yaml already applied and ready.
#
# Every credential below is a simple, hardcoded username=password (or clientId=secret) pair,
# inlined directly in this script for easier initial understanding - swap them for real
# generated values before this becomes anything but a local/dev cluster:
#   - operator      / operator      -> realm role "operator"   (Operate: full process access)
#   - tasklist-user / tasklist-user -> realm role "task-user"  (Tasklist: user tasks only)
#   - admin         / admin         -> no realm role; matches defaultRoles.admin.users in
#                                      ../with_permissions.yaml, so gets Camunda's built-in admin
#   - oc-client        / oc-client        -> the interactive OIDC client's ID/secret pair
#   - benchmark-client / benchmark-client -> the service-account client's ID/secret pair
#                                            (matches the `c8ctl add profile` example in
#                                            ../ENABLEMENT_FULL_INSTALLATION_README.MD)

set -euo pipefail

KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE:-keycloak}
CAMUNDA_NAMESPACE=${CAMUNDA_NAMESPACE:-camunda}
KEYCLOAK_POD=${KEYCLOAK_POD:-keycloak-0}
REALM=${REALM:-camunda-platform}
CLIENT_ID=${CLIENT_ID:-oc-client}
CLIENT_SECRET=${CLIENT_SECRET:-oc-client}
BENCHMARK_CLIENT_ID=${BENCHMARK_CLIENT_ID:-benchmark-client}
BENCHMARK_CLIENT_SECRET=${BENCHMARK_CLIENT_SECRET:-benchmark-client}
# Wildcard so it covers whatever callback path Camunda's OIDC client constructs under the
# redirectUrl host:port configured in ../with_permissions.yaml.
REDIRECT_URI=${REDIRECT_URI:-http://localhost:8080/*}

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

# Adds an audience mapper to a client so issued tokens carry `aud: oc-client` - matches
# orchestration.security.authentication.oidc.audience in ../with_permissions.yaml. Every client
# whose tokens hit the orchestration cluster needs this.
add_audience_mapper() {
  local client_uuid=$1
  kc_exec create "clients/$client_uuid/protocol-mappers/models" -r "$REALM" \
    -s name=aud-mapper \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s "config={\"included.client.audience\":\"$CLIENT_ID\",\"access.token.claim\":\"true\"}" \
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
  -s "redirectUris=[\"$REDIRECT_URI\"]" \
  -s 'webOrigins=["+"]' \
  || echo "  -> client '$CLIENT_ID' already exists, skipping"

OC_CLIENT_UUID=$(kc_exec get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')

echo "Adding an audience mapper to '$CLIENT_ID' so tokens carry 'aud: $CLIENT_ID' ..."
add_audience_mapper "$OC_CLIENT_UUID"

echo "Writing the client secret to '$CAMUNDA_NAMESPACE/camunda-keycloak-client-secrets' (key: oc-secret) ..."
# For a real deployment, generate the client secret above instead of hardcoding it, and
# retrieve it here rather than writing back the known literal:
#   CLIENT_SECRET=$(kc_exec get "clients/$OC_CLIENT_UUID/client-secret" -r "$REALM" --fields value --format csv --noquotes | tr -d '\r')
kubectl create secret generic camunda-keycloak-client-secrets \
  --namespace "$CAMUNDA_NAMESPACE" \
  --from-literal=oc-secret="$CLIENT_SECRET" \
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
  || echo "  -> client '$BENCHMARK_CLIENT_ID' already exists, skipping"

BENCHMARK_CLIENT_UUID=$(kc_exec get clients -r "$REALM" -q clientId="$BENCHMARK_CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')

echo "Adding an audience mapper to '$BENCHMARK_CLIENT_ID' so its tokens carry 'aud: $CLIENT_ID' ..."
add_audience_mapper "$BENCHMARK_CLIENT_UUID"

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

echo ""
echo "Done - realm: $REALM"
echo "  clients: $CLIENT_ID / $CLIENT_SECRET (interactive), $BENCHMARK_CLIENT_ID / $BENCHMARK_CLIENT_SECRET (service account)"
echo "  roles: operator, task-user"
echo "  example users (all username=password): operator, tasklist-user, admin"
