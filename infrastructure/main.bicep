// Phase 2 — Azure DEV environment for commerce-intelligence and commerce-operations.
//
// Subscription-scoped so the resource group itself is part of the recreatable IaC: running
// this template from scratch (given a Postgres admin password and a deployer object ID)
// reproduces the whole environment.
//
// Bootstrap note: on a first-ever deployment, ACR has no images yet. intelligenceApiImage /
// operationsApiImage default to a small public placeholder image so the Container Apps can
// be created; scripts/deploy-dev.sh then builds+pushes the real images and points each
// Container App at them with `az containerapp update`. See README.md.
targetScope = 'subscription'

@description('Environment name — controls resource group and resource naming')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Azure region for all resources')
param location string = 'uksouth'

@description('Resource group name. Defaults to rg-commerce-<environmentName>.')
param resourceGroupName string = 'rg-commerce-${environmentName}'

@description('PostgreSQL administrator login name')
param postgresAdminUsername string = 'commerceadmin'

@secure()
@description('PostgreSQL administrator password. Never defaulted or committed — supply via CLI parameter override.')
param postgresAdminPassword string

@description('PostgreSQL compute SKU (Burstable family — cheapest tier)')
param postgresSkuName string = 'Standard_B1ms'

@description('PostgreSQL storage size in GiB')
param postgresStorageSizeGb int = 32

@description('Optional single caller IP allowed through the Postgres firewall, e.g. for running migrations from a dev/CI machine. Leave empty to skip.')
param clientIpAddress string = ''

@description('AAD object ID of the principal running this deployment (az ad signed-in-user show --query id -o tsv). Granted rights to write Key Vault secrets.')
param deployerPrincipalId string

@description('Container image for the commerce-intelligence API. Defaults to a placeholder until the real image is pushed to ACR.')
param intelligenceApiImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Container image for the commerce-operations API. Defaults to a placeholder until the real image is pushed to ACR.')
param operationsApiImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Minimum replicas per Container App (0 = scale-to-zero)')
param containerAppMinReplicas int = 0

@description('Maximum replicas per Container App')
param containerAppMaxReplicas int = 1

@description('Monthly cost budget amount for the resource group, in the subscription\'s billing currency')
param budgetAmount int = 50

@description('Email addresses notified by the cost budget')
param budgetContactEmails array

@description('Log Analytics retention in days')
param logAnalyticsRetentionDays int = 30

var namePrefix = 'commerce-${environmentName}'
var resourceToken = toLower(substring(uniqueString(subscription().id, resourceGroupName, environmentName), 0, 6))
var tags = {
  application: 'commerce-platform'
  environment: environmentName
  'managed-by': 'bicep'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    namePrefix: namePrefix
    location: location
    retentionInDays: logAnalyticsRetentionDays
    tags: tags
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  scope: rg
  params: {
    location: location
    tags: tags
  }
}

