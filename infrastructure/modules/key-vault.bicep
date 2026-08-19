// Key Vault holding every application secret: the Postgres admin password and each app's
// full database connection string (so neither secret nor the apps that consume them ever
// need the raw password to appear in application settings, source control, or CI logs).
// RBAC authorization model — access is granted via Azure role assignments below, not
// legacy access policies.
@description('Globally-unique vault name (3-24 chars)')
param vaultName string

@description('Azure region for the vault')
param location string

@description('Azure AD tenant ID')
param tenantId string = subscription().tenantId

@description('PostgreSQL server FQDN, used to build the two app connection strings')
param postgresServerFqdn string

@description('PostgreSQL administrator login')
param postgresAdminUsername string

@secure()
@description('PostgreSQL administrator password — written into the vault, never elsewhere')
param postgresAdminPassword string

@description('Application Insights connection string, stored so either app can pick it up later without an infra change')
@secure()
param appInsightsConnectionString string

@description('AAD object ID of the principal running this deployment — granted Key Vault Secrets Officer so the deployment itself can write the secrets below')
param deployerPrincipalId string

@description('Principal IDs of the application managed identities — granted Key Vault Secrets User (read-only)')
param readerPrincipalIds array

@description('Tags applied to the vault')
param tags object = {}

var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

var intelligenceDatabaseUrl = 'postgresql+psycopg://${postgresAdminUsername}:${postgresAdminPassword}@${postgresServerFqdn}:5432/ai_commerce?sslmode=require'
var operationsDatabaseUrl = 'postgresql+psycopg://${postgresAdminUsername}:${postgresAdminPassword}@${postgresServerFqdn}:5432/commerce_operations?sslmode=require'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    accessPolicies: []
  }
}

resource deployerSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, deployerPrincipalId, keyVaultSecretsOfficerRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}

resource readerSecretsUserAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in readerPrincipalIds: {
    name: guid(vault.id, principalId, keyVaultSecretsUserRoleId)
    scope: vault
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource postgresAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-admin-password'
  properties: {
    value: postgresAdminPassword
  }
  dependsOn: [
    deployerSecretsOfficer
  ]
}

resource intelligenceDatabaseUrlSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'commerce-intelligence-database-url'
  properties: {
    value: intelligenceDatabaseUrl
  }
  dependsOn: [
    deployerSecretsOfficer
  ]
}

resource operationsDatabaseUrlSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'commerce-operations-database-url'
  properties: {
    value: operationsDatabaseUrl
  }
  dependsOn: [
    deployerSecretsOfficer
  ]
}

resource appInsightsConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'appinsights-connection-string'
  properties: {
    value: appInsightsConnectionString
  }
  dependsOn: [
    deployerSecretsOfficer
  ]
}

output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
output intelligenceDatabaseUrlSecretUri string = '${vault.properties.vaultUri}secrets/${intelligenceDatabaseUrlSecret.name}'
output operationsDatabaseUrlSecretUri string = '${vault.properties.vaultUri}secrets/${operationsDatabaseUrlSecret.name}'
output appInsightsConnectionStringSecretUri string = '${vault.properties.vaultUri}secrets/${appInsightsConnectionStringSecret.name}'
