// Scenario 3 (ms-foundry-pe-demo) — VNet-integrated test WebApp.
//
// This is the ONLY client that can reach the private, network-injected Foundry
// agent. It is deployed on the delegated `app-subnet` with regional VNet
// integration (vnetRouteAllEnabled=true) so all outbound traffic — including the
// call to the private Foundry project endpoint and the private data stores —
// stays inside the VNet and resolves via the linked Private DNS zones.
//
// The site's system-assigned managed identity is granted the data-plane roles
// needed to create and run agents (and upload File Search files) against the
// project: Cognitive Services User + Azure AI User, scoped to the account (roles
// cascade to the child project).

@description('Azure region for the deployment')
param location string

@description('Unique suffix for resource names (matches the deployment RG suffix)')
param suffix string

@description('Resource ID of the delegated app-subnet for regional VNet integration')
param appSubnetId string

@description('The Foundry (Cognitive Services AIServices) account name to grant the WebApp data-plane access on')
param accountName string

@description('The private Foundry project endpoint (https://<account>.services.ai.azure.com/api/projects/<project>)')
param projectEndpoint string

@description('The Foundry account endpoint')
param accountEndpoint string

@description('The project name')
param projectName string

@description('The model deployment name the agent uses')
param modelDeployment string

@description('The AI Search service name backing the app-side RAG grounding index')
param aiSearchName string

@description('App Service plan SKU')
param appServiceSku string = 'B1'

var planName = 'foundry-demo-agent-plan-${suffix}'
var siteName = 'foundry-demo-agent-app-${suffix}'

// Built-in role definition IDs (data-plane agent usage)
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
// 53ca6127... = "Foundry User" (formerly "Azure AI User") — grants create/run
// of agents and File Search uploads against the project.
var azureAiUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
// Reader — control-plane read of the account's publicNetworkAccess for the
// Foundry status panel (/api/foundry-status).
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// 8ebe5a00... = "Search Index Data Contributor" — lets the WebApp MI read/write
// documents on the private AI Search grounding index (app-side RAG queries + upload).
var searchIndexDataContributorRoleId = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
// 7ca78c08... = "Search Service Contributor" — lets the WebApp MI create/manage the
// grounding index schema on the private AI Search (needed by /api/seed).
var searchServiceContributorRoleId = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: appServiceSku
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: siteName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: appSubnetId
    vnetRouteAllEnabled: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      alwaysOn: true
      appSettings: [
        {
          name: 'Demo__Scenario'
          value: 'Agent'
        }
        {
          // Reused by /api/diagnostics (DNS of the private account FQDN) and
          // /api/foundry-status (control-plane publicNetworkAccess read).
          name: 'AzureOpenAI__Endpoint'
          value: accountEndpoint
        }
        {
          name: 'AzureOpenAI__ResourceId'
          value: account.id
        }
        {
          name: 'Agent__ProjectEndpoint'
          value: projectEndpoint
        }
        {
          name: 'Agent__AccountEndpoint'
          value: accountEndpoint
        }
        {
          name: 'Agent__ProjectName'
          value: projectName
        }
        {
          name: 'Agent__ModelDeployment'
          value: modelDeployment
        }
        {
          // app-side RAG grounding: the WebApp queries this PRIVATE AI Search over the
          // private endpoint, injects the matching manual excerpts, and asks the agent.
          name: 'Agent__SearchEndpoint'
          value: 'https://${aiSearchName}.search.windows.net'
        }
        {
          name: 'Agent__SearchIndexName'
          value: 'manuals-idx'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
      ]
    }
  }
}

// Reference the account so we can scope data-plane role assignments to it.
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

// Reference the private AI Search service to scope the RAG data-plane role.
resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = {
  name: aiSearchName
}

resource searchIndexDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, site.id, searchIndexDataContributorRoleId)
  scope: searchService
  properties: {
    principalId: site.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource searchServiceContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, site.id, searchServiceContributorRoleId)
  scope: searchService
  properties: {
    principalId: site.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource cognitiveServicesUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, site.id, cognitiveServicesUserRoleId)
  scope: account
  properties: {
    principalId: site.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource azureAiUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, site.id, azureAiUserRoleId)
  scope: account
  properties: {
    principalId: site.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, site.id, readerRoleId)
  scope: account
  properties: {
    principalId: site.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalType: 'ServicePrincipal'
  }
}

output webAppName string = site.name
output webAppUrl string = 'https://${site.properties.defaultHostName}'
output webAppPrincipalId string = site.identity.principalId
