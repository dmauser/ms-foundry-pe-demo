# Azure OpenAI Private Endpoint Demo — Complete Walkthrough

**Purpose:** Master guide for running the Private Endpoint demo to customers.  
**Time Required:** ~30 minutes (first run); ~15 minutes (subsequent runs)  
**Audience:** Solutions architects, cloud engineers, security team leads

---

## 1. Architecture Diagram

### Before: Public Internet Access

```
┌─────────────────────────────────────────────────────────────────┐
│ AZURE CLOUD                                                      │
│                                                                   │
│ App Service (myapp.azurewebsites.net)                           │
│ ┌─────────────────────┐                                         │
│ │  .NET 8 Web App     │                                         │
│ │  - Running Container                                          │
│ │  - HTTP/HTTPS       │                                         │
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
│ Azure OpenAI Service                                             │
│ ┌──────────────────────────────────────────────────────────────┤
│ │ myresource.openai.azure.com (Public Endpoint)               │
│ │ IP: 20.42.111.222 (Public Azure IP range)                   │
│ │ ✗ Publicly accessible on internet                           │
│ └──────────────────────────────────────────────────────────────┤
└─────────────────────────────────────────────────────────────────┘

[Your Laptop]  ──can reach──►  PUBLIC INTERNET  ──can reach──►  Azure OpenAI
```

**Key Points:**
- App Service resolves `myresource.openai.azure.com` → public IP (20.x.x.x)
- Traffic exits Azure backbone, crosses the public internet
- Anyone with API key can attempt to reach the endpoint
- Subject to DDoS, egress charges, internet latency

---

### After: Private VNet + Private Endpoint

```
┌──────────────────────────────────────────────────────────────────┐
│ AZURE CLOUD & VNET (10.0.0.0/16)                                │
│                                                                   │
│ ┌─────────────────────────────────┐                             │
│ │ Integration Subnet (10.0.1.0/24)│                             │
│ │ Delegated to Microsoft.Web/*    │                             │
│ │ ┌───────────────────────────┐   │                             │
│ │ │ App Service (VNet-bound)  │   │                             │
│ │ │ Private IP: 10.0.1.42     │   │                             │
│ │ └───────────────────────────┘   │                             │
│ └─────────────────────────────────┘                             │
│         │                                                        │
│         │ VNET ROUTE (RFC1918)                                  │
│         │ ◄───────────────────────►                            │
│         ↓                                                        │
│ ┌─────────────────────────────────┐                             │
│ │ PE Subnet (10.0.2.0/24)         │                             │
│ │ ┌───────────────────────────┐   │                             │
│ │ │ Private Endpoint          │   │                             │
│ │ │ IP: 10.0.2.5              │   │                             │
│ │ │ privatelink.openai.azure…│   │                             │
│ │ └───────────────────────────┘   │                             │
│ └─────────────────────────────────┘                             │
│                                                                   │
│ ┌─────────────────────────────────┐                             │
│ │ Private DNS Zone                │                             │
│ │ privatelink.openai.azure.com   │                             │
│ │ ↓                               │                             │
│ │ myresource.privatelink… → 10.0.2.5                           │
│ └─────────────────────────────────┘                             │
└──────────────────────────────────────────────────────────────────┘
                    │
                    │ Azure Backbone Only
                    │ (No internet)
                    ↓
        ┌───────────────────────┐
        │ Azure OpenAI Service  │
        │ (Private Endpoint only)
        │ Public endpoint: Disabled
        └───────────────────────┘

[Your Laptop]  ✗ CANNOT reach  Azure OpenAI (403 Forbidden)
[App Service]  ──CAN reach──►  Azure OpenAI (via private endpoint, 10.0.2.5)
```

**Key Points:**
- App Service has VNet Integration → gets private IP (10.0.1.42)
- Private Endpoint created in PE subnet → gets IP (10.0.2.5)
- Private DNS zone intercepts hostname → resolves to 10.0.2.5 (inside VNet only)
- Public endpoint disabled → internet calls receive 403 Forbidden
- Traffic never leaves Azure backbone
- Your laptop cannot reach the endpoint (expected security behavior)

---

## 2. Step-by-Step Portal Demo

### Phase 1: Create Resources (Public Access)