module containerRegistry 'modules/container-registry.bicep' = {
  name: 'container-registry'
  scope: rg
  params: {
    registryName: 'acrcommerce${environmentName}${resourceToken}'
    location: location
    pullPrincipalIds: [
      identity.outputs.intelligenceIdentityPrincipalId
      identity.outputs.operationsIdentityPrincipalId
    ]
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    storageAccountName: 'stcommerce${environmentName}${resourceToken}'
    location: location
    dataContributorPrincipalIds: [
      identity.outputs.intelligenceIdentityPrincipalId
      identity.outputs.operationsIdentityPrincipalId
    ]
    tags: tags
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  scope: rg
  params: {
    serverName: 'psql-commerce-${environmentName}-${resourceToken}'
    location: location
    administratorLogin: postgresAdminUsername
    administratorLoginPassword: postgresAdminPassword
    skuName: postgresSkuName
    storageSizeGb: postgresStorageSizeGb
    clientIpAddress: clientIpAddress
    tags: tags
  }
}

module keyVault 'modules/key-vault.bicep' = {
  name: 'key-vault'
  scope: rg
  params: {
    vaultName: 'kv-commerce-${environmentName}-${resourceToken}'
    location: location
    postgresServerFqdn: postgres.outputs.serverFqdn
    postgresAdminUsername: postgresAdminUsername
    postgresAdminPassword: postgresAdminPassword
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    deployerPrincipalId: deployerPrincipalId
    readerPrincipalIds: [
      identity.outputs.intelligenceIdentityPrincipalId
      identity.outputs.operationsIdentityPrincipalId
    ]
    tags: tags
  }
}

module containerApps 'modules/container-apps.bicep' = {
  name: 'container-apps'
  scope: rg
  params: {
    location: location
    environmentName: 'cae-${namePrefix}'
    logAnalyticsCustomerId: monitoring.outputs.logAnalyticsCustomerId
    logAnalyticsSharedKey: monitoring.outputs.logAnalyticsSharedKey
    registryLoginServer: containerRegistry.outputs.loginServer
    minReplicas: containerAppMinReplicas
    maxReplicas: containerAppMaxReplicas
    tags: tags
    apps: [
      {
        name: 'commerce-intelligence-api'
        image: intelligenceApiImage
        targetPort: 8000
        identityResourceId: identity.outputs.intelligenceIdentityId
        secrets: [
          {
            name: 'database-url'
            keyVaultUrl: keyVault.outputs.intelligenceDatabaseUrlSecretUri
          }
          {
            name: 'appinsights-connection-string'
            keyVaultUrl: keyVault.outputs.appInsightsConnectionStringSecretUri
          }
        ]
        env: [
          { name: 'APP_ENV', value: environmentName }
          { name: 'APP_NAME', value: 'Commerce Intelligence' }
          { name: 'API_V1_PREFIX', value: '/api/v1' }
          { name: 'LOG_LEVEL', value: 'INFO' }
          { name: 'LOG_JSON', value: 'true' }
          { name: 'DATABASE_URL', secretRef: 'database-url' }
          { name: 'AI_PROVIDER', value: 'mock' }
          { name: 'SEARCH_PROVIDER', value: 'mock' }
          { name: 'SUPPLIER_PROVIDER', value: 'mock' }
          { name: 'MARKETPLACE_PROVIDER', value: 'mock' }
          { name: 'WEB_CONCURRENCY', value: '1' }
          { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
        ]
      }
      {
        name: 'commerce-operations-api'
        image: operationsApiImage
        targetPort: 8000
        identityResourceId: identity.outputs.operationsIdentityId
        secrets: [
          {
            name: 'database-url'
            keyVaultUrl: keyVault.outputs.operationsDatabaseUrlSecretUri
          }
          {
            name: 'appinsights-connection-string'
            keyVaultUrl: keyVault.outputs.appInsightsConnectionStringSecretUri
          }
        ]
        env: [
          // The app's Settings model only allows local|test|staging|production (no "dev"
          // literal) — "staging" is the closest fit for a deployed-but-not-production
          // environment. See infrastructure/README.md.
          { name: 'COMMERCE_ENVIRONMENT', value: 'staging' }
          { name: 'COMMERCE_DEBUG', value: 'false' }
          { name: 'COMMERCE_LOG_LEVEL', value: 'INFO' }
          { name: 'COMMERCE_DATABASE_URL', secretRef: 'database-url' }
          { name: 'COMMERCE_CORS_ORIGINS', value: '[]' }
          // DEV-only: matches the app's own local default. No API keys are provisioned in
          // this phase, so leaving auth off is what makes /health, /ready and smoke tests
          // reachable without a credential. Documented in the completion report.
          { name: 'COMMERCE_API_AUTH_ENABLED', value: 'false' }
          { name: 'COMMERCE_METRICS_ENABLED', value: 'true' }
          { name: 'COMMERCE_DEMO_MODE', value: 'false' }
          { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
        ]
      }
    ]
  }
}

module budget 'modules/budget.bicep' = {
  name: 'budget'
  scope: rg
  params: {
    budgetName: 'budget-${namePrefix}'
    amount: budgetAmount
    contactEmails: budgetContactEmails
  }
}

output resourceGroupName string = rg.name
output acrLoginServer string = containerRegistry.outputs.loginServer
output acrName string = containerRegistry.outputs.registryName
output postgresServerFqdn string = postgres.outputs.serverFqdn
output postgresServerName string = postgres.outputs.serverName
output keyVaultName string = keyVault.outputs.vaultName
output storageAccountName string = storage.outputs.storageAccountName
output logAnalyticsWorkspaceCustomerId string = monitoring.outputs.logAnalyticsCustomerId
output appInsightsName string = monitoring.outputs.appInsightsName
output containerAppFqdns array = containerApps.outputs.appFqdns
output intelligenceIdentityClientId string = identity.outputs.intelligenceIdentityClientId
output operationsIdentityClientId string = identity.outputs.operationsIdentityClientId
