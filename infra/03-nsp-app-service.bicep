// Scenario 2 — Step A: Deploy a second App Service (NO VNet Integration)
// that reaches the EXISTING Scenario 1 Foundry over its public endpoint using
// its own system-assigned managed identity. At this point the Foundry is still
// public, so both the laptop and this App Service can call it. Step B (NSP)
// then locks the Foundry down to identity-based access only.

@description('Unique suffix — must match the Scenario 1 (01-*) deployment')
param suffix string

@description('Azure region for all resources')
param location string = 'centralus'

// --- Naming ---
var aiServicesName = 'foundry-demo-ai-${suffix}'
var appServicePlanName = 'foundry-demo-plan-${suffix}'
var nspWebAppName = 'foundry-demo-nsp-app-${suffix}'
var deploymentName = 'gpt-4o-mini'

// --- References to existing Scenario 1 resources ---
resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aiServicesName
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' existing = {
  name: appServicePlanName
}

// --- Second Web App (NSP scenario) — intentionally NOT VNet integrated ---
resource nspWebApp 'Microsoft.Web/sites@2023-12-01' = {
  name: nspWebAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      appSettings: [
        {
          name: 'AzureOpenAI__Endpoint'
          value: 'https://${aiServicesName}.cognitiveservices.azure.com/'
        }
        {
          name: 'AzureOpenAI__DeploymentName'
          value: deploymentName
        }
        {
          name: 'AzureOpenAI__UseSystemAssignedIdentity'
          value: 'true'
        }
        {
          // Switches the embedded UI to the Network Security Perimeter view.
          name: 'Demo__Scenario'
          value: 'NSP'
        }
      ]
    }
    httpsOnly: true
  }
}

// --- Role Assignment: Cognitive Services User on the existing Foundry ---
@description('Cognitive Services User role definition ID')
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServices.id, nspWebApp.id, cognitiveServicesUserRoleId)
  scope: aiServices
  properties: {
    principalId: nspWebApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

// --- Outputs ---
output nspWebAppName string = nspWebApp.name
output aiServicesEndpoint string = 'https://${aiServicesName}.cognitiveservices.azure.com/'
output resourceGroupName string = resourceGroup().name
