#!/usr/bin/env bash
# Production-style smoke tests against a deployed DEV (or PROD) environment: liveness,
# readiness, and one read endpoint per app. Talks only to the public HTTPS endpoints — safe
# to run repeatedly against a live environment.
#
# Usage:
#   ./scripts/smoke-test.sh [resource-group]     # defaults to rg-commerce-dev
set -euo pipefail

RESOURCE_GROUP="${1:-rg-commerce-dev}"
FAILURES=0

check() {
  local description="$1"
  local url="$2"
  local expect_substring="$3"

  local body status
  if ! status="$(curl -s -o /tmp/smoke-body.$$ -w '%{http_code}' --max-time 15 "$url")"; then
    echo "[FAIL] $description — request to $url failed"
    FAILURES=$((FAILURES + 1))
    return
  fi
  body="$(cat /tmp/smoke-body.$$ 2>/dev/null || true)"
  rm -f /tmp/smoke-body.$$

  if [[ "$status" != "200" ]]; then
    echo "[FAIL] $description — HTTP $status from $url ($body)"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ -n "$expect_substring" && "$body" != *"$expect_substring"* ]]; then
    echo "[FAIL] $description — response did not contain '$expect_substring': $body"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "[PASS] $description"
}

echo "Resolving Container App endpoints in resource group '$RESOURCE_GROUP'..."
INTELLIGENCE_FQDN="$(az containerapp show --name commerce-intelligence-api --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv)"
OPERATIONS_FQDN="$(az containerapp show --name commerce-operations-api --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv)"

if [[ -z "$INTELLIGENCE_FQDN" || -z "$OPERATIONS_FQDN" ]]; then
  echo "Could not resolve one or both Container App FQDNs. Has deploy-dev.sh run successfully?" >&2
  exit 1
fi

INTELLIGENCE_URL="https://$INTELLIGENCE_FQDN"
OPERATIONS_URL="https://$OPERATIONS_FQDN"
echo "commerce-intelligence-api: $INTELLIGENCE_URL"
echo "commerce-operations-api:   $OPERATIONS_URL"
echo

echo "== commerce-intelligence-api =="
check "GET /health (liveness)" "$INTELLIGENCE_URL/health" '"status":"ok"'
check "GET /ready (readiness, DB reachable)" "$INTELLIGENCE_URL/ready" '"database":"reachable"'
check "GET /openapi.json (app is actually serving)" "$INTELLIGENCE_URL/openapi.json" '"openapi"'
echo

echo "== commerce-operations-api =="
check "GET /health (liveness)" "$OPERATIONS_URL/health" '"status":"ok"'
check "GET /ready (readiness, DB reachable)" "$OPERATIONS_URL/ready" '"status":"ready"'
check "GET /openapi.json (app is actually serving)" "$OPERATIONS_URL/openapi.json" '"openapi"'
echo

if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES smoke check(s) failed."
  exit 1
fi

echo "All smoke checks passed."
