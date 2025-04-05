@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}


@secure()
param postgresDatabasePassword string
param msdocsFlaskPostgresqlSampleAppExists bool

@description('Id of the user or app to assign application roles')
param principalId string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Container registry
module containerRegistry 'br/public:avm/res/container-registry/registry:0.1.1' = {
  name: 'registry'
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    tags: tags
    publicNetworkAccess: 'Enabled'
    roleAssignments:[
      {
        principalId: msdocsFlaskPostgresqlSampleAppIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
    ]
  }
}

// Container apps environment
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.4.5' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
  }
}
var postgresDatabaseName = 'Outdoors'
var postgresDatabaseUser = 'psqladmin'
module postgresServer 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.1.4' = {
  name: 'postgresServer'
  params: {
    name: '${abbrs.dBforPostgreSQLServers}${resourceToken}'
    skuName: 'Standard_B1ms'
    tier: 'Burstable'
    administratorLogin: postgresDatabaseUser
    administratorLoginPassword: postgresDatabasePassword
    geoRedundantBackup: 'Disabled'
    passwordAuth:'Enabled'
    firewallRules: [
      {
        name: 'AllowAllIps'
        startIpAddress: '0.0.0.0'
        endIpAddress: '255.255.255.255'
      }
    ]
    databases: [
      {
        name: postgresDatabaseName
      }
    ]
    location: location
  }
}

module msdocsFlaskPostgresqlSampleAppIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'msdocsFlaskPostgresqlSampleAppidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}msdocsFlaskPostgresqlSampleApp-${resourceToken}'
    location: location
  }
}

module msdocsFlaskPostgresqlSampleAppFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'msdocsFlaskPostgresqlSampleApp-fetch-image'
  params: {
    exists: msdocsFlaskPostgresqlSampleAppExists
    name: 'msdocs-flask-postgresql-sample-app'
  }
}

module msdocsFlaskPostgresqlSampleApp 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'msdocsFlaskPostgresqlSampleApp'
  params: {
    name: 'msdocs-flask-postgresql-sample-app'
    ingressTargetPort: 80
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  [
        {
          name: 'postgres-password'
          value: postgresDatabasePassword
        }
        {
          name: 'db-url'
          value: 'postgresql://${postgresDatabaseUser}:${postgresDatabasePassword}@${postgresServer.outputs.fqdn}:5432/${postgresDatabaseName}'
        }
      ]
    }
    containers: [
      {
        image: msdocsFlaskPostgresqlSampleAppFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: [
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: msdocsFlaskPostgresqlSampleAppIdentity.outputs.clientId
          }
          {
            name: 'POSTGRES_HOST'
            value: postgresServer.outputs.fqdn
          }
          {
            name: 'POSTGRES_USERNAME'
            value: postgresDatabaseUser
          }
          {
            name: 'POSTGRES_DATABASE'
            value: postgresDatabaseName
          }
          {
            name: 'POSTGRES_PASSWORD'
            secretRef: 'postgres-password'
          }
          {
            name: 'POSTGRES_URL'
            secretRef: 'db-url'
          }
          {
            name: 'POSTGRES_PORT'
            value: '5432'
          }
          {
            name: 'AZURE_KEY_VAULT_NAME'
            value: keyVault.outputs.name
          }
          {
            name: 'AZURE_KEY_VAULT_ENDPOINT'
            value: keyVault.outputs.uri
          }
          {
            name: 'PORT'
            value: '80'
          }
        ]
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [msdocsFlaskPostgresqlSampleAppIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: msdocsFlaskPostgresqlSampleAppIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'msdocs-flask-postgresql-sample-app' })
  }
}
// Create a keyvault to store secrets
module keyVault 'br/public:avm/res/key-vault/vault:0.12.0' = {
  name: 'keyvault'
  params: {
    name: '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
    accessPolicies: [
      {
        objectId: principalId
        permissions: {
          secrets: [ 'get', 'list', 'set' ]
        }
      }
      {
        objectId: msdocsFlaskPostgresqlSampleAppIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
    secrets: [
      {
        name: 'postgres-password'
        value: postgresDatabasePassword
      }
    ]
  }
}
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_RESOURCE_MSDOCS_FLASK_POSTGRESQL_SAMPLE_APP_ID string = msdocsFlaskPostgresqlSampleApp.outputs.resourceId
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output AZURE_RESOURCE_VAULT_ID string = keyVault.outputs.resourceId
output AZURE_RESOURCE_OUTDOORS_ID string = '${postgresServer.outputs.resourceId}/databases/Outdoors'
