// Phase 2: Enable Private Access for Azure AI Services
// Adds private endpoint, private DNS zone, and disables public access.

@description('Unique suffix for resource names (must match Phase 1)')
param suffix string

@description('Azure region for all resources')
param location string = 'centralus'

// --- Naming (derived from suffix) ---
var aiServicesName = 'foundry-demo-ai-${suffix}'
var vnetName = 'foundry-demo-vnet-${suffix}'
var privateEndpointName = 'pe-${aiServicesName}'
var dnsZoneName = 'privatelink.cognitiveservices.azure.com'

// --- References to existing resources ---
resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aiServicesName
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}

resource foundrySubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'foundry-subnet'
}

// --- Private Endpoint ---
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: foundrySubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-conn'
        properties: {
          privateLinkServiceId: aiServices.id
          groupIds: ['account']
        }
      }
    ]
  }
}

// --- Private DNS Zone ---
resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
}

// --- VNet Link ---
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// --- DNS Zone Group (auto-registers PE IP in DNS zone) ---
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

// --- Disable Public Access on AI Services ---
resource aiServicesUpdate 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aiServicesName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: aiServicesName
    publicNetworkAccess: 'Disabled'
  }
}

// --- Outputs ---
output privateEndpointName string = privateEndpoint.name
output dnsZoneName string = dnsZone.name
