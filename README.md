# 🔒 Azure AI Foundry — Network Security Demo (Private Endpoint & Network Security Perimeter)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![.NET 8](https://img.shields.io/badge/.NET-8.0-blue)](https://dotnet.microsoft.com/download/dotnet/8.0)
[![Azure Foundry](https://img.shields.io/badge/Azure-AI%20Foundry-0078D4)](https://azure.microsoft.com/en-us/products/ai-services/foundry/)

**A hands-on demo proving two different ways to secure access to Azure AI Foundry models — with zero API keys.**

This repository demonstrates two complementary security patterns against the **same** Azure AI Foundry resource:

- **Scenario 1 — Private Endpoint + VNet Integration** *(network-layer isolation)*: the App Service joins a VNet and reaches Foundry over a private endpoint; the public endpoint is disabled and the laptop is blocked because it cannot route to the private IP.
- **Scenario 2 — Network Security Perimeter (NSP) + Managed Identity** *(identity-layer isolation)*: a second App Service **without** VNet integration reaches Foundry; a Network Security Perimeter locks the resource down so only **managed identities from the subscription** are allowed. The App Service (system-assigned MI) works; the laptop (user `az login` token) is blocked. The endpoint stays public in DNS — the boundary is at the **identity layer**.

Both scenarios use **Managed Identity (DefaultAzureCredential)** — no API keys anywhere.

---

### 📑 Navigation

[Quick Facts](#quick-facts) · [Scenario 1: Private Endpoint](#scenario-1--private-endpoint--vnet-integration) · [Scenario 2: Network Security Perimeter](#scenario-2--network-security-perimeter--managed-identity) · [Comparison](#scenario-comparison) · [Prerequisites](#prerequisites) · [Quick Start](#quick-start-local-development) · [App Config](#app-configuration) · [API Endpoints](#api-endpoints) · [Security](#security-notes) · [Project Structure](#project-structure) · [Clean Up](#clean-up) · [Resources](#resources)

---

## Quick Facts

| Aspect | Value |
|--------|-------|
| **Resource Type** | Azure AI Services (AIServices / "Foundry" in Portal) |
| **Model** | `gpt-5-mini` (GlobalStandard) |
| **Authentication** | Managed Identity (DefaultAzureCredential) |
| **Region** | `centralus` |
| **Scenario 1 App** | `https://foundry-demo-app-<suffix>.azurewebsites.net` (VNet integrated) |
| **Scenario 2 App** | `https://foundry-demo-nsp-app-<suffix>.azurewebsites.net` (no VNet) |
| **Architecture** | .NET 8 minimal API + embedded dark-theme UI (single codebase, scenario-aware via `Demo__Scenario`) |

---

## Scenario 1 — Private Endpoint + VNet Integration

> **Network-layer isolation.** The App Service joins a VNet; Foundry is reached over a private endpoint; the public endpoint is disabled. The laptop is blocked because it cannot route to the private IP.

### Architecture

```mermaid
graph LR
    subgraph PrivatePhase["🔒 PHASE 2: Private Endpoint"]
        direction TB
        User2["🌐 User/Laptop<br/>❌ BLOCKED"] -.->|✗ cannot reach| AppSvc2["App Service<br/>azurewebsites.net"]
        AppSvc2 -->|VNet Integration<br/>Private IP 10.0.1.x| VNet["Virtual Network<br/>10.0.0.0/16"]
        VNet -->|Private Route| PrivateEP["🔐 Private Endpoint<br/>10.0.2.x"]
        PrivateEP -->|Managed Link| Foundry2["🔒 Azure AI Foundry<br/>Public Endpoint DISABLED"]
        VNet -->|Private DNS<br/>privatelink.cognitiveservices.azure.com| DNS["Private DNS Zone"]
        DNS -.->|resolves to 10.0.2.x| PrivateEP
    end

    subgraph PublicPhase["🟡 PHASE 1: Public Access"]
        direction TB
        User1["🌐 User/Laptop"] -->|HTTPS public| AppSvc1["App Service<br/>azurewebsites.net"]
        AppSvc1 -->|public IP| Internet1["☁️ Public Internet"]
        Internet1 -->|public IP| Foundry1["🟢 Azure AI Foundry<br/>Public Endpoint ENABLED"]
    end
```

---

### Demo Flow (Scenario 1)

### 1. **Phase 1 Deployment** — Everything Works
- Deploy foundry-demo-ai, App Service, VNet, App Service Plan
- App Service has **no** VNet integration yet
- Public access is enabled on foundry-demo-ai
- ✅ Laptop can call `/api/ask` → Azure AI Foundry (public IP)
- ✅ App Service can call `/api/ask` → Azure AI Foundry (public IP)
- **Badge shows:** 🔴 **PUBLIC**

### 2. **Phase 2 Deployment** — Transition to Private
- Enable VNet Integration on App Service
- Create Private Endpoint in VNet
- Configure Private DNS Zone
- Disable public access on foundry-demo-ai
- ❌ Laptop can call `/api/ask` → fails (public blocked, can't reach private endpoint)
- ✅ App Service can call `/api/ask` → works (private IP → private endpoint)
- **Badge shows:** 🟢 **PRIVATE**

**What the customer sees:**
- Before: "Your app works from the cloud, but also from my laptop."
- After: "Now the cloud app still works, but my laptop gets blocked. That's the security boundary."

---

## Prerequisites

- **Azure Subscription** with enough quota for:
  - Azure AI Services (Foundry)
  - App Service + App Service Plan
  - Virtual Network + Private Endpoint (Scenario 1)
  - Private DNS Zone (Scenario 1)
  - Network Security Perimeter (Scenario 2 — check region availability / RP registration)
- **Local Development:**
  - .NET 8 SDK or later
  - Azure CLI (az)
  - PowerShell 7+ (`pwsh`) **or** Bash (WSL2, Git Bash, or native Linux/macOS)
- **Permissions:**
  - Contributor role on the resource group
  - Cognitive Services Contributor (for model deployments)

### Windows Prerequisites Installation (winget)

If you don't have the required tools installed, use **winget** on Windows:

```powershell
# Install Git
winget install Git.Git

# Install .NET 8 SDK
winget install Microsoft.DotNet.SDK.8

# Install Azure CLI
winget install Microsoft.AzureCLI

# Install PowerShell 7 (if you don't have pwsh)
winget install Microsoft.PowerShell
```

> **Note:** After installing these tools, restart your terminal before proceeding.

---

## Quick Start (Local Development)

### 1. Clone and prepare environment

```bash
git clone https://github.com/dmauser/ms-foundry-pe-demo.git
cd ms-foundry-pe-demo
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"
```

### 2. Run locally with DefaultAzureCredential

```bash
# Must be logged in via az login
cd src
dotnet run
```

The app will start on `http://localhost:5000`. Open http://localhost:5000/ in your browser.

- **Diagnostics** will show: `🔴 PUBLIC` (local laptop connecting directly)
- **Chat Test** will work if:
  - You have access to foundry-demo-ai (same subscription)
  - Public endpoint is enabled
  - DefaultAzureCredential can authenticate (from `az login`)

---

## Scenario 1 — Deploy (Private Endpoint)

> **Prerequisite:** complete the shared [Prerequisites](#prerequisites) above. Scenario 1 is a two-phase flow: Phase 1 (public baseline) → Phase 2 (private).

### Phase 1: Deploy Public Access

```bash
# From the repo root (Linux/macOS)
scripts/01-deploy-public-access.sh
```

```powershell
# From the repo root (Windows PowerShell)
pwsh scripts/01-deploy-public-access.ps1
```

> **Note:** All resource names include a randomly generated 5-character suffix (e.g., `foundry-demo-ai-a3x9k`) to allow multiple users to deploy the demo in the same subscription without naming conflicts. The suffix is stored in `scripts/.deploy-suffix` and reused by both scripts.

**What this does:**
- Creates resource group: `rg-foundry-demo-<suffix>`
- Deploys all infrastructure via Bicep (`infra/01-public-access.bicep`):
  - Azure AI Services: `foundry-demo-ai-<suffix>` (gpt-5-mini, GlobalStandard)
  - App Service Plan: `foundry-demo-plan-<suffix>` (Linux, B1)
  - App Service: `foundry-demo-app-<suffix>` with VNet Integration
  - VNet: `foundry-demo-vnet-<suffix>` (10.0.0.0/16) with two subnets
  - RBAC: Cognitive Services User role for App Service managed identity
- Builds and zip-deploys the .NET 8 app
- App Settings configured automatically:
  - `AzureOpenAI__Endpoint = https://foundry-demo-ai-<suffix>.cognitiveservices.azure.com/`
  - `AzureOpenAI__DeploymentName = gpt-5-mini`
  - `AzureOpenAI__UseSystemAssignedIdentity = true`
- **Leaves public access enabled** on the AI Services resource

**After Phase 1:**
- Visit `https://foundry-demo-app-<suffix>.azurewebsites.net`
- Diagnostics badge: 🔴 **PUBLIC** (App Service not yet in VNet)
- Chat works from laptop (public endpoint)
- Chat works from App Service (public endpoint)

### Phase 2: Enable Private Access

```bash
# From the repo root (Linux/macOS)
scripts/02-enable-private-access.sh
```

```powershell
# From the repo root (Windows PowerShell)
pwsh scripts/02-enable-private-access.ps1
```

**What this does:**
- Deploys private infrastructure via Bicep (`infra/02-private-access.bicep`):
  - Private Endpoint in `foundry-subnet` (10.0.2.0/24)
  - Private DNS Zone: `privatelink.cognitiveservices.azure.com`
  - VNet Link for DNS resolution
  - DNS Zone Group for automatic A record registration
- Disables public access on the AI Services resource via `az resource update`

**After Phase 2:**
- Visit `https://foundry-demo-app-<suffix>.azurewebsites.net`
- Diagnostics badge: 🟢 **PRIVATE** (resolves to 10.0.2.x private endpoint IP)
- Chat works from App Service (private endpoint)
- Chat **fails** from laptop (public access blocked, can't route to private IP)

---

## Scenario 1 — Validation Results

> **Infrastructure as Code:** All Azure resources are provisioned via **Bicep templates** (`infra/`). Wrapper scripts handle only suffix generation, resource group creation, Bicep deployment, and .NET app packaging. PowerShell (`.ps1`) equivalents exist for every script and share the same `scripts/.deploy-suffix` file.

### Expected Behavior

| Scenario | Phase 1 (Public) | Phase 2 (Private) | Indicator |
|----------|-----------------|-------------------|-----------|
| **App Service** — DNS resolution | Public IP | Private IP (10.0.2.x) | ✓ Changes |
| **App Service** — Chat works | ✅ Yes | ✅ Yes | 🟢 Uninterrupted |
| **Laptop** — DNS resolution | Public IP | ❌ Cannot resolve (or times out) | — |
| **Laptop** — Chat works | ✅ Yes | ❌ No | 🔴 Blocked as expected |
| **Badge** (App Service UI) | 🔴 PUBLIC | 🟢 PRIVATE | Visual confirmation |

### Running the Demo

1. **Start at Phase 1:**
   - Open `https://foundry-demo-app-<suffix>.azurewebsites.net` on a customer's laptop
   - Click "Run Diagnostics" → shows 🔴 **PUBLIC**, resolves to public IP
   - Type "hello" in Chat Test → response appears
   - Say: "Notice the endpoint is publicly accessible right now."

2. **Run Phase 2 deployment:**
   ```bash
   scripts/02-enable-private-access.sh
   ```
   - Wait ~2 minutes for DNS propagation

3. **Reconnect at Phase 2:**
   - Refresh `https://foundry-demo-app-<suffix>.azurewebsites.net`
   - Click "Run Diagnostics" → shows 🟢 **PRIVATE**, resolves to private IP (10.0.2.x)
   - Type "hello" in Chat Test → response appears
   - Say: "Same app, still works. But look—the endpoint is now private."

4. **From your laptop:**
   - Try to connect to the Foundry endpoint directly → fails (connection refused)
   - Try calling `dotnet run` and hitting `/api/ask` → fails (can't resolve or access)
   - Say: "From the outside, the endpoint is completely blocked. Only the VNet can reach it."

---

---

## Scenario 2 — Network Security Perimeter + Managed Identity

> **Identity-layer isolation.** A **second** App Service — deliberately **without** VNet integration — calls the **same** Foundry. A Network Security Perimeter (NSP) locks the resource down with an identity-based inbound rule so only **managed identities from the subscription** are allowed. The App Service's system-assigned managed identity is permitted; a laptop using a user `az login` token is blocked. The endpoint keeps its **public DNS name** — the boundary is at the **identity layer**, not the network layer.

### How the identity perimeter works

Scenario 2 uses a `Microsoft.Network/networkSecurityPerimeters` resource with a single **inbound access rule of type _Subscriptions_**. Per Azure NSP semantics, a Subscriptions rule *"allows inbound access authenticated using any managed identity from the subscription."* The Foundry is associated with the perimeter in **`Enforced`** mode:

- ✅ **App Service** (system-assigned MI in the subscription) → **allowed**
- ❌ **Laptop** (user token from `az login`, not a managed identity) → **blocked (403)**

No VNet, no private endpoint, no private DNS zone required.

### Architecture

```mermaid
graph LR
    subgraph Enforced["🛡️ NSP ENFORCED (identity perimeter)"]
        direction TB
        User["🌐 User/Laptop<br/>az login user token<br/>❌ BLOCKED (403)"] -.->|✗ not a managed identity| Foundry["🔒 Azure AI Foundry<br/>public DNS, NSP-guarded"]
        NspApp["App Service (no VNet)<br/>foundry-demo-nsp-app<br/>System-assigned MI ✅"] -->|managed identity<br/>from subscription| Foundry
        NSP["Network Security Perimeter<br/>Inbound rule: Subscriptions = this sub"] -.->|Enforced association| Foundry
    end
```

### Demo Flow (Scenario 2)

**Step A (03)** — Deploy the second App Service against the still-public Foundry. Both laptop and app work. *(baseline)*

**Step B (04)** — Apply the Network Security Perimeter (Enforced). The app keeps working via its managed identity; the laptop is now blocked.

**What the customer sees:**
- Before: "This second app has **no** VNet integration, yet it reaches Foundry — and so does my laptop."
- After: "Same app, still works — because it authenticates with a **managed identity**. My laptop is now blocked even though the endpoint is still public. The perimeter gates by **identity**, not network."

### Deploy (Scenario 2)

> **Prerequisite:** Scenario 2 runs from the **Scenario 1 Phase-1 (public) baseline** — you must have already run `01-deploy-public-access` (it creates the Foundry + App Service Plan and the shared `.deploy-suffix`). You do **not** need Scenario 1 Phase 2 (`02-*`).
>
> ⚠️ **Do not mix scenarios on the same Foundry.** Scenario 2 (`04-enforce-nsp`) is an **alternative** to Scenario 1 Phase 2 (`02-enable-private-access`). Applying both a private endpoint (`02`) and an NSP (`04`) to the same Foundry is not the intended demo path. To run Scenario 2 cleanly after Scenario 1 Phase 2, re-enable public access first (Step A does this automatically).
>
> 🧩 **NSP is public preview and requires two subscription feature flags** to be registered, or the perimeter provisions but the data plane does **not** enforce it (user tokens keep getting `200` instead of `403`). **Step B (`04-enforce-nsp`) registers these automatically**, but you can pre-register them:
> ```bash
> az feature registration create --namespace Microsoft.CognitiveServices --name OpenAI.NspPreview
> az feature registration create --namespace Microsoft.Network --name AllowNSPInPublicPreview
> ```
> Registration is usually quick; the script polls until both report `Registered` and then re-registers the `Microsoft.CognitiveServices` / `Microsoft.Network` providers. See [Add an Azure OpenAI service to a network security perimeter](https://learn.microsoft.com/azure/ai-services/openai/how-to/network-security-perimeter).

#### Step A: Deploy the second (NSP) App Service

```bash
# Linux/macOS
scripts/03-deploy-nsp-app.sh
```

```powershell
# Windows PowerShell
pwsh scripts/03-deploy-nsp-app.ps1
```

**What this does** (`infra/03-nsp-app-service.bicep`):
- Ensures the Foundry `publicNetworkAccess = Enabled` (baseline)
- Deploys a new App Service `foundry-demo-nsp-app-<suffix>` on the **existing** App Service Plan — **no VNet integration**
- System-assigned managed identity + **Cognitive Services User** role on the existing Foundry
- App settings include `Demo__Scenario = NSP` so the UI renders the NSP framing
- Builds and zip-deploys the same .NET 8 app

**After Step A:** visit `https://foundry-demo-nsp-app-<suffix>.azurewebsites.net` → badge shows 🛡️ **NSP PERIMETER**; chat works from both laptop and app (Foundry still public).

#### Step B: Enforce the Network Security Perimeter

```bash
# Linux/macOS
scripts/04-enforce-nsp.sh
```

```powershell
# Windows PowerShell
pwsh scripts/04-enforce-nsp.ps1
```

**What this does** (`infra/04-nsp-enforce.bicep`):
- Creates `foundry-demo-nsp-<suffix>` (Network Security Perimeter) + profile
- Adds an **inbound access rule** of type **Subscriptions** = the current subscription (any managed identity from the sub)
- Associates the **existing Foundry** with the perimeter in **`Enforced`** mode

**After Step B:**
- ✅ Chat works from the App Service (managed identity allowed by the perimeter)
- ❌ Chat **fails** from the laptop (user token is not a managed identity → 403)
- The endpoint DNS is still public — the block is at the identity layer

> **Note:** data-plane enforcement can take a few minutes to propagate after Step B. If the laptop deny test still returns `200`, wait ~3 minutes and retry.

### Expected Behavior (Scenario 2)

| Actor | Step A (public, no NSP) | Step B (NSP Enforced) | Why |
|-------|-------------------------|-----------------------|-----|
| **App Service** (system MI) — Chat | ✅ Yes | ✅ Yes | Managed identity from the subscription is allowed by the inbound rule |
| **Laptop** (user `az login`) — Chat | ✅ Yes | ❌ No (403) | User token is not a managed identity → denied by the perimeter |
| **Endpoint DNS** | Public | Public (unchanged) | NSP gates by identity, not by network/DNS |
| **VNet Integration** | Not required | Not required | The whole point of Scenario 2 |

### Caveats (Scenario 2)

- **Region availability / RP registration:** NSP is not available in every region and may require the `Microsoft.Network` NSP feature to be registered on the subscription. `centralus` is expected to work.
- **Subscription-wide rule:** the inbound rule allows *any* managed identity in the subscription — including Scenario 1's App Service MI. That is acceptable for this demo; the teaching point is identity-gating vs. the laptop's user token. Tighten with a narrower rule (e.g. specific identities/PaaS resources) for production.
- **Enforced mode:** applying `Enforced` immediately blocks non-allowed callers. Use `Learning` mode first if you want to observe traffic before enforcing.

---

## Scenario Comparison

| Dimension | Scenario 1 — Private Endpoint | Scenario 2 — Network Security Perimeter |
|-----------|-------------------------------|------------------------------------------|
| **Isolation layer** | Network (VNet + private IP) | Identity (managed identity) |
| **App Service VNet integration** | **Required** | **Not required** |
| **Foundry public endpoint** | Disabled | Stays public in DNS (NSP-guarded) |
| **What blocks the laptop** | Cannot route to the private IP | Not a managed identity (403) |
| **Extra infra** | VNet, subnets, private endpoint, private DNS zone | Network Security Perimeter + profile + rule |
| **DNS behavior** | Resolves to private `10.x` inside VNet | Unchanged public name |
| **App Service** | `foundry-demo-app-<suffix>` | `foundry-demo-nsp-app-<suffix>` |
| **Deploy scripts** | `01-*`, `02-*` | `03-*`, `04-*` (needs `01-*` baseline) |
| **Badge in UI** | 🔴 PUBLIC → 🟢 PRIVATE | 🛡️ NSP PERIMETER (Chat Test is the allow/deny proof) |

Both scenarios authenticate with **Managed Identity** and require **no API keys**.

---

## App Configuration

### Environment Variables

The App Service is configured with these variables (no API key required):

```
AzureOpenAI__Endpoint = https://foundry-demo-ai-<suffix>.cognitiveservices.azure.com/
AzureOpenAI__DeploymentName = gpt-5-mini
Demo__Scenario = PrivateEndpoint   # Scenario 1 default; the NSP app sets this to "NSP"
```

> **`Demo__Scenario`** drives the UI framing only. `PrivateEndpoint` (default) → 🔴 PUBLIC / 🟢 PRIVATE badge from RFC1918 IP detection. `NSP` → 🛡️ NSP PERIMETER framing where the Chat Test is the allow/deny proof. The `/api/ask` auth logic (Managed Identity via `DefaultAzureCredential`) is identical for both.

### Authentication Flow

**No API keys. Uses Managed Identity:**

```csharp
// In Program.cs
var credential = new DefaultAzureCredential();
var client = new AzureOpenAIClient(new Uri(endpoint), credential);
```

The App Service's system-assigned managed identity is granted **Cognitive Services User** role on foundry-demo-ai.

---

## API Endpoints

### `GET /` — HTML UI
Returns the embedded dark-theme dashboard.

### `GET /api/diagnostics` — Network Diagnostics
Checks network connectivity and returns JSON:

```json
{
  "scenario": "PrivateEndpoint",
  "hostname": "foundry-demo-ai.cognitiveservices.azure.com",
  "resolvedIPs": ["10.0.1.10"],
  "isPrivate": true,
  "websitePrivateIP": "10.0.2.5",
  "vnetIntegrated": true,
  "timestamp": "2025-05-05T16:37:25Z"
}
```

- **`scenario`**: `PrivateEndpoint` (default) or `NSP`, from the `Demo__Scenario` app setting
- **`isPrivate`**: `true` if all resolved IPs are RFC1918 (10.x, 172.16–31.x, 192.168.x.x)
- **`vnetIntegrated`**: `true` if `WEBSITE_PRIVATE_IP` environment variable is set (indicates VNet Integration)

### `GET /api/ask?prompt=hello` — Chat API
Sends prompt to gpt-5-mini and returns JSON:

```json
{
  "prompt": "hello",
  "response": "Hello! How can I help you today?",
  "latencyMs": 456,
  "model": "gpt-5-mini",
  "timestamp": "2025-05-05T16:37:25Z"
}
```

On error (network, auth, model):
```json
{
  "error": "connection refused",
  "prompt": "hello"
}
```

---

## Security Notes

### Managed Identity (Zero API Keys)
- App Service uses **system-assigned managed identity**
- No API keys stored anywhere (not in config, not in Key Vault needed for this demo)
- If foundry-demo-ai is demoted to Azure OpenAI Service, key rotation would be required (use Key Vault)

### Private Endpoint Benefits
- **Network Isolation:** Foundry endpoint is unreachable from the internet
- **Private DNS:** Custom domain resolves to private IP inside VNet only
- **Compliance:** Network traffic never traverses the public internet
- **Auditability:** Private endpoint connections appear in Azure logs

### Disabling Public Access
- Scenario 1 Phase 2 sets `public_network_access = false` on foundry-demo-ai
- Breaks all public DNS resolution and IP-based access
- Only way to reach the service is via the private endpoint in the VNet

### Network Security Perimeter (Scenario 2)
- **Identity-based boundary:** an NSP inbound *Subscriptions* rule permits only managed identities from the subscription — user tokens (e.g. a laptop `az login`) are denied
- **No VNet required:** the App Service reaches Foundry over the public endpoint but is authorized by its managed identity
- **Endpoint stays public in DNS:** the block happens at the identity/authorization layer, not the network layer
- **Enforced vs. Learning:** `Enforced` blocks immediately; use `Learning` mode to observe traffic before enforcing
- **Scope the rule for production:** the subscription-wide rule allows any MI in the sub — narrow it to specific identities/resources for real workloads

---

## Project Structure

```
ms-foundry-pe-demo/
├── README.md                          # This file
├── infra/
│   ├── 01-public-access.bicep         # Scenario 1 Phase 1: VNet, AI Services, App Service, RBAC
│   ├── 02-private-access.bicep        # Scenario 1 Phase 2: Private Endpoint, DNS Zone
│   ├── 03-nsp-app-service.bicep       # Scenario 2 Step A: 2nd App Service (no VNet) + RBAC
│   └── 04-nsp-enforce.bicep           # Scenario 2 Step B: Network Security Perimeter (Enforced)
├── src/
│   ├── Program.cs                     # .NET 8 minimal API + embedded HTML (scenario-aware)
│   ├── appsettings.json               # Endpoint + DeploymentName config
│   └── *.csproj                       # Project file
├── docs/
│   ├── demo-walkthrough.md            # Step-by-step portal walkthrough
│   ├── network-evidence.md            # Network diagnostics & evidence
│   └── diagrams/                      # Architecture diagrams
├── scripts/
│   ├── 01-deploy-public-access.sh     # Scenario 1 Phase 1: Bash wrapper
│   ├── 01-deploy-public-access.ps1    # Scenario 1 Phase 1: PowerShell wrapper
│   ├── 02-enable-private-access.sh    # Scenario 1 Phase 2: Bash wrapper
│   ├── 02-enable-private-access.ps1   # Scenario 1 Phase 2: PowerShell wrapper
│   ├── 03-deploy-nsp-app.sh           # Scenario 2 Step A: Bash wrapper
│   ├── 03-deploy-nsp-app.ps1          # Scenario 2 Step A: PowerShell wrapper
│   ├── 04-enforce-nsp.sh              # Scenario 2 Step B: Bash wrapper
│   ├── 04-enforce-nsp.ps1             # Scenario 2 Step B: PowerShell wrapper
│   └── .deploy-suffix                 # Generated suffix (gitignored, shared by both scenarios)
├── .github/                           # GitHub config & copilot instructions
└── .gitignore                         # Git ignore rules
```

---

## Local Development

### Build

```bash
cd src
dotnet build
```

### Run

```bash
# Must have az login active
dotnet run
# Open http://localhost:5000/
```

### Test Endpoints

```bash
# Diagnostics
curl http://localhost:5000/api/diagnostics | jq

# Chat (requires public access + az login)
curl "http://localhost:5000/api/ask?prompt=What%20is%202%2B2%3F"
```

---

## Clean Up

To delete all demo resources:

```bash
# Read suffix from file
SUFFIX=$(cat scripts/.deploy-suffix)
az group delete -n "rg-foundry-demo-$SUFFIX" --yes --no-wait
```

```powershell
# PowerShell
$Suffix = (Get-Content scripts/.deploy-suffix -Raw).Trim()
az group delete -n "rg-foundry-demo-$Suffix" --yes --no-wait
```

---

## Resources

- [Azure AI Foundry](https://azure.microsoft.com/en-us/products/ai-services/foundry/)
- [Private Endpoints for Azure OpenAI](https://learn.microsoft.com/en-us/azure/ai-services/how-to/manage-identity)
- [VNet Integration in App Service](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration)
- [Network Security Perimeter overview](https://learn.microsoft.com/en-us/azure/private-link/network-security-perimeter-concepts)
- [DefaultAzureCredential (Azure Identity SDK)](https://learn.microsoft.com/en-us/dotnet/api/azure.identity.defaultazurecredential)

---

## License

MIT — See [LICENSE](./LICENSE) for details.

---

## Contributing

This is a demo repository maintained by the Azure AI team. For bugs or feedback, please open an issue.

---

**Demo Version:** 4.0 (adds Scenario 2 — Network Security Perimeter)  
**Last Updated:** July 2026
