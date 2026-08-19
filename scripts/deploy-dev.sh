#!/usr/bin/env bash
# End-to-end Phase 2 DEV deployment: infra -> build -> push -> deploy -> migrate -> verify.
# Safe to re-run — every step is idempotent (Bicep deployments, `docker build`, `az acr
# import`/push of an existing tag, `az containerapp update`, and `alembic upgrade head`
# are all no-ops or overwrite-in-place when re-applied).
#
# Prerequisites:
#   - az CLI, docker, and this repo checked out
#   - Sibling checkouts of commerce-intelligence and commerce-operations (see
#     README.md for the expected ../ layout), or set
#     INTELLIGENCE_REPO_DIR / OPERATIONS_REPO_DIR to point at them.
#
# Required environment variables:
#   POSTGRES_ADMIN_PASSWORD   - PostgreSQL admin password (never stored in this repo)
#
# Optional environment variables:
#   AZURE_SUBSCRIPTION_ID     - subscription to deploy into (uses current `az account` if unset)
#   ENVIRONMENT               - "dev" (default) or "prod"
#   LOCATION                  - Azure region (default: uksouth, matches the .bicepparam files)
#   INTELLIGENCE_REPO_DIR     - path to the commerce-intelligence checkout (default: ../commerce-intelligence)
#   OPERATIONS_REPO_DIR       - path to the commerce-operations checkout (default: ../commerce-operations)
#   IMAGE_TAG                 - tag applied to both images (default: short git SHA of each repo, else "dev")
#   SKIP_MIGRATIONS           - set to "1" to skip the commerce-operations migration step
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infrastructure"

ENVIRONMENT="${ENVIRONMENT:-dev}"
LOCATION="${LOCATION:-uksouth}"
INTELLIGENCE_REPO_DIR="${INTELLIGENCE_REPO_DIR:-$REPO_ROOT/../commerce-intelligence}"
OPERATIONS_REPO_DIR="${OPERATIONS_REPO_DIR:-$REPO_ROOT/../commerce-operations}"

RESOURCE_GROUP="rg-commerce-$ENVIRONMENT"

if [[ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]]; then
  echo "ERROR: POSTGRES_ADMIN_PASSWORD must be set. Example (bash):" >&2
  echo "  export POSTGRES_ADMIN_PASSWORD=\"\$(openssl rand -base64 24)\"" >&2
  exit 1
fi

echo "=== 1/11: Azure authentication ==="
if ! az account show >/dev/null 2>&1; then
  az login
fi
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
fi
az account show --query '{subscriptionId:id, name:name, tenantId:tenantId}' -o table

echo "=== 2/11: Resolve deployer identity and Postgres client IP ==="
DEPLOYER_PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv)"
echo "Deployer principal ID: $DEPLOYER_PRINCIPAL_ID"
CLIENT_IP="$(curl -s --max-time 5 https://api.ipify.org || true)"
if [[ -n "$CLIENT_IP" ]]; then
  echo "Deploy machine public IP: $CLIENT_IP (will be allow-listed on Postgres for migrations)"
else
  echo "Could not resolve a public IP; Postgres will only be reachable from Azure services."
fi

echo "=== 3/11: Validate the Bicep deployment (what-if) ==="
POSTGRES_ADMIN_PASSWORD="$POSTGRES_ADMIN_PASSWORD" \
DEPLOYER_PRINCIPAL_ID="$DEPLOYER_PRINCIPAL_ID" \
LOCATION="$LOCATION" \
  "$SCRIPT_DIR/validate.sh" "$ENVIRONMENT"

echo "=== 4/11: Deploy DEV infrastructure ==="
DEPLOYMENT_NAME="commerce-$ENVIRONMENT-$(date +%Y%m%d%H%M%S)"
az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --template-file "$INFRA_DIR/main.bicep" \
  --parameters "$INFRA_DIR/parameters/$ENVIRONMENT.bicepparam" \
  --parameters postgresAdminPassword="$POSTGRES_ADMIN_PASSWORD" \
               deployerPrincipalId="$DEPLOYER_PRINCIPAL_ID" \
               clientIpAddress="$CLIENT_IP"

