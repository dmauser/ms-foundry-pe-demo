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

@description('Retention (days) for the NSP access-log Log Analytics workspace')
param logRetentionDays int = 30

// --- Naming ---
var aiServicesName = 'foundry-demo-ai-${suffix}'
var nspName = 'foundry-demo-nsp-${suffix}'
var profileName = 'foundry-demo-nsp-profile'
var inboundRuleName = 'allow-subscription-identities'
var associationName = 'foundry-assoc'
var lawName = 'foundry-demo-law-${suffix}'

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

// --- Log Analytics workspace: destination for NSP access logs (proof) ---
// centralus is an Azure Monitor supported region. The workspace lives OUTSIDE
// the perimeter here (fine for a demo); for production you may add the
// workspace to the same NSP so the telemetry path is protected too.
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
  }
}

// --- Diagnostic setting: stream ALL NSP access evaluations to the workspace ---
// IMPORTANT: Network Security Perimeter does NOT support the 'allLogs' category
// group. A diagnostic setting using categoryGroup 'allLogs' is accepted by ARM
// but collects NOTHING (the NSP categories are not members of any group), so the
// workspace stays empty. You MUST enable each NSP log category explicitly.
// These categories capture every inbound/outbound access decision (Approved and
// Denied) into the resource-specific NSPAccessLogs table. This is the PROOF the
// perimeter is enforcing: the laptop (user token) lands as ResultAction 'Denied'
// (NspPublicInboundResourceRulesDenied); the App Service managed identity as
// 'Approved' (NspPublicInboundResourceRulesAllowed).
// Note: 'Dedicated' (logAnalyticsDestinationType) does not persist on NSP
// diagnostic settings; NSP access logs are resource-specific and always land in
// the NSPAccessLogs table regardless, so it is intentionally omitted here.
var nspLogCategories = [
  'NspPublicInboundPerimeterRulesAllowed'
  'NspPublicInboundPerimeterRulesDenied'
  'NspPublicOutboundPerimeterRulesAllowed'
  'NspPublicOutboundPerimeterRulesDenied'
  'NspIntraPerimeterInboundAllowed'
  'NspPublicInboundResourceRulesAllowed'
  'NspPublicInboundResourceRulesDenied'
  'NspPublicOutboundResourceRulesAllowed'
  'NspPublicOutboundResourceRulesDenied'
  'NspPrivateInboundAllowed'
  'NspCrossPerimeterOutboundAllowed'
  'NspCrossPerimeterInboundAllowed'
  'NspOutboundAttempt'
]
resource nspDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'nsp-access-logs'
  scope: nsp
  properties: {
    workspaceId: law.id
    logs: [for category in nspLogCategories: {
      category: category
      enabled: true
    }]
  }
}

// --- Outputs ---
output networkSecurityPerimeterName string = nsp.name
output profileName string = nspProfile.name
output logAnalyticsWorkspaceName string = law.name
output logAnalyticsWorkspaceResourceId string = law.id
