// Scenario 2 — Step B: Lock the EXISTING Scenario 1 Foundry behind a
// Network Security Perimeter (NSP) using an identity-based inbound rule.
//
// The perimeter is created in Enforced mode with a single "Subscriptions"
// inbound access rule. Per Azure NSP semantics, a Subscriptions rule
// "allows inbound access authenticated using any managed identity from the
// subscription" — so the App Service (system-assigned managed identity in
// this subscription) is permitted, while a laptop using a user (az login)
// token is denied. The Foundry endpoint stays public in DNS; the security
// boundary is at the IDENTITY layer, not the network layer.

@description('Unique suffix — must match the Scenario 1 (01-*) deployment')
param suffix string

@description('Azure region for all resources')
param location string = 'centralus'

@description('Subscription id (ARM id format) allowed inbound via managed identity. Defaults to the deployment subscription.')
param allowedSubscriptionResourceId string = subscription().id

// --- Naming ---
var aiServicesName = 'foundry-demo-ai-${suffix}'
var nspName = 'foundry-demo-nsp-${suffix}'
var profileName = 'foundry-demo-nsp-profile'
var inboundRuleName = 'allow-subscription-identities'
var associationName = 'foundry-assoc'

// --- Reference to existing Scenario 1 Foundry ---
resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aiServicesName
}

// --- Network Security Perimeter ---
resource nsp 'Microsoft.Network/networkSecurityPerimeters@2024-07-01' = {
  name: nspName
  location: location
  properties: {}
}

// --- Profile ---
resource nspProfile 'Microsoft.Network/networkSecurityPerimeters/profiles@2024-07-01' = {
  parent: nsp
  name: profileName
  properties: {}
}

// --- Inbound access rule: identity-based (Subscriptions) ---
resource inboundRule 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2024-07-01' = {
  parent: nspProfile
  name: inboundRuleName
  properties: {
    direction: 'Inbound'
    subscriptions: [
      {
        id: allowedSubscriptionResourceId
      }
    ]
  }
}

// --- Resource association: put the Foundry inside the perimeter (Enforced) ---
resource association 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2024-07-01' = {
  parent: nsp
  name: associationName
  properties: {
    privateLinkResource: {
      id: aiServices.id
    }
    profile: {
      id: nspProfile.id
    }
    accessMode: 'Enforced'
  }
  dependsOn: [
    inboundRule
  ]
}

// --- Outputs ---
output networkSecurityPerimeterName string = nsp.name
output profileName string = nspProfile.name
