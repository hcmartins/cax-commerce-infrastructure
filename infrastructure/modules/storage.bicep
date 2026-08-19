// Storage account for the three blob containers the applications' Phase 1 docs describe:
// raw workflow/run outputs, exports, and marketplace listing assets. Standard_LRS is the
// cheapest redundancy tier appropriate for dev/MVP data that isn't yet business-critical.
@description('Globally-unique storage account name (lowercase alphanumeric only, 3-24 chars)')
param storageAccountName string

@description('Azure region for the storage account')
param location string

@description('Principal IDs of the managed identities that need blob read/write access')
param dataContributorPrincipalIds array

@description('Tags applied to the storage account')
param tags object = {}

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var containerNames = [
  'raw-outputs'
  'exports'
  'listing-assets'
]

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = [
  for containerName in containerNames: {
    parent: blobService
    name: containerName
    properties: {
      publicAccess: 'None'
    }
  }
]

resource blobDataContributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in dataContributorPrincipalIds: {
    name: guid(storageAccount.id, principalId, storageBlobDataContributorRoleId)
    scope: storageAccount
    properties: {
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        storageBlobDataContributorRoleId
      )
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output storageAccountName string = storageAccount.name
output primaryBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