#### Step 1.1: Create Azure OpenAI Resource
1. Go to **Azure Portal** → **Create a resource** → Search for **"Azure OpenAI"**
2. Click **Azure OpenAI** (published by Microsoft) → **Create**
3. **Basics tab:**
   - **Subscription:** Select your subscription
   - **Resource Group:** Create or select (e.g., `rg-openai-demo`)
   - **Region:** East US or West Europe (where `gpt-4o-mini` model is available)
   - **Name:** `myai` (will be used as the resource-specific endpoint)
   - **Pricing tier:** Standard S0
4. Click **Next: Network** → Leave as **Public endpoint**
5. Click **Review + Create** → **Create**
6. Wait for deployment (2–3 minutes)

#### Step 1.2: Deploy gpt-4o-mini Model
1. In the Azure OpenAI resource, navigate to **Model deployments** (under Deployment)
2. Click **Create new deployment** → **Deploy model**
3. Select **gpt-4o-mini** from the model list
4. **Deployment name:** `gpt-4o-mini`
5. **Version:** Leave as default (latest)
6. Click **Create**
7. Wait for model deployment (1–2 minutes)

#### Step 1.3: Get API Key
1. In the Azure OpenAI resource, go to **Keys and Endpoint** (under Resource Management)
2. Copy **Key 1** (you'll need this for app settings)
3. Copy the **Endpoint** URL (e.g., `https://myai.openai.azure.com/`)

#### Step 1.4: Create App Service
1. Go to **Azure Portal** → **Create a resource** → Search for **"Web App"**
2. Click **Web App** (by Microsoft) → **Create**
3. **Basics tab:**
   - **Subscription:** Same subscription
   - **Resource Group:** Same resource group
   - **Name:** `myapp-pe-demo` (will be your DNS name)
   - **Publish:** Code (not container)
   - **Runtime stack:** .NET 8 (LTS)
   - **Operating system:** Windows or Linux (your choice)
   - **Region:** Same as Azure OpenAI
   - **App Service Plan:** Create new (e.g., `plan-demo`, Standard S1 or higher)
4. Click **Next: Database** → Skip (no database)
5. Click **Next: Monitoring** → Enable Application Insights if desired (optional for this demo)
6. Click **Review + Create** → **Create**
7. Wait for deployment (2–3 minutes)

#### Step 1.5: Configure App Settings
1. Once App Service is deployed, go to the resource
2. Navigate to **Settings** → **Configuration** (under Settings)
3. Click **New application setting** and add these three settings:

| Name | Value | Notes |
|------|-------|-------|
| `AzureOpenAI__Endpoint` | `https://myai.openai.azure.com/` | From Key & Endpoint blade; include trailing slash |
| `AzureOpenAI__DeploymentName` | `gpt-4o-mini` | Must match deployment name from Step 1.2 |
| `AzureOpenAI__ApiKey` | `<paste Key 1 from Step 1.3>` | From Keys and Endpoint blade |

4. Click **Save** → **Continue** (restart not required yet, but you can restart now)

#### Step 1.6: Deploy the .NET App
Choose one method:

**Option A: ZIP Deploy**
1. Download the app source or use local repo clone
2. In App Service, go to **Deployment Center** → Select deployment method (Local Git, GitHub, Zip upload, etc.)
3. Use Zip deploy: Go to Advanced Tools → Debug Console → Site/wwwroot → Upload the zipped .NET 8 app
4. Unzip and the app will start

**Option B: Visual Studio Publish**
1. Open solution in Visual Studio
2. Right-click project → **Publish**
3. Select **Azure** → Choose the App Service resource → **Finish**
4. Click **Publish**

**Option C: Git Deployment**
1. In App Service, go to **Deployment Center** → Select **Local Git**
2. Clone the repo to your machine
3. Add Azure remote: `git remote add azure <git clone URL>`
4. Push to Azure: `git push azure main`

#### Step 1.7: TEST — Verify Public Access Works
1. Go to your App Service URL in browser: `https://myapp-pe-demo.azurewebsites.net/`
2. You should see the **Azure OpenAI Demo** page
3. Click **🔄 Run Diagnostics** button
4. **Expected result:**
   - 🔴 **PUBLIC** badge (red)
   - Resolved IPs: `20.x.x.x` (Azure public IP range)
   - `WEBSITE_PRIVATE_IP`: (not set)
   - `VNet Integrated`: **No ✗**
5. If you see 🟢 PRIVATE, something is already configured — skip ahead or reset and start over

#### Step 1.8: TEST — Chat Functionality
1. In the **Chat Test** panel, type a prompt: `"Hello, what is Azure?"`
2. Click **Send**
3. **Expected result:**
   - Response appears in 2–5 seconds
   - Model: `gpt-4o-mini`
   - Latency: ~500ms (will be faster after VNet integration due to less internet hops)

---

### Phase 2: Move to Private Access

#### Step 2.1: Create Virtual Network
1. Go to **Azure Portal** → **Create a resource** → Search for **"Virtual Network"**
2. Click **Virtual Network** (by Microsoft) → **Create**
3. **Basics tab:**
   - **Subscription:** Same subscription
   - **Resource Group:** Same resource group
   - **Name:** `vnet-demo`
   - **Region:** Same as your resources
4. Click **Next: IP Addresses**
5. **Address space:** Change to `10.0.0.0/16` (or leave default 10.0.0.0/16 if already set)
6. Click **Add subnet** twice to create two subnets:

**Subnet 1: Integration Subnet**
- **Name:** `subnet-integration`
- **Address range:** `10.0.1.0/24`
- **Delegation:** `Microsoft.Web/serverFarms` (important!)

**Subnet 2: Private Endpoint Subnet**
- **Name:** `subnet-pe`
- **Address range:** `10.0.2.0/24`
- **Delegation:** None

7. Click **Review + Create** → **Create**

#### Step 2.2: Enable App Service VNet Integration
1. Go to your **App Service** resource
2. Navigate to **Settings** → **Networking** (under Settings)
3. Under **Outbound traffic**, click **VNet Integration**
4. Click **Add VNet**
5. **Select VNet:** `vnet-demo`
6. **Select Subnet:** `subnet-integration`
7. Click **OK**
8. **Expected:** App Service shows "Connected to vnet-demo (subnet-integration)"
9. **Restart App Service** (top toolbar → **Restart**)

#### Step 2.3: Create Private Endpoint for Azure OpenAI
1. Go to your **Azure OpenAI resource**
2. Navigate to **Settings** → **Networking** (under Resource Management)
3. Click **+ Private endpoint connection** (or "+ Private endpoint" if shown as a button)
4. **Basics tab:**
   - **Project details:** Select your subscription and resource group
   - **Name:** `pe-openai-demo`
   - **Region:** Same as resources
5. Click **Next: Resource**
6. **Resource tab:**
   - **Connection name:** `pe-openai-demo-connection`
   - **Target sub-resource:** Select **account** (this is the default and correct)
7. Click **Next: Virtual Network**
8. **Virtual Network:** Select `vnet-demo`
9. **Subnet:** Select `subnet-pe`
10. Click **Next: DNS**
11. **DNS tab:**
    - **Integrate with private DNS zone:** **Yes**
    - Private DNS zone will be created or auto-linked: `privatelink.openai.azure.com`
12. Click **Next: Tags** (skip or add tags)
13. Click **Review + Create** → **Create**
14. Wait for private endpoint deployment (2–3 minutes)

#### Step 2.4: Verify Private DNS Zone Linked to VNet
1. Go to **Private DNS Zones** in the portal
2. Find or search for `privatelink.openai.azure.com`
3. Click on it
4. Navigate to **Settings** → **Virtual Network Links** (under Settings)
5. **Expected:** You should see `vnet-demo` listed and **linked**
6. If not linked, click **+ Add** and link `vnet-demo` now

#### Step 2.5: Disable Public Access on Azure OpenAI
1. Go to your **Azure OpenAI resource**
2. Navigate to **Settings** → **Networking** (under Resource Management)
3. Under **Firewalls and virtual networks**, find the radio button or dropdown:
   - **Current setting:** Likely shows **"Enabled from all networks"**
   - **Change to:** **Disabled** (or **"Enabled from selected virtual networks and private endpoints"**)
4. Click **Save**
5. **Expected:** Portal may warn "Public access will be disabled. You will only be able to access this resource through private endpoints."
6. Confirm: **Yes, disable public access**

#### Step 2.6: TEST — Verify Private Access Works
1. Go to your App Service in the browser: `https://myapp-pe-demo.azurewebsites.net/`
2. Click **🔄 Run Diagnostics**
3. **Expected result:**
   - 🟢 **PRIVATE** badge (green)
   - Resolved IPs: `10.0.2.x` (private endpoint IP in PE subnet)
   - `WEBSITE_PRIVATE_IP`: `10.0.1.42` (or similar 10.0.1.x)
   - `VNet Integrated`: **Yes ✓**

#### Step 2.7: TEST — Chat Still Works
1. Type a new prompt: `"What is a private endpoint?"`
2. Click **Send**
3. **Expected result:**
   - Response appears in 1–3 seconds (likely **faster** than public due to reduced internet latency)
   - Same model and format as before

#### Step 2.8: TEST — Direct Access Fails (Proof of Lockdown)
**Run from your laptop (outside the VNet):**

```bash
# Should fail with 403 Forbidden or connection refused
curl -v https://myai.openai.azure.com/health

# Expected:
# HTTP/1.1 403 Forbidden
# -or-
# Connection refused
```

This proves the endpoint is no longer publicly accessible.

---

## 3. App Service App Settings Reference

All three settings are required for the app to function. These are managed via **App Service → Configuration → Application settings**.

| Setting | Type | Value | Example | Notes |
|---------|------|-------|---------|-------|
| `AzureOpenAI__Endpoint` | String | Full HTTPS URL to Azure OpenAI resource | `https://myai.openai.azure.com/` | **Include trailing slash.** Use resource-specific endpoint, not regional endpoint. |
| `AzureOpenAI__DeploymentName` | String | Name of deployed model | `gpt-4o-mini` | Must exactly match the deployment name from Step 1.2. Case-sensitive. |
| `AzureOpenAI__ApiKey` | Secret | API key from Azure OpenAI Keys blade | `<key-from-portal>` | Use Key 1 or Key 2. Best practice: use Key Vault reference or managed identity instead of plain text. |

**Best Practice:** Do NOT store the API key in `appsettings.json` or commit it to source control. Always use:
- **App Service Application Settings** (shown above)
- **Azure Key Vault** with managed identity reference
- **DefaultAzureCredential** (preferred) if using managed identity

---

## 4. Validation Commands

Run these commands to validate the state of your deployment at each phase.

| Command | Where to Run | Before (Public) | After (Private) | Notes |
|---------|--------------|-----------------|-----------------|-------|
| `nslookup myai.openai.azure.com` | Your laptop | Resolves to `20.x.x.x` | Still resolves to `20.x.x.x` | Outside VNet always sees public IP; this is normal. |
| `nslookup myai.openai.azure.com` | App Service Kudu | Resolves to `20.x.x.x` | Resolves to `10.0.2.x` | **KEY INDICATOR:** Private DNS zone only works inside VNet. |
| `curl https://myai.openai.azure.com/health -v` | Your laptop | HTTP 200 OK | HTTP 403 Forbidden | Public endpoint accessible before; blocked after. |
| `curl https://myapp-pe-demo.azurewebsites.net/api/diagnostics` | Your laptop | `"isPrivate": false` | `"isPrivate": true` | App detects private connectivity. |
| `curl https://myapp-pe-demo.azurewebsites.net/api/ask?prompt=hello` | Your laptop | Chat response | Chat response | Same app; works throughout (network path changes). |

**How to run nslookup from App Service Kudu:**
1. Go to your App Service
2. Navigate to **Development Tools** → **Advanced Tools (Kudu)** (or go directly to `https://myapp-pe-demo.scm.azurewebsites.net/`)
3. Click **Debug Console** → **PowerShell** or **CMD**
4. Type: `nslookup myai.openai.azure.com`

---

## 5. Expected Results

### Before: Public Access (Phase 1 Complete)

**Diagnostics:**
```json
{
  "hostname": "myai.openai.azure.com",
  "resolvedIPs": ["20.42.111.222"],
  "isPrivate": false,
  "websitePrivateIP": null,
  "vnetIntegrated": false,
  "timestamp": "2025-05-05T12:30:00Z"
}
```

**Badge:** 🔴 **PUBLIC** (red)

**DNS from laptop:** `20.42.111.222` (Azure public IP)  
**DNS from Kudu:** `20.42.111.222` (same as laptop)  
**curl to endpoint:** HTTP 200 OK (public access works)  
**Chat test:** Responds in ~500–1000ms (crosses internet)

---

### After: Private Access (Phase 2 Complete)

**Diagnostics:**
```json
{
  "hostname": "myai.openai.azure.com",
  "resolvedIPs": ["10.0.2.5"],
  "isPrivate": true,
  "websitePrivateIP": "10.0.1.42",
  "vnetIntegrated": true,
  "timestamp": "2025-05-05T12:45:00Z"
}
```

**Badge:** 🟢 **PRIVATE** (green)

**DNS from laptop:** `20.42.111.222` (still public from outside VNet — expected)  
**DNS from Kudu:** `10.0.2.5` (private endpoint IP — private DNS zone works inside VNet)  
**curl to endpoint:** HTTP 403 Forbidden (public access blocked — security working)  
**Chat test:** Responds in ~200–500ms (stays on Azure backbone, faster)

---

## 6. Troubleshooting Checklist

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| **App shows 🔴 PUBLIC after enabling VNet** | VNet Integration not enabled or not restarted | Go to **App Service → Networking → VNet Integration**; ensure `subnet-integration` is selected; click **Restart** |
| **`WEBSITE_PRIVATE_IP` is empty (null)** | VNet Integration not configured | Enable VNet Integration (see above); `WEBSITE_PRIVATE_IP` environment variable is set only when VNet integration is active |
| **nslookup from Kudu still shows 20.x.x.x** | Private DNS zone not linked to VNet | Go to **Private DNS Zone (`privatelink.openai.azure.com`) → Virtual Network Links**; verify `vnet-demo` is listed and linked |
| **App returns 502 or can't reach Azure OpenAI** | Using wrong endpoint format (regional instead of resource-specific) | Check `AzureOpenAI__Endpoint` in **App Settings**; must be `https://myai.openai.azure.com/`, not `https://eastus.api.cognitive.microsoft.com/` |
| **curl from laptop works even after disabling public access** | Public access not actually disabled in Azure OpenAI | Go to **Azure OpenAI → Networking → Firewalls and virtual networks**; ensure setting is **"Disabled"** or **"Enabled from selected virtual networks and private endpoints"**; save |
| **Chat returns 401 Unauthorized** | API key invalid or expired | Go to **Azure OpenAI → Keys and Endpoint**; regenerate Key 1 or Key 2; update `AzureOpenAI__ApiKey` in App Settings; restart App Service |
| **Chat returns 404 Not Found** | Deployment name mismatch | Verify `AzureOpenAI__DeploymentName` matches actual deployment name from **Azure OpenAI → Model deployments** (e.g., `gpt-4o-mini`); case-sensitive |
| **Private Endpoint creation fails** | Subnet already has private endpoints or delegation conflict | Ensure `subnet-pe` has **no delegation**; if error persists, create a new subnet and retry |
| **App Service restart hangs or fails** | VNet Integration configuration issue | Try restarting from **App Service → Overview → Restart** in portal; if hung, check VNet Integration status; may need to reconfigure |

---

## 7. Security Notes

1. **API Keys in Configuration**
   - The demo uses app settings for simplicity
   - **Production:** Use Azure Key Vault with managed identity or DefaultAzureCredential
   - Do NOT commit API keys to source control

2. **Private Endpoint Security**
   - Private endpoint secures the **network path** only
   - **Authentication is still required** (API key or managed identity)
   - Without the API key, even internal VNet traffic cannot reach Azure OpenAI

3. **Network Isolation**
   - App Service is isolated to the VNet via VNet Integration
   - Azure OpenAI is isolated to the VNet via Private Endpoint
   - Traffic never crosses the public internet (data exfiltration risk reduced)

4. **DNS Security**
   - Private DNS zone intercepts DNS queries only inside the VNet
   - External lookups still resolve to public IP (expected and harmless)
   - Prevents DNS hijacking or cache poisoning attacks

5. **Firewall Considerations**
   - If Azure OpenAI has additional firewall rules (IP-based or other), private endpoint may bypass some checks
   - Ensure firewall rules align with private endpoint subnet IP range if needed

6. **Compliance & Audit**
   - Private endpoints leave full audit trail in Azure Monitor & App Insights
   - Diagnostics endpoint (`/api/diagnostics`) includes indicators for compliance validation

---

## 8. Demo Script (Talking Points)

### Opening (2 minutes)
> "Welcome. Today I want to show you a real-world security pattern for cloud applications. 
> 
> This app calls Azure OpenAI—the same way many of your applications do. But let me first show you what's happening under the hood. **The app is currently going over the public internet.** 
>
> Let me run a quick diagnostic check to prove it."

### Show Diagnostics (1 minute)
> "See this? The app is detecting a **public IP** (20.x.x.x range). That means when this app talks to Azure OpenAI, the traffic leaves Azure's backbone and goes across the public internet. Anyone with the endpoint URL and an API key can attempt access. 
>
> Of course, the API key is your only security boundary. But what if someone intercepts the traffic? What if there's a compliance requirement that data never leaves your network?
>
> That's where **private endpoints** come in."

### Make the Change (10 minutes)
> "Let me show you how to move this to private networking. I'm going to:
> 1. Create a Virtual Network with two subnets
> 2. Enable VNet Integration on the App Service
> 3. Create a Private Endpoint for Azure OpenAI
> 4. Disable public access
> 
> And here's the key: **I'm not changing any code or configuration files. Same app, same endpoint URL.**"

[Walk through Phase 2 steps 2.1–2.5]

> "Now, here's the magic part. I'm disabling public access on Azure OpenAI. After this, nobody from the internet can reach the endpoint. Not even with a valid API key."

### Show the Result (2 minutes)
> "Same app. Same URL. Look at the diagnostics badge now: **🟢 PRIVATE**. The resolved IP is **10.0.2.5**—that's the private endpoint IP inside our VNet. 
>
> And the chat still works. Same latency or better, because traffic is no longer hopping across the internet."

[Run a chat test]

### Prove Lockdown (2 minutes)
> "From my laptop—which is outside the VNet—let me try to reach the endpoint directly. 
> 
> [Run: `curl https://myai.openai.azure.com/...`]
>
> **403 Forbidden.** The endpoint is completely locked down. Only traffic from inside the VNet can reach it.
>
> **This is the security benefit:** Your data doesn't leave your network. Your endpoints are invisible from the internet. And it took us about 15 minutes to set up."

### Closing (1 minute)
> "In summary:
> - **Before:** Public internet route, egress charges, exposed to DDoS
> - **After:** Private endpoint, faster, no egress charges, locked to VNet only, compliance-friendly
> 
> The cost is minimal—private endpoints are about $7/month per resource. The security and compliance win is huge.
>
> Questions?"

---

## Quick Reference

### Portal Paths
- **Create Azure OpenAI:** Azure Portal → Create a resource → Azure OpenAI
- **Create App Service:** Azure Portal → Create a resource → Web App
- **VNet Integration:** App Service → Settings → Networking → VNet Integration
- **Private Endpoint:** Azure OpenAI → Settings → Networking → + Private endpoint
- **Public Access Toggle:** Azure OpenAI → Settings → Networking → Firewalls and virtual networks

### Key Hostnames
- **App Service:** `https://myapp-pe-demo.azurewebsites.net/`
- **Diagnostics:** `https://myapp-pe-demo.azurewebsites.net/api/diagnostics`
- **Chat API:** `https://myapp-pe-demo.azurewebsites.net/api/ask?prompt=<text>`
- **Kudu Console:** `https://myapp-pe-demo.scm.azurewebsites.net/debug/cmd` or `/powershell`

### IP Ranges to Remember
- **VNet:** `10.0.0.0/16`
- **Integration Subnet:** `10.0.1.0/24`
- **PE Subnet:** `10.0.2.0/24`
- **Public Azure IPs:** `20.x.x.x`, `52.x.x.x`, etc. (varies by region)
- **RFC1918 (Private):** `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`

### Environment Variables
- `WEBSITE_PRIVATE_IP` — Set automatically when VNet Integration is enabled; indicates app has private IP in VNet

---

## Additional Resources

- **Network Evidence Reference:** See `docs/network-evidence.md` for detailed DNS resolution chains and private vs. public indicators
- **App Source:** `src/Program.cs` — Diagnostics and Chat APIs; HTML UI with real-time badge indicator
- **Architecture Decision Log:** `.squad/decisions.md` — Team decisions and findings

---

*Last Updated: 2025-05-05*  
*Demo Duration: ~30 minutes (first run); ~15 minutes (subsequent runs)*  
*Difficulty Level: Intermediate (assumes Azure Portal familiarity)*
