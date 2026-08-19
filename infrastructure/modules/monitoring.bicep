// Log Analytics workspace + workspace-based Application Insights.
// Workspace-based App Insights shares the same underlying Log Analytics store as the
// Container Apps Environment's console log stream, so container stdout/stderr is queryable
// from either resource without adding an OpenTelemetry/App Insights SDK to either app.
@description('Base name used to derive resource names, e.g. commerce-dev')
param namePrefix string

@description('Azure region for both resources')
param location string

@description('Log retention in days. Kept short in dev to minimise ingestion/retention cost.')
param retentionInDays int = 30

@description('Tags applied to both resources')
param tags object = {}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      disableLocalAuth: false
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${namePrefix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsCustomerId string = logAnalytics.properties.customerId
@secure()
output logAnalyticsSharedKey string = logAnalytics.listKeys().primarySharedKey
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
