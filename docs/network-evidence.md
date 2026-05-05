# Network Evidence Reference

How to verify whether your application is using public or private access to Azure resources.

---

## Evidence of Public Access (Before Private Endpoint)

These signs indicate traffic is **routing over the public internet**:

| Check | What to look for | Why it matters |
|-------|-----------------|----------------|
| **nslookup from laptop** | Resolves to `20.x.x.x` or `52.x.x.x` (Azure public IP range) | App resource is publicly routable |
| **nslookup from App Service Kudu** | Also resolves to public IP (same as laptop) | No Private Endpoint intercepts DNS |
| **curl to endpoint from laptop** | Returns `200 OK` | Public endpoint accepts traffic from internet |
| **App `/api/diagnostics`** | `"isPrivate": false` | Code detects public connectivity |
| **Resolved IP in diagnostics** | `"resolvedIp": "20.x.x.x"` (or higher range) | Confirmed public IP resolution |

### Example Output (Public)
```
# From laptop
$ nslookup myresource.openai.azure.com
Name:    myresource.openai.azure.com
Address: 20.42.111.222

# From App Service Kudu console
$ nslookup myresource.openai.azure.com
Address: 20.42.111.222

# Curl from laptop
$ curl https://myresource.openai.azure.com/...
HTTP/1.1 200 OK

# App diagnostics
{
  "isPrivate": false,
  "resolvedIp": "20.42.111.222",
  "vnetIntegration": false
}
```

---

## Evidence of Private Access (After Private Endpoint + VNet Integration)

These signs indicate traffic is **staying on Azure's backbone network**:

| Check | What to look for | Why it matters |
|-------|-----------------|----------------|
| **nslookup from laptop** | Still resolves to public IP | Laptop is outside the VNet — expected |
| **nslookup from App Service Kudu** | Resolves to `10.x.x.x` (private endpoint IP) | Private DNS zone override works from inside VNet |
| **curl to endpoint from laptop** | Returns `403 Forbidden` or connection refused | Public access is disabled — good |
| **App `/api/diagnostics`** | `"isPrivate": true` | Code confirms private connectivity |
| **Resolved IP in diagnostics** | `"resolvedIp": "10.x.x.x"` | Private endpoint address range |
| **WEBSITE_PRIVATE_IP env var** | Populated (e.g., `10.0.1.42`) | App Service has VNet integration enabled |

### Example Output (Private)
```
# From laptop (outside VNet)
$ nslookup myresource.openai.azure.com
Name:    myresource.openai.azure.com
Address: 20.42.111.222
(Same public IP — no access from here)

# From App Service Kudu (inside VNet)
$ nslookup myresource.openai.azure.com
Name:    myresource.openai.azure.com
Address: 10.0.2.5

# Curl from laptop
$ curl https://myresource.openai.azure.com/...
HTTP/1.1 403 Forbidden
(Access denied — public endpoint is blocked)

# App diagnostics
{
  "isPrivate": true,
  "resolvedIp": "10.0.2.5",
  "vnetIntegration": true,
  "vnetIp": "10.0.1.42"
}
```

---

## The "Aha Moment" for Customers

**Same app. Same endpoint URL. Same code. Different network paths.**

### Before Private Endpoint
- App makes request to `myresource.openai.azure.com`
- DNS resolves to **public IP** on Azure's edge
- Traffic exits Azure, goes over the **public internet**
- Anyone with the endpoint URL can attempt access
- Subject to DDoS, internet latency, egress charges

### After Private Endpoint + VNet Integration
- App makes request to `myresource.openai.azure.com` (no code change!)
- DNS resolves to **private endpoint IP** (10.x.x.x) via Private DNS zone
- Traffic stays inside **Azure's backbone network**
- Resource is **invisible from the internet** — only accessible from the VNet
- Security, performance, and cost optimization in one architectural change

**From your laptop:** You lose direct access (403). This is the security benefit.  
**From the app:** Everything still works — just faster and more secure.

---

## DNS Resolution Chain (The Technical Detail)

### Public Resolution (Outside VNet)
```
myresource.openai.azure.com
  → CNAME to myresource.privatelink.openai.azure.com (Azure always adds this)
  → A record resolves to 20.42.111.222 (public IP)
```
The CNAME exists, but without a Private DNS zone override, it still points to public IP.

### Private Resolution (Inside VNet with Private DNS Zone)
```
myresource.openai.azure.com
  → CNAME to myresource.privatelink.openai.azure.com
  → Private DNS zone intercepts: points to 10.0.2.5 (private endpoint IP)
  → Traffic reaches resource via private network
```

**Why resource-specific endpoints matter:** Regional endpoints (e.g., `myregion.api.cognitive.microsoft.com`) don't play nicely with private endpoints. Always use the resource-specific FQDN (`myresource.openai.azure.com`).

---

## Quick Validation Checklist

```bash
# From your laptop (control check — should always see public IP)
nslookup myresource.openai.azure.com
curl -v https://myresource.openai.azure.com/health

# From App Service Kudu console (azure.com > App Service > Advanced Tools > Go)
nslookup myresource.openai.azure.com
curl https://api-endpoint:port/diagnostics

# Check environment inside App Service
# Should see WEBSITE_PRIVATE_IP set if VNet integration is active
```

| Scenario | DNS from Kudu | curl from laptop | App diagnostics |
|----------|---------------|-----------------|-----------------|
| **Before** | Public IP | 200 OK | `isPrivate: false` |
| **After** | 10.x.x.x | 403 Forbidden | `isPrivate: true, resolvedIp: 10.x.x.x` |

---

## Troubleshooting: What If It Doesn't Work?

| Symptom | Likely Cause | Check |
|---------|-------------|-------|
| nslookup from Kudu still shows public IP | Private DNS zone not linked to subnet | Azure Portal > Private DNS Zones > VNet Links |
| App can't reach endpoint with 403 | Endpoint's firewall blocks App Service subnet | Azure Portal > Endpoint > Networking > Firewall Rules |
| VNet integration but diagnostics shows public | App not using resource-specific FQDN | Verify URL in code/config ends in `.openai.azure.com` |
| `WEBSITE_PRIVATE_IP` empty | VNet integration not enabled | Azure Portal > App Service > Networking > VNet Integration |

---

*Reference: This document explains the observables for the Private Endpoint + VNet Integration pattern. See your architecture diagram for subnet, endpoint, and DNS zone topology.*
