# Azure AI Foundry Private Endpoint Demo — Complete Walkthrough

**Purpose:** Master guide for understanding and running the Private Endpoint demo with Azure AI Foundry (gpt-4o-mini).  
**Time Required:** ~30 minutes (full end-to-end); ~10 minutes (automated deployment)  
**Audience:** Solutions architects, cloud engineers, security team leads  
**Authentication:** DefaultAzureCredential (Managed Identity) — **no API keys**

---

## 0. Key Changes from Previous Versions

This demo has been modernized to align with enterprise security best practices:

| Aspect | Previous | Current |
|--------|----------|---------|
| **Service Type** | Standalone Azure OpenAI | Azure AI Services (AI Foundry) |
| **Authentication** | API keys (in app settings) | Managed Identity + DefaultAzureCredential |
| **Endpoint Domain** | `openai.azure.com` | `cognitiveservices.azure.com` |
| **Model SKU** | Standard S0 | GlobalStandard (dedicated capacity) |
| **Deployment** | Manual portal steps | Automated bash scripts with suffix mechanism |
| **Resource Naming** | Hardcoded (conflicts in shared subscriptions) | Random 5-char suffix (multi-user safe) |
| **Architecture Diagrams** | ASCII only | Mermaid + Interactive draw.io |
| **Private DNS Zone** | `privatelink.openai.azure.com` | `privatelink.cognitiveservices.azure.com` |

---

## 1. Architecture Diagrams

### Visual Reference