ACR_LOGIN_SERVER="$(az deployment sub show --name "$DEPLOYMENT_NAME" --query properties.outputs.acrLoginServer.value -o tsv)"
ACR_NAME="$(az deployment sub show --name "$DEPLOYMENT_NAME" --query properties.outputs.acrName.value -o tsv)"
KEY_VAULT_NAME="$(az deployment sub show --name "$DEPLOYMENT_NAME" --query properties.outputs.keyVaultName.value -o tsv)"
echo "Resource group: $RESOURCE_GROUP"
echo "ACR:            $ACR_LOGIN_SERVER"
echo "Key Vault:      $KEY_VAULT_NAME"

echo "=== 5/11: Build Docker images ==="
if [[ ! -d "$INTELLIGENCE_REPO_DIR" ]]; then
  echo "ERROR: commerce-intelligence checkout not found at $INTELLIGENCE_REPO_DIR" >&2
  exit 1
fi
if [[ ! -d "$OPERATIONS_REPO_DIR" ]]; then
  echo "ERROR: commerce-operations checkout not found at $OPERATIONS_REPO_DIR" >&2
  exit 1
fi

INTELLIGENCE_TAG="${IMAGE_TAG:-$(git -C "$INTELLIGENCE_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)}"
OPERATIONS_TAG="${IMAGE_TAG:-$(git -C "$OPERATIONS_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)}"

INTELLIGENCE_IMAGE="$ACR_LOGIN_SERVER/commerce-intelligence-api:$INTELLIGENCE_TAG"
OPERATIONS_IMAGE="$ACR_LOGIN_SERVER/commerce-operations-api:$OPERATIONS_TAG"

docker build -f "$INTELLIGENCE_REPO_DIR/docker/api.Dockerfile" -t "$INTELLIGENCE_IMAGE" "$INTELLIGENCE_REPO_DIR"
docker build --target api -t "$OPERATIONS_IMAGE" "$OPERATIONS_REPO_DIR"
docker build --target migrate -t "commerce-operations-migrate:$OPERATIONS_TAG" "$OPERATIONS_REPO_DIR"

echo "=== 6/11: Push images to ACR ==="
az acr login --name "$ACR_NAME"
docker push "$INTELLIGENCE_IMAGE"
docker push "$OPERATIONS_IMAGE"

echo "=== 7/11: Update Container Apps to the new images ==="
az containerapp update --name commerce-intelligence-api --resource-group "$RESOURCE_GROUP" --image "$INTELLIGENCE_IMAGE"
az containerapp update --name commerce-operations-api --resource-group "$RESOURCE_GROUP" --image "$OPERATIONS_IMAGE"

echo "=== 8/11: Run commerce-operations Alembic migrations ==="
# commerce-intelligence runs "alembic upgrade head" as part of its own container startup
# (see docker/api.Dockerfile), so no separate step is needed for it. commerce-operations
# keeps migration as a distinct one-shot process (its "migrate" build target) — run it here
# against the Azure Postgres server directly, over the firewall rule added for this
# machine's IP in step 4.
if [[ "${SKIP_MIGRATIONS:-0}" != "1" ]]; then
  OPERATIONS_DATABASE_URL="$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name commerce-operations-database-url --query value -o tsv)"
  docker run --rm -e COMMERCE_DATABASE_URL="$OPERATIONS_DATABASE_URL" "commerce-operations-migrate:$OPERATIONS_TAG"
else
  echo "SKIP_MIGRATIONS=1 — skipping."
fi

echo "=== 9/11: Verify /health ==="
INTELLIGENCE_FQDN="$(az containerapp show --name commerce-intelligence-api --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv)"
OPERATIONS_FQDN="$(az containerapp show --name commerce-operations-api --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv)"
curl -fsS "https://$INTELLIGENCE_FQDN/health" && echo
curl -fsS "https://$OPERATIONS_FQDN/health" && echo

echo "=== 10/11: Verify /ready ==="
curl -fsS "https://$INTELLIGENCE_FQDN/ready" && echo
curl -fsS "https://$OPERATIONS_FQDN/ready" && echo

echo "=== 11/11: Smoke tests ==="
"$SCRIPT_DIR/smoke-test.sh" "$RESOURCE_GROUP"

echo
echo "Deployment complete."
echo "commerce-intelligence-api: https://$INTELLIGENCE_FQDN"
echo "commerce-operations-api:   https://$OPERATIONS_FQDN"
