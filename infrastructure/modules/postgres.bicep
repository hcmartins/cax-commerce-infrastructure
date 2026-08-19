// Azure Database for PostgreSQL Flexible Server, Burstable tier (cheapest SKU family),
// with one database per application on a single shared server.
//
// SECURITY (temporary DEV compromise, documented per Phase 2 requirements):
// This server has a public endpoint. No VNET/private endpoint is used, because a
// Consumption-plan Container Apps Environment has no fixed outbound IP range to scope a
// private-networking rule to, and adding one would mean a delegated subnet + private DNS
// zone — the "complex networking" this phase is explicitly scoped to avoid for an MVP.
// Firewall access is limited to:
//   1. Azure-internal services only (not the open internet) via the special
//      0.0.0.0-0.0.0.0 "AllowAllAzureServicesAndResourcesWithinAzureIps" rule.
//   2. Optionally, one caller IP (clientIpAddress) so migrations can be run from a
//      developer/CI machine.
// Before production, replace this with VNET integration + private DNS, or at minimum
// remove the AllowAllAzureServices rule in favour of Container Apps VNET integration.
@description('Globally-unique server name')
param serverName string

@description('Azure region for the server')
param location string

@description('Administrator login name (must not be a reserved name like "admin")')
param administratorLogin string

@secure()
@description('Administrator login password')
param administratorLoginPassword string

@description('Compute SKU, e.g. Standard_B1ms (Burstable, cheapest tier)')
param skuName string = 'Standard_B1ms'

@description('Storage size in GiB (32 is the minimum)')
param storageSizeGb int = 32

@description('PostgreSQL major version')
param postgresVersion string = '16'

@description('Optional single caller IP address to allow through the firewall, e.g. for running migrations from a dev machine. Leave empty to skip.')
param clientIpAddress string = ''

@description('Database names to create on this server')
param databaseNames array = [
  'ai_commerce'
  'commerce_operations'
]

@description('Tags applied to the server')
param tags object = {}

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: 'Burstable'
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    storage: {
      storageSizeGB: storageSizeGb
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource databases 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = [
  for dbName in databaseNames: {
    parent: server
    name: dbName
    properties: {
      charset: 'UTF8'
      collation: 'en_US.utf8'
    }
  }
]

resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: server
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource allowClientIp 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = if (!empty(clientIpAddress)) {
  parent: server
  name: 'AllowDeploymentClient'
  properties: {
    startIpAddress: clientIpAddress
    endIpAddress: clientIpAddress
  }
}

output serverName string = server.name
output serverFqdn string = server.properties.fullyQualifiedDomainName
