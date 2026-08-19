# commerce-infrastructure

Azure Bicep infrastructure-as-code for the commerce platform's Azure environments. Provisions
everything commerce-intelligence and commerce-operations need to run their backend APIs in
Azure: Container Apps, PostgreSQL, Key Vault, Container Registry, Storage, and monitoring.

See [docs/architecture.md](docs/architecture.md) for the full design rationale, a diagram,
and the security/scope decisions behind this phase.

## Repository layout

```
infrastructure/
  main.bicep                  Subscription-scoped entry point — creates the resource group
                               and wires together every module below.
  modules/
    monitoring.bicep           Log Analytics workspace + workspace-based Application Insights
    identity.bicep              Two user-assigned managed identities, one per app
    container-registry.bicep    Azure Container Registry (Basic SKU) + AcrPull role assignments
    storage.bicep                Storage account + raw-outputs/exports/listing-assets containers
    postgres.bicep                PostgreSQL Flexible Server + two databases + firewall rules
    key-vault.bicep                 Key Vault + app secrets + RBAC role assignments
    container-apps.bicep             Container Apps Environment + the two API container apps
    budget.bicep                      Resource-group cost budget with email alerts
  parameters/
    dev.bicepparam               DEV parameter values (deployed by this phase)
    prod.bicepparam               PROD parameter values (NOT deployed by this phase)
scripts/
  deploy-dev.sh                 End-to-end: infra -> build -> push -> deploy -> migrate -> verify
  validate.sh                   Lint + az deployment validate + what-if, no changes made
  smoke-test.sh                 curl-based /health, /ready, /openapi.json checks against a live deployment
docs/
  architecture.md               Design rationale, diagram, deferred components, security decisions
```

## Expected local layout

The deploy script builds Docker images from sibling application repos, matching the layout
used for local development:

```
projects/
  commerce-infrastructure/   (this repo)
  commerce-intelligence/
  commerce-operations/
```

Override `INTELLIGENCE_REPO_DIR` / `OPERATIONS_REPO_DIR` if your checkouts live elsewhere.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`), logged in
  interactively or via a service principal
- The Bicep CLI extension: `az bicep install` (or `az bicep upgrade` if already installed)
- Docker Desktop or an equivalent Docker CLI
- An Azure subscription with permission to create resource groups and assign RBAC roles

## Deploying DEV

```bash
# 1. Set the one required secret — never commit this, never put it in a parameter file.
export POSTGRES_ADMIN_PASSWORD="$(openssl rand -base64 24)"

# 2. Optional: target a specific subscription (otherwise uses your current `az account`)
export AZURE_SUBSCRIPTION_ID="<subscription-id>"

# 3. Run the full pipeline
./scripts/deploy-dev.sh
```

This single script performs every step in the Phase 2 deployment checklist:

1. `az login` (only if not already authenticated) and subscription selection
2. Resolves your Azure AD object ID and public IP (for Key Vault and Postgres access)
3. Validates the Bicep deployment (`scripts/validate.sh`: lint, `deployment sub validate`, what-if)
4. Deploys the DEV infrastructure (`az deployment sub create`) — resource group included
5. Builds both Docker images (commerce-intelligence's `api.Dockerfile`, commerce-operations'
   `api` build target)
6. Pushes both images to the newly created Container Registry
7. Points both Container Apps at the pushed images (`az containerapp update`)
8. Runs commerce-operations' Alembic migrations (`docker run` of its `migrate` build target
   against the Azure Postgres server). commerce-intelligence migrates itself on container
   startup — see `docker/api.Dockerfile` in that repo — so no separate step is needed for it.
9. Verifies `/health` on both apps
10. Verifies `/ready` on both apps (confirms database connectivity)
11. Runs `scripts/smoke-test.sh` against both deployed endpoints

Re-running the whole script is safe — every step is idempotent.

### Running steps individually

```bash
# Validate only, no changes:
./scripts/validate.sh dev

# Smoke-test an already-deployed environment:
./scripts/smoke-test.sh rg-commerce-dev
```

## What gets created

| # | Resource | Purpose |
|---|---|---|
| 1 | Resource Group `rg-commerce-dev` | Container for everything below |
| 2 | Container Registry (Basic) | Hosts both apps' images |
| 3 | Container Apps Environment (Consumption) | Runtime for the two API apps |
| 4 | Container Apps `commerce-intelligence-api`, `commerce-operations-api` | The two backend APIs, scale 0-1 |
| 5 | PostgreSQL Flexible Server (`Standard_B1ms`) | Shared database server |
| 6 | Databases `ai_commerce`, `commerce_operations` | One per app, on the shared server |
| 7 | Storage Account + 3 blob containers | `raw-outputs`, `exports`, `listing-assets` |
| 8 | Key Vault (RBAC) | Postgres password, both apps' DB connection strings, App Insights connection string |
| 9 | Log Analytics + Application Insights | Centralised logs/metrics |
| 10 | 2 user-assigned managed identities | One per app, used for ACR/Key Vault/Storage access |
| 11 | Cost budget | Email alerts at 80% actual / 100% forecasted monthly spend |

PROD is **not** deployed by this phase — `infrastructure/parameters/prod.bicepparam` exists
so the split is in place, but `deploy-dev.sh` only ever targets DEV, and its placeholder
images must be replaced with real tagged images before anyone runs a PROD deployment.

## Secrets and configuration

No secret, password, connection string, or environment-specific value is hard-coded anywhere
in this repository. The one value that must never be committed —
`POSTGRES_ADMIN_PASSWORD` — is supplied only via an environment variable at deploy time, and
flows straight into Key Vault. Everything else either has a safe non-secret default in the
`.bicepparam` files or is derived at deploy time (your Azure AD object ID, your public IP).

## Cost drivers (approximate, UK South, DEV)

| Resource | Approx. monthly cost driver |
|---|---|
| Container Apps (x2, scale-to-zero, Consumption) | ~$0 idle; a few dollars under light dev traffic |
| Container Registry (Basic) | ~$5/month flat |
| PostgreSQL Flexible Server (`Standard_B1ms`, 32 GiB) | ~$12-15/month |
| Storage Account (Standard_LRS, near-empty) | Cents/month at DEV data volumes |
| Key Vault | Negligible (per-operation pricing, low volume) |
| Log Analytics + Application Insights (30-day retention) | A few dollars/month at DEV log volumes |
| **Total** | **Roughly $20-30/month**, with the budget alert set to $50 |

The dominant fixed cost is PostgreSQL (it doesn't scale to zero); everything else scales down
with usage.
# cax-commerce-infrastructure
