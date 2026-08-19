// User-assigned managed identities, one per application.
// Created before ACR/Key Vault/Storage so their principal IDs can be granted access
// (AcrPull, Key Vault Secrets User, Storage Blob Data Contributor) BEFORE the container
// apps that use them are created — avoids the create-then-grant race that system-assigned
// identities hit when a Container App needs registry/secret access at creation time.
@description('Azure region for the identities')
param location string

@description('Tags applied to both identities')
param tags object = {}

resource intelligenceIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-commerce-intelligence-api'
  location: location
  tags: tags
}

resource operationsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-commerce-operations-api'
  location: location
  tags: tags
}

output intelligenceIdentityId string = intelligenceIdentity.id
output intelligenceIdentityPrincipalId string = intelligenceIdentity.properties.principalId
output intelligenceIdentityClientId string = intelligenceIdentity.properties.clientId
output operationsIdentityId string = operationsIdentity.id
output operationsIdentityPrincipalId string = operationsIdentity.properties.principalId
output operationsIdentityClientId string = operationsIdentity.properties.clientId
