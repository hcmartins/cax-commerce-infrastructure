#!/usr/bin/env bash
# Lints and validates the Bicep templates without deploying anything.
#
# Usage:
#   ./scripts/validate.sh [environment]     # environment defaults to "dev"
#
# Requires POSTGRES_ADMIN_PASSWORD and DEPLOYER_PRINCIPAL_ID in the environment (same
# variables deploy-dev.sh uses) since main.bicep has no default for either.
set -euo pipefail

ENVIRONMENT="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/infrastructure"
LOCATION="${LOCATION:-uksouth}"

if [[ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]]; then
  echo "POSTGRES_ADMIN_PASSWORD is not set — generating a throwaway value for validation only." >&2
  POSTGRES_ADMIN_PASSWORD="$(openssl rand -base64 24)"
fi

if [[ -z "${DEPLOYER_PRINCIPAL_ID:-}" ]]; then
  echo "DEPLOYER_PRINCIPAL_ID is not set. Resolving via 'az ad signed-in-user show'..."
  DEPLOYER_PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv)"
fi

echo "== bicep build (syntax/type check) =="
az bicep build --file "$INFRA_DIR/main.bicep" --stdout > /dev/null
echo "OK"

echo "== bicep lint =="
az bicep lint --file "$INFRA_DIR/main.bicep"

echo "== az deployment sub validate ($ENVIRONMENT) =="
az deployment sub validate \
  --location "$LOCATION" \
  --template-file "$INFRA_DIR/main.bicep" \
  --parameters "$INFRA_DIR/parameters/$ENVIRONMENT.bicepparam" \
  --parameters postgresAdminPassword="$POSTGRES_ADMIN_PASSWORD" deployerPrincipalId="$DEPLOYER_PRINCIPAL_ID"

echo "== az deployment sub what-if ($ENVIRONMENT) =="
az deployment sub what-if \
  --location "$LOCATION" \
  --template-file "$INFRA_DIR/main.bicep" \
  --parameters "$INFRA_DIR/parameters/$ENVIRONMENT.bicepparam" \
  --parameters postgresAdminPassword="$POSTGRES_ADMIN_PASSWORD" deployerPrincipalId="$DEPLOYER_PRINCIPAL_ID"

echo "Validation complete for $ENVIRONMENT."
