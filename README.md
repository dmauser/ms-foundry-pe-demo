# Azure OpenAI Private Endpoint Demo

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![.NET 8](https://img.shields.io/badge/.NET-8.0-blue)](https://dotnet.microsoft.com/download/dotnet/8.0)
[![Azure](https://img.shields.io/badge/Azure-OpenAI-0078D4)](https://azure.microsoft.com/en-us/products/ai-services/openai-service/)

## Overview

This demo showcases the migration from public to private endpoint access for Azure OpenAI using App Service VNet Integration. It illustrates how to securely connect your applications to Azure AI services while maintaining network isolation and compliance requirements.

**Key Insight:** App Service remains publicly accessible (users can reach it), but all outbound connections to Azure OpenAI transit through a private endpoint, demonstrating a hybrid-access security pattern commonly used in enterprise environments.

---

## Architecture

### Before: Public Access
```
┌─────────────┐
│    User     │
└──────┬──────┘
       │ (HTTPS)
       ▼
┌──────────────────────────┐
│   App Service (public)   │
└──────┬───────────────────┘
       │ (HTTPS, public route)
       ▼
    Internet
       │
       ▼
┌──────────────────────────────┐
│  Azure OpenAI (public)       │
│  *.openai.azure.com          │
└──────────────────────────────┘
```

### After: Private Access
```
┌─────────────┐
│    User     │
└──────┬──────┘
       │ (HTTPS)
       ▼
┌──────────────────────────────────────────┐
│      App Service (public)                │
│      ↓ VNet Integration                  │
│  ┌────────────────────────────────────┐  │
│  │   Azure Virtual Network (VNet)     │  │
│  │                                    │  │
│  │  ┌──────────────────────────────┐  │  │
│  │  │ integration-subnet           │  │  │
│  │  │ (delegated to               │  │  │
│  │  │  Microsoft.Web/serverFarms) │  │  │
│  │  └──────────────────────────────┘  │  │
│  │                                    │  │
│  │  ┌──────────────────────────────┐  │  │
│  │  │ pe-subnet                    │  │  │
│  │  │ ┌────────────────────────┐   │  │  │
│  │  │ │ Private Endpoint       │   │  │  │
│  │  │ │ (10.x.x.x via RFC1918)│   │  │  │
│  │  │ └────────────────────────┘   │  │  │
│  │  └──────────────────────────────┘  │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
       │ (Private route via PE)
       ▼
┌──────────────────────────────┐
│  Azure OpenAI (private)      │
│  RFC1918 IP (10.x.x.x)       │
│  Private DNS Zone:           │
│  privatelink.openai.azure.com│
└──────────────────────────────┘
```

---

## Key Concepts

✅ **App Service Remains Public** — Users can continue accessing your application via its public URL.

✅ **Private Outbound Access** — All communication from App Service to Azure OpenAI flows through the private endpoint, never traversing the public internet.

✅ **Resource-Specific Endpoints** — Uses `https://<resource>.openai.azure.com/` (not regional endpoints) for deterministic private DNS resolution.

✅ **Private DNS Integration** — The zone `privatelink.openai.azure.com` is linked to your VNet, resolving the Azure OpenAI resource to its private RFC1918 IP address.

✅ **Network Evidence** — The demo UI displays actual DNS resolution results and detects whether traffic is flowing privately (RFC1918) or publicly.

---

## Demo Application

### Technology Stack
- **.NET 8** minimal API backend
- **Dark-themed web UI** with real-time diagnostics
- **Azure OpenAI SDK** for model interaction

### Features
- 🟢 **PRIVATE** badge — Confirms RFC1918 (10.x.x.x) connectivity
- 🔴 **PUBLIC** badge — Shows public internet routing
- **DNS Resolution Panel** — Displays resolved IPs for the Azure OpenAI endpoint
- **Chat Interface** — Test live connectivity to your deployed model
- **Diagnostics Endpoint** — JSON-formatted network evidence for programmatic validation

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Serves the web UI |
| `/api/diagnostics` | GET | Returns network diagnostics (DNS, IP detection, routing) |
| `/api/ask?prompt=...` | GET | Proxies chat requests to Azure OpenAI |

---

## Prerequisites

- **Azure Subscription** with OpenAI resource quota
- **Azure CLI** (v2.50+)
- **.NET 8 SDK** ([download](https://dotnet.microsoft.com/download/dotnet/8.0))
- **GitHub CLI** (optional, for publishing)

---

## Quick Start (Local Development)

```bash
# Navigate to the source directory
cd src

# Run the application
dotnet run

# Open your browser
# http://localhost:5000
```

The app will start on `http://localhost:5000` with hot reload enabled.

---

## Azure Deployment

### High-Level Steps

1. **Create Resource Group**
   ```bash
   az group create --name myRG --location eastus
   ```

2. **Create Azure OpenAI Resource**
   - Deploy a `gpt-4o-mini` model

3. **Create App Service Plan & App**
   ```bash
   az appservice plan create --name myAppPlan --resource-group myRG --sku B1 --is-linux
   az webapp create --name myApp --plan myAppPlan --resource-group myRG --runtime "dotnetcore:8.0"
   ```

4. **Configure Application Settings**
   ```bash
   az webapp config appsettings set --name myApp --resource-group myRG --settings \
     AzureOpenAI__Endpoint="https://<your-resource>.openai.azure.com/" \
     AzureOpenAI__DeploymentName="gpt-4o-mini" \
     AzureOpenAI__ApiKey="<your-api-key>"
   ```

5. **Deploy Application**
   ```bash
   cd src
   dotnet publish -c Release -o ./publish
   az webapp deployment source config-zip --name myApp --resource-group myRG --src-path ./publish.zip
   ```

6. **Test Public Access**
   - Visit `https://<myApp>.azurewebsites.net/`
   - Confirm 🔴 **PUBLIC** badge

7. **Create Virtual Network & Subnets**
   ```bash
   az network vnet create --name myVNet --resource-group myRG --address-prefix 10.0.0.0/16
   az network vnet subnet create --name integration-subnet --vnet-name myVNet --resource-group myRG \
     --address-prefix 10.0.1.0/24 --delegations Microsoft.Web/serverFarms
   az network vnet subnet create --name pe-subnet --vnet-name myVNet --resource-group myRG \
     --address-prefix 10.0.2.0/24
   ```

8. **Enable VNet Integration**
   ```bash
   az webapp vnet-integration add --name myApp --resource-group myRG --vnet myVNet --subnet integration-subnet
   ```

9. **Create Private Endpoint & Private DNS**
   - See [Full Portal Walkthrough](docs/demo-walkthrough.md) for detailed steps

10. **Disable Public Network Access on Azure OpenAI**
    ```bash
    az cognitiveservices account update --name <your-resource> --resource-group myRG \
      --public-network-access false
    ```

11. **Test Private Access**
    - Visit `https://<myApp>.azurewebsites.net/`
    - Confirm 🟢 **PRIVATE** badge

📖 **Full instructions:** See [docs/demo-walkthrough.md](docs/demo-walkthrough.md) for detailed Azure Portal steps.

---

## App Settings Reference

| Setting | Description | Example |
|---------|-------------|---------|
| `AzureOpenAI__Endpoint` | Azure OpenAI resource endpoint | `https://myresource.openai.azure.com/` |
| `AzureOpenAI__DeploymentName` | Deployment name within your resource | `gpt-4o-mini` |
| `AzureOpenAI__ApiKey` | API key for authentication | `(generated from portal)` |

---

## Validation & Verification

### From Your Laptop (Before Private Endpoint)

```bash
# Should resolve to a public IP
nslookup <your-resource>.openai.azure.com

# Should succeed (public access)
curl https://<your-resource>.openai.azure.com/openai/deployments \
  -H "api-key: <your-api-key>"
```

### From App Service (via Kudu Console or SSH)

```bash
# Diagnose network routing
curl https://<myApp>.azurewebsites.net/api/diagnostics | jq

# Test model connectivity
curl "https://<myApp>.azurewebsites.net/api/ask?prompt=Hello"
```

### Expected Behavior Matrix

| Scenario | Direct from Laptop | From App Service |
|----------|-------------------|-----------------|
| **Before Setup (Public)** | ✅ 200 OK, public IP | ✅ 200 OK, 🔴 PUBLIC |
| **After VNet Integration Only** | ✅ 200 OK, public IP | ✅ 200 OK, 🔴 PUBLIC |
| **After Private Endpoint + Public Disabled** | ❌ 403 Forbidden | ✅ 200 OK, 🟢 PRIVATE |

---

## Security Best Practices

🔒 **Never commit API keys** — Use environment variables, App Service app settings, or Key Vault.

🔒 **Use Key Vault References** — Reference secrets via `@Microsoft.KeyVault(...)` syntax in app settings.

🔒 **Rotate Keys Regularly** — Especially after demos or before production deployments.

🔒 **Prefer Managed Identity** — In production, use Azure Managed Identity instead of API keys.

🔒 **Network Isolation** — Ensure private endpoints are properly isolated; monitor outbound traffic.

---

## Additional Documentation

- 📖 [Full Azure Portal Walkthrough](docs/demo-walkthrough.md) — Step-by-step instructions for private endpoint configuration
- 🔍 [Network Evidence Reference](docs/network-evidence.md) — Understanding DNS resolution and RFC1918 detection

---

## Project Structure

```
.
├── src/
│   ├── Program.cs                 # Minimal API configuration
│   ├── OpenAIService.cs           # Azure OpenAI SDK integration
│   ├── DiagnosticsService.cs      # Network diagnostics & DNS resolution
│   ├── wwwroot/
│   │   ├── index.html             # Dark-themed web UI
│   │   ├── css/style.css          # Styling
│   │   └── js/app.js              # Client-side logic
│   └── azure-openai-demo.csproj   # Project file
├── docs/
│   ├── demo-walkthrough.md        # Portal configuration guide
│   └── network-evidence.md        # Network diagnostics reference
├── README.md                       # This file
└── LICENSE                         # MIT License
```

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

## Support & Questions

For questions or issues with this demo:
1. Check [docs/network-evidence.md](docs/network-evidence.md) for troubleshooting
2. Review the [Full Walkthrough](docs/demo-walkthrough.md)
3. Open an issue on GitHub

---

**Demo Created:** 2026 | **Last Updated:** May 2026
