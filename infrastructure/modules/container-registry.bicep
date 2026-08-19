// Azure Container Registry (Basic SKU — cheapest tier, sufficient for two low-traffic
// dev repos) with admin user disabled. Pulls are authenticated via the AcrPull role
// granted to each application's user-assigned managed identity, not shared credentials.
@description('Globally-unique registry name (alphanumeric only, 5-50 chars)')
param registryName string

@description('Azure region for the registry')
param location string

@description('Principal IDs of the managed identities that need to pull images')
param pullPrincipalIds array

@description('Tags applied to the registry')
param tags object = {}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource acrPullAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in pullPrincipalIds: {
    name: guid(registry.id, principalId, acrPullRoleId)
    scope: registry
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output loginServer string = registry.properties.loginServer
output registryName string = registry.name
output registryId string = registry.id