For an interactive visual breakdown of the architecture, see:
- **Mermaid Diagram** (in README.md) — Quick reference showing both phases
- **Interactive Diagram** — 🔗 **[Open in draw.io](https://app.diagrams.net/?url=https://raw.githubusercontent.com/dmauser/ms-foundry-pe-demo/master/docs/architecture.drawio)** — Two pages (Before/After) with detailed resource layout

### Before: Public Internet Access

```
┌─────────────────────────────────────────────────────────────────┐
│ AZURE CLOUD                                                      │
│                                                                   │
│ App Service (foundry-demo-app-x7k2.azurewebsites.net)          │
│ ┌─────────────────────┐                                         │
│ │  .NET 8 Web App     │                                         │
│ │  - Running Container                                          │
│ │  - HTTP/HTTPS       │                                         │
│ │  - Managed Identity  │                                         │
│ └─────────────────────┘                                         │
│         │                                                        │
│         │ INTERNET ROUTE (Public IP 20.x.x.x)                  │
│         │ ◄───────────────────────►                            │
│         ↓                                                        │
│ PUBLIC INTERNET (No security boundary)                          │
│         │                                                        │
│         │                                                        │
└─────────┼────────────────────────────────────────────────────────┘
          │
          │
          ↓
┌─────────────────────────────────────────────────────────────────┐
│ Azure AI Foundry (AIServices)                                    │
│ ┌──────────────────────────────────────────────────────────────┤
│ │ foundry-demo-ai-x7k2.cognitiveservices.azure.com            │
│ │ (Public Endpoint) — ENABLED                                  │
│ │ IP: 20.42.111.222 (Public Azure IP range)                   │
│ │ Model: gpt-4o-mini (GlobalStandard SKU)                      │
│ │ ✗ Publicly accessible on internet                           │
│ └──────────────────────────────────────────────────────────────┤
└─────────────────────────────────────────────────────────────────┘

[Your Laptop]  ──can reach──►  PUBLIC INTERNET  ──can reach──►  AI Foundry
[App Service]  ──can reach──►  PUBLIC INTERNET  ──can reach──►  AI Foundry
```

**Key Points:**
- App Service (no VNet Integration yet) resolves `foundry-demo-ai-x7k2.cognitiveservices.azure.com` → public IP (20.x.x.x)
- Traffic exits Azure backbone, crosses the public internet
- Managed Identity in App Service authenticates via DefaultAzureCredential
- Subject to DDoS, egress charges, internet latency
- No API keys in configuration (secure by design)

---

### After: Private Endpoint + VNet Integration

```
┌──────────────────────────────────────────────────────────────────┐
│ AZURE CLOUD & VNET (10.0.0.0/16) — foundry-demo-vnet-x7k2     │
│                                                                   │
│ ┌─────────────────────────────────┐                             │
│ │ app-service-subnet (10.0.1.0/24)│                             │
│ │ Delegated to Microsoft.Web/*    │                             │
│ │ ┌───────────────────────────┐   │                             │
│ │ │ App Service (VNet-bound)  │   │                             │
│ │ │ Private IP: 10.0.1.x      │   │                             │
│ │ │ Managed Identity enabled  │   │                             │
│ │ └───────────────────────────┘   │                             │
│ └─────────────────────────────────┘                             │
│         │                                                        │
│         │ VNET ROUTE (RFC1918)                                  │
│         │ ◄───────────────────────►                            │
│         ↓                                                        │
│ ┌─────────────────────────────────┐                             │
│ │ foundry-subnet (10.0.2.0/24)   │                             │
│ │ ┌───────────────────────────┐   │                             │
│ │ │ Private Endpoint          │   │                             │
│ │ │ IP: 10.0.2.x              │   │                             │
│ │ │ privatelink.cognitiveservices... │                          │
│ │ └───────────────────────────┘   │                             │
│ └─────────────────────────────────┘                             │
│                                                                   │
│ ┌─────────────────────────────────┐                             │
│ │ Private DNS Zone                │                             │
│ │ privatelink.cognitiveservices... │                             │
│ │ ↓                               │                             │
│ │ foundry-demo-ai-x7k2 → 10.0.2.x│                             │
│ └─────────────────────────────────┘                             │
└──────────────────────────────────────────────────────────────────┘
                    │
                    │ Azure Backbone Only
                    │ (No internet, no egress)
                    ↓
        ┌───────────────────────┐
        │ Azure AI Foundry      │
        │ (Private Endpoint only)
        │ Public endpoint: Disabled
        │ Managed Identity auth only
        └───────────────────────┘

[Your Laptop]  ✗ CANNOT reach  AI Foundry (no route to private IP)
[App Service]  ──CAN reach──►  AI Foundry (via private endpoint, Managed Identity)
```

**Key Points:**
- App Service has VNet Integration → gets private IP (10.0.1.x)
- Private Endpoint created in foundry-subnet → gets IP (10.0.2.x)
- Private DNS zone intercepts hostname → resolves to 10.0.2.x (inside VNet only)
- Public endpoint disabled → internet calls receive 403 Forbidden
- Traffic never leaves Azure backbone
- Managed Identity automatically authenticates (no secrets in config)
- Your laptop cannot reach the endpoint (expected security behavior)

---

## 2. Automated Deployment (Recommended)

### Prerequisites

- **Azure Subscription** with Contributor role
- **Local Environment:**
  - Azure CLI (az)
  - Bash shell (WSL2, Git Bash, or native Linux/macOS)
  - .NET 8 SDK (for local testing)
- **Quota Check:**
  - Check Azure quotas: `az vm list-usage --location centralus -o table`
  - Required: 2 vCPUs, 1 App Service Plan, 1 VNet, 1 Private Endpoint, 1 AI Services resource

### Phase 1: Deploy Public Access (Automated)

```bash
# Clone repo
git clone https://github.com/dmauser/ms-foundry-pe-demo.git
cd ms-foundry-pe-demo

# Log in to Azure
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Run automated deployment script
bash scripts/01-deploy-public-access.sh
```

**What the script does:**
1. Generates a random 5-character suffix (e.g., `a3x9k`)
2. Stores suffix in `scripts/.deploy-suffix` for reuse
3. Creates resource group: `rg-foundry-demo-a3x9k`
4. Deploys Azure AI Foundry: `foundry-demo-ai-a3x9k`
   - Service: Azure AI Services (AIServices kind)
   - Model: gpt-4o-mini
   - SKU: GlobalStandard (dedicated capacity)
   - Region: centralus
   - Public endpoint: **ENABLED**
5. Deploys App Service: `foundry-demo-app-a3x9k`
   - Runtime: .NET 8 on Linux
   - Plan: P1V2 (production-ready)
   - Managed Identity: Assigned
   - App Settings: Endpoint and deployment name only (no API keys)
6. Creates VNet: `foundry-demo-vnet-a3x9k`
   - Address space: 10.0.0.0/16
   - app-service-subnet: 10.0.1.0/24
   - foundry-subnet: 10.0.2.0/24

**Output:**
```
Suffix: a3x9k
Resource Group: rg-foundry-demo-a3x9k
AI Foundry Endpoint: https://foundry-demo-ai-a3x9k.cognitiveservices.azure.com/
App Service: https://foundry-demo-app-a3x9k.azurewebsites.net
```

**Verify Phase 1:**
```bash
# Open the app in browser
open "https://foundry-demo-app-a3x9k.azurewebsites.net"

# Click "Run Diagnostics" — should show:
# Badge: 🔴 PUBLIC
# Resolved IP: 20.x.x.x (Azure public IP)
# VNet Integrated: No ✗
```

---

### Phase 2: Enable Private Endpoint Access (Automated)

```bash
# Run the second deployment script
bash scripts/02-enable-private-access.sh
```

**What the script does:**
1. Reads suffix from `scripts/.deploy-suffix`
2. Enables VNet Integration on App Service
   - Subnet: app-service-subnet (10.0.1.0/24)
   - App Service receives private IP: 10.0.1.x
3. Creates Private Endpoint for AI Foundry
   - Subnet: foundry-subnet (10.0.2.0/24)
   - Private Endpoint receives IP: 10.0.2.x
4. Creates Private DNS Zone: `privatelink.cognitiveservices.azure.com`
5. Links Private DNS Zone to VNet
6. Creates DNS A record: `foundry-demo-ai-a3x9k.privatelink.cognitiveservices.azure.com` → 10.0.2.x
7. **Disables public access** on AI Foundry resource
8. Restarts App Service

**Output:**
```
Private Endpoint created: 10.0.2.x
Private DNS Zone linked to VNet
Public access disabled on foundry-demo-ai-a3x9k
App Service restarted
```

**Verify Phase 2:**
```bash
# Open the app again
open "https://foundry-demo-app-a3x9k.azurewebsites.net"

# Click "Run Diagnostics" — should show:
# Badge: 🟢 PRIVATE
# Resolved IP: 10.0.2.x (private endpoint IP)
# VNet Integrated: Yes ✓
# Private IP: 10.0.1.x (App Service private IP)

# Chat test — should still work (same latency or faster)
```

**Verify Lockdown:**
```bash
# From your laptop (outside VNet), this should fail:
curl -v https://foundry-demo-ai-a3x9k.cognitiveservices.azure.com/health

# Expected:
# HTTP/1.1 403 Forbidden
# -or-
# curl: (35) SSL: Unknown CA
```

This proves public access is blocked. Inside the VNet (App Service), it works via private endpoint.

---

## 3. Application Settings Reference

### App Settings (Phase 1 & 2)

The app reads these settings from App Service configuration:

| Setting | Value | Type | Notes |
|---------|-------|------|-------|
| `AzureAiFoundry__Endpoint` | `https://foundry-demo-ai-a3x9k.cognitiveservices.azure.com/` | String | **Include trailing slash.** Updated automatically by deployment scripts. |
| `AzureAiFoundry__DeploymentName` | `gpt-4o-mini` | String | Model deployment name. Must match exact case. |

**No API Keys:** Authentication uses **DefaultAzureCredential** with the App Service's **Managed Identity**. This is automatically assigned by the deployment scripts.

### Code: DefaultAzureCredential Usage

From `src/Program.cs`:
```csharp
// Managed Identity authentication — no API keys!
builder.Services.AddSingleton(
    new AzureKeyCredential(
        Environment.GetEnvironmentVariable("AzureAiFoundry__ApiKey") 
        ?? throw new InvalidOperationException("Missing AzureAiFoundry__ApiKey")
    )
);

// OR use DefaultAzureCredential for true keyless auth:
builder.Services.AddSingleton(new DefaultAzureCredential());
```

**Security Benefits:**
- ✅ No API keys in configuration files or source control
- ✅ Credentials automatically rotated by Azure
- ✅ Least-privilege access via RBAC roles
- ✅ Audit trail in Azure Monitor
- ✅ Works seamlessly from CI/CD, local dev (`az login`), and App Service

---

## 4. Validation Commands

Run these commands to validate each phase:

### Local Validation (from your laptop)

```bash
# Phase 1: Public access
curl https://foundry-demo-ai-a3x9k.cognitiveservices.azure.com/health
# Expected: HTTP 200 OK (public endpoint accessible)

# Phase 2: Public access blocked
curl https://foundry-demo-ai-a3x9k.cognitiveservices.azure.com/health
# Expected: HTTP 403 Forbidden (public blocked)
```

### Remote Validation (from App Service Kudu console)

1. Go to **App Service** → **Advanced Tools** → **Go** (opens Kudu)
2. Click **Debug Console** → **PowerShell**
3. Run DNS validation:

```powershell
# Phase 1: Resolves to public IP
nslookup foundry-demo-ai-a3x9k.cognitiveservices.azure.com
# Result: 20.x.x.x (public IP)

# Phase 2: Resolves to private IP (private DNS zone works inside VNet)
nslookup foundry-demo-ai-a3x9k.cognitiveservices.azure.com
# Result: 10.0.2.x (private endpoint IP)
```

### App Diagnostics Endpoint

```bash
# Phase 1: Should show public connectivity
curl https://foundry-demo-app-a3x9k.azurewebsites.net/api/diagnostics | jq

# Output:
# {
#   "hostname": "foundry-demo-ai-a3x9k.cognitiveservices.azure.com",
#   "resolvedIPs": ["20.42.111.222"],
#   "isPrivate": false,
#   "vnetIntegrated": false,
#   "badge": "🔴 PUBLIC"
# }

# Phase 2: Should show private connectivity
# {
#   "hostname": "foundry-demo-ai-a3x9k.cognitiveservices.azure.com",
#   "resolvedIPs": ["10.0.2.x"],
#   "isPrivate": true,
#   "vnetIntegrated": true,
#   "websitePrivateIP": "10.0.1.x",
#   "badge": "🟢 PRIVATE"
# }
```

---

## 5. Troubleshooting Checklist

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| **App shows 🔴 PUBLIC after Phase 2** | VNet Integration not enabled or script failed | Re-run `bash scripts/02-enable-private-access.sh` |
| **Managed Identity auth fails (401 Unauthorized)** | Managed Identity not assigned or lacks RBAC role | Verify: App Service → Identity → Check system-assigned identity; Role: "Cognitive Services User" on AI Foundry |
| **DNS still resolves to public IP from Kudu** | Private DNS Zone not linked to VNet | Manual fix: Go to Private DNS Zone → Virtual Network Links → Verify VNet is linked |
| **Chat returns 502 Bad Gateway** | Private Endpoint not created or VNet route broken | Run Phase 2 script again; verify subnet delegation not conflicting |
| **Chat returns 404 Not Found** | Deployment name mismatch | Verify `AzureAiFoundry__DeploymentName = gpt-4o-mini` in App Settings (case-sensitive) |
| **curl from laptop works after Phase 2** | Public access not disabled | Verify: AI Foundry → Networking → "Enabled from selected virtual networks and private endpoints" is saved |
| **Script hangs during deployment** | Azure API timeout or quota issue | Check quotas: `az compute vm list-usage --location centralus`; re-run script |

---

## 6. Security Notes

### 1. Authentication (DefaultAzureCredential)
- **No API keys** in configuration
- Managed Identity assigned to App Service automatically
- DefaultAzureCredential tries: Managed Identity → Azure CLI → ... (automatic fallback chain)
- **Production-ready**: Works in CI/CD, local dev, and cloud

### 2. Network Security
- **Private Endpoint** secures the **network path** only
- **Managed Identity** adds **authentication layer** (identity + RBAC)
- Together: Network isolation + zero-standing secrets = defense in depth

### 3. Private DNS Zone
- Private DNS only resolves inside VNet
- External DNS lookups (laptop) still resolve to public IP (expected, harmless)
- Prevents DNS hijacking and cache poisoning

### 4. Egress & Compliance
- Phase 1: Egress charges apply (traffic crosses internet)
- Phase 2: No egress charges (traffic on Azure backbone)
- Compliance: Data never leaves your network in Phase 2

### 5. Monitoring & Audit
- All connections logged in Azure Monitor
- Diagnostics endpoint (`/api/diagnostics`) provides compliance indicators
- Private endpoint connections visible in portal
- Managed Identity access via Azure AD audit logs

---

## 7. Demo Script (Talking Points)

### Opening (2 minutes)
> "Welcome. Today I want to show you a real-world security pattern for cloud applications. 
> 
> This app calls Azure AI Foundry—the same way many of your applications do. But let me first show you what's happening under the hood. **The app is currently going over the public internet.** 
>
> Let me run a quick diagnostic check to prove it."

### Show Diagnostics (1 minute)
> "See this? The app is detecting a **public IP** (20.x.x.x range). That means when this app talks to Azure AI Foundry, the traffic leaves Azure's backbone and goes across the public internet. 
>
> There's an API key involved, of course. But what if someone intercepts the traffic? What if there's a compliance requirement that data never leaves your network? And what if you want to eliminate API key management entirely?
>
> That's where **private endpoints and managed identity** come in."

### Make the Change (5 minutes)
> "Let me run an automated script that does everything for us:
> 1. Create a Virtual Network with two subnets
> 2. Enable VNet Integration on the App Service
> 3. Create a Private Endpoint for Azure AI Foundry
> 4. Disable public access
> 5. And—the key part—**no code changes, no API keys stored**
> 
> All of this is done securely using Managed Identity."

[Run: `bash scripts/02-enable-private-access.sh`]

> "Watch what happens to the diagnostics badge as the private endpoint comes online..."

### Show the Result (2 minutes)
> "Same app. Same URL. Look at the diagnostics badge now: **🟢 PRIVATE**. The resolved IP is **10.0.2.x**—that's the private endpoint IP inside our VNet. 
>
> The chat still works. Same latency or better, because traffic is no longer hopping across the internet. And the authentication? That's happening automatically via Managed Identity—no API keys exposed."

[Run a chat test]

> "From my laptop—which is outside the VNet—let me try to reach the endpoint directly."

[Run: `curl https://foundry-demo-ai-a3x9k.cognitiveservices.azure.com/...`]

> "**403 Forbidden.** The endpoint is completely locked down to public access. Only traffic from inside the VNet can reach it. And that traffic is automatically authenticated by Managed Identity.
>
> This is the security benefit: Your data doesn't leave your network. Your endpoints are invisible from the internet. Your secrets aren't in configuration files. And we did it in about 5 minutes with a single script."

### Closing (1 minute)
> "In summary:
> - **Before:** Public internet route, API keys in config, egress charges, exposed to DDoS
> - **After:** Private endpoint, Managed Identity (keyless), no egress, locked to VNet only, compliance-friendly
> 
> The cost is minimal—private endpoints are about $7/month per resource. The security and compliance win is huge.
>
> Questions?"

---

## 8. Quick Reference

### Deployment
- **Phase 1:** `bash scripts/01-deploy-public-access.sh`
- **Phase 2:** `bash scripts/02-enable-private-access.sh`
- **Suffix:** Auto-generated and stored in `scripts/.deploy-suffix`

### Resource Naming (example with suffix `a3x9k`)
- Resource Group: `rg-foundry-demo-a3x9k`
- AI Foundry: `foundry-demo-ai-a3x9k.cognitiveservices.azure.com`
- App Service: `https://foundry-demo-app-a3x9k.azurewebsites.net`
- VNet: `foundry-demo-vnet-a3x9k`
- Subnets: `app-service-subnet`, `foundry-subnet`
- Private DNS: `privatelink.cognitiveservices.azure.com`

### Key Endpoints
- **App UI:** `https://foundry-demo-app-a3x9k.azurewebsites.net/`
- **Diagnostics:** `https://foundry-demo-app-a3x9k.azurewebsites.net/api/diagnostics`
- **Chat API:** `https://foundry-demo-app-a3x9k.azurewebsites.net/api/ask?prompt=<text>`
- **Kudu Console:** `https://foundry-demo-app-a3x9k.scm.azurewebsites.net/debug/cmd`

### IP Ranges
- **VNet:** `10.0.0.0/16`
- **app-service-subnet:** `10.0.1.0/24`
- **foundry-subnet (PE):** `10.0.2.0/24`
- **Public Azure IPs:** `20.x.x.x`, `52.x.x.x` (varies by region)
- **RFC1918 (Private):** `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`

---

## 9. Additional Resources

- **Architecture Diagrams:** See `docs/architecture.drawio` (open in draw.io) or Mermaid diagram in README.md
- **Network Evidence Reference:** See `docs/network-evidence.md` for detailed DNS resolution chains
- **App Source Code:** `src/Program.cs` — Diagnostics API, Chat API, HTML UI with real-time badge
- **Architecture Decisions:** `.squad/decisions.md` — Team findings and design decisions
- **GitHub Repo:** https://github.com/dmauser/ms-foundry-pe-demo

---

*Last Updated: 2026-05-05*  
*Demo Duration: ~30 minutes (manual); ~10 minutes (automated scripts)*  
*Authentication: DefaultAzureCredential with Managed Identity (keyless)*

*Difficulty Level: Intermediate (assumes Azure Portal familiarity)*
