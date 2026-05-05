// Phase 1: Deploy Azure AI Foundry Demo with Public Access
// All Azure resources provisioned declaratively — no az CLI quirks.

@description('Unique suffix for globally unique resource names')
param suffix string

@description('Azure region for all resources')
param location string = 'centralus'

// --- Naming ---
var aiServicesName = 'foundry-demo-ai-${suffix}'
var appServicePlanName = 'foundry-demo-plan-${suffix}'
var webAppName = 'foundry-demo-app-${suffix}'
var vnetName = 'foundry-demo-vnet-${suffix}'
var deploymentName = 'gpt-4o-mini'

// --- Virtual Network ---
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'app-service-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'delegation-web'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'foundry-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// --- Azure AI Services ---
resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aiServicesName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: aiServicesName
    publicNetworkAccess: 'Enabled'
  }
}

// --- Model Deployment ---
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiServices
  name: deploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 1
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
  }
}

// --- App Service Plan ---
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  sku: {
    name: 'B1'
  }
  properties: {
    reserved: true
  }
}

// --- Web App ---
resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    virtualNetworkSubnetId: vnet.properties.subnets[0].id
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
      ]
    }
    httpsOnly: true
  }
}

// --- Role Assignment: Cognitive Services User ---
@description('Cognitive Services User role definition ID')
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServices.id, webApp.id, cognitiveServicesUserRoleId)
  scope: aiServices
  properties: {
    principalId: webApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

// --- Outputs ---
output webAppName string = webApp.name
output aiServicesEndpoint string = 'https://${aiServicesName}.cognitiveservices.azure.com/'
output resourceGroupName string = resourceGroup().name
