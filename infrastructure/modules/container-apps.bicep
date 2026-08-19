// Consumption-plan Container Apps Environment (no dedicated VNET/workload profile — the
// cheapest option, appropriate since neither app needs one for an MVP) plus the two API
// container apps, both scale-to-zero. UI/worker/dashboard processes are intentionally out
// of scope for this phase; only each application's backend API is deployed.
@description('Azure region for the environment and apps')
param location string

@description('Name for the Container Apps Environment')
param environmentName string

@description('Log Analytics workspace customer ID (for the environment\'s log destination)')
param logAnalyticsCustomerId string

@secure()
@description('Log Analytics workspace shared key')
param logAnalyticsSharedKey string

@description('Container registry login server, e.g. myacr.azurecr.io')
param registryLoginServer string

@description('Minimum replicas per app (0 enables scale-to-zero)')
param minReplicas int = 0

@description('Maximum replicas per app')
param maxReplicas int = 1

@description('Per-app definitions to deploy as container apps')
param apps array

@description('Tags applied to the environment and apps')
param tags object = {}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource containerApps 'Microsoft.App/containerApps@2024-03-01' = [
  for app in apps: {
    name: app.name
    location: location
    tags: tags
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${app.identityResourceId}': {}
      }
    }
    properties: {
      managedEnvironmentId: environment.id
      workloadProfileName: 'Consumption'
      configuration: {
        activeRevisionsMode: 'Single'
        ingress: {
          external: true
          targetPort: app.targetPort
          transport: 'auto'
          allowInsecure: false
        }
        registries: [
          {
            server: registryLoginServer
            identity: app.identityResourceId
          }
        ]
        secrets: [
          for secret in app.secrets: {
            name: secret.name
            keyVaultUrl: secret.keyVaultUrl
            identity: app.identityResourceId
          }
        ]
      }
      template: {
        containers: [
          {
            name: app.name
            image: app.image
            resources: {
              cpu: json('0.5')
              memory: '1Gi'
            }
            env: app.env
          }
        ]
        scale: {
          minReplicas: minReplicas
          maxReplicas: maxReplicas
        }
      }
    }
  }
]

output appFqdns array = [
  for (app, i) in apps: {
    name: app.name
    fqdn: containerApps[i].properties.configuration.ingress.fqdn
  }
]
output environmentId string = environment.id
