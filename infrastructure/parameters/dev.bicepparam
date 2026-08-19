using '../main.bicep'

// postgresAdminPassword, deployerPrincipalId, and clientIpAddress are intentionally NOT set
// here — they are secret, machine-specific, or both, and are supplied at deploy time via
// `--parameters` CLI overrides in scripts/deploy-dev.sh. Never hard-code them in this file.

param environmentName = 'dev'
param location = 'uksouth'

param postgresAdminUsername = 'commerceadmin'
param postgresSkuName = 'Standard_B1ms'
param postgresStorageSizeGb = 32

param intelligenceApiImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param operationsApiImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

param containerAppMinReplicas = 0
param containerAppMaxReplicas = 1

param budgetAmount = 50
param budgetContactEmails = [
  'hcaxtonmartins@gmail.com'
]

param logAnalyticsRetentionDays = 30
