# Squad Decisions

## Active Decisions

### App Architecture — Single-file Minimal API with Embedded UI
**Author:** Dallas | **Date:** 2026-05-05 | **Status:** Implemented

- .NET 8 minimal API, single Program.cs with embedded HTML (raw string literal)
- Three endpoints: `/` (UI), `/api/diagnostics` (DNS/VNet JSON), `/api/ask` (chat proxy)
- RFC1918 detection for private IP ranges (10.x, 172.16-31.x, 192.168.x)
- Azure.AI.OpenAI v2.1.0 SDK with AzureKeyCredential auth
- Config via environment variables: `AzureOpenAI__Endpoint`, `AzureOpenAI__DeploymentName`, `AzureOpenAI__ApiKey`
- No static files, controllers, or external JS/CSS — zero deployment friction

**Rationale:** Self-contained, easy to deploy to App Service. Single artifact, no build pipeline complexity.

### Network Evidence Reference Document
**Author:** Parker (Infra/DevOps) | **Date:** 2026-05-05 | **Status:** Approved for team

- Created `docs/network-evidence.md` as customer-facing reference card
- Explains observable differences between public and private access patterns
- Provides DNS resolution chain and curl validation examples
- Includes troubleshooting section for common issues

**Rationale:** Standardizes proof points for demo walkthrough. Customers understand exactly what to look for in their own deployments.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
