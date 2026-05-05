# Project Context

- **Owner:** Daniel Mauser
- **Project:** ms-foundry-pe-demo — Azure AI private endpoint demo
- **Stack:** .NET 8, ASP.NET Core, Azure App Service, Azure AI Foundry/OpenAI, VNet, Private Endpoints, Private DNS
- **Created:** 2026-05-05

## Work Completed

**2026-05-05: Built demo app with private endpoint evidence UI**
- Implemented .NET 8 Minimal API with embedded HTML UI
- Three endpoints: `/` (UI), `/api/diagnostics` (DNS/VNet detection), `/api/ask` (Azure OpenAI proxy)
- RFC1918 detection logic for identifying private IP ranges
- Professional dark-theme UI with green/red badge for private/public state indication
- Single artifact deployment: no external dependencies, zero deployment friction
- Azure.AI.OpenAI v2.1.0 SDK integrated with AzureKeyCredential
- Configuration via standard .NET environment variables

**Decision Recorded:** App Architecture — Single-file Minimal API with Embedded UI

## Learnings

<!-- Append new learnings below. -->
