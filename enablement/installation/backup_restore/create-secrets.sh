#!/bin/bash
set -e

echo "Creating Kubernetes secret for S3 backup credentials..."

# Load secrets from file
source secrets.env.secret

# Create the secret
kubectl create secret generic camunda-backup-s3-credentials \
  --from-literal=access-key="${S3_ACCESS_KEY}" \
  --from-literal=secret-key="${S3_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Secret 'camunda-backup-s3-credentials' created successfully"
