#!/bin/bash
set -e

echo "Creating Kubernetes secret for OIDC client credentials..."

# Load secrets from file
source secrets.env

# Create the secret
kubectl create secret generic jens-keycloak-client-secrets \
  --from-literal=oc-secret="${OC_CLIENT_SECRET}" \
  --from-literal=app-integrator="${APP_INTEGRATOR_SECRET}" \
  -n camunda \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Secret 'jens-keycloak-client-secrets' created successfully"
