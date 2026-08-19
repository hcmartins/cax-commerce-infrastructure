using '../main.bicep'

// Not deployed in Phase 2 — provided so the DEV/PROD split exists from day one and PROD
// can be reviewed and adjusted (SKUs, replica counts, budget) before it is first deployed.
//
// postgresAdminPassword, deployerPrincipalId, and clientIpAddress are intentionally NOT set
// here — supply them via `--parameters` CLI overrides at deploy time, from a proper secret
// store/CI pipeline for PROD, never from a developer's shell history.

param environmentName = 'prod'
param location = 'uksouth'

param postgresAdminUsername = 'commerceadmin'
// Slightly larger than dev's Burstable B1ms — reassess against real PROD load before first use.
param postgresSkuName = 'Standard_B2s'
param postgresStorageSizeGb = 64

// PROD must not deploy the placeholder image — set these to a real, tagged ACR image
// before running a PROD deployment.
param intelligenceApiImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param operationsApiImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

// PROD should not scale to zero (cold starts on a customer-facing environment) and should
// tolerate at least one instance failure — revisit before first PROD deployment.
param containerAppMinReplicas = 1
param containerAppMaxReplicas = 3

param budgetAmount = 150
param budgetContactEmails = [
  'hcaxtonmartins@gmail.com'
]

param logAnalyticsRetentionDays = 90
