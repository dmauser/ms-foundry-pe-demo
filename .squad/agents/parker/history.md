# Project Context

- **Owner:** Daniel Mauser
- **Project:** ms-foundry-pe-demo — Azure AI private endpoint demo
- **Stack:** .NET 8, ASP.NET Core, Azure App Service, Azure AI Foundry/OpenAI, VNet, Private Endpoints, Private DNS
- **Created:** 2026-05-05

## Work Completed

**2026-05-05: Created network evidence reference documentation**
- Built `docs/network-evidence.md` as customer-facing reference card
- Documented observable differences between public vs. private access patterns
- Provided DNS resolution chain explanation with Private DNS zone override
- Created concrete curl examples and validation commands for before/after scenarios
- Included quick reference commands for laptop vs. Kudu console validation
- Added troubleshooting table for common issues (DNS failures, connectivity problems, latency)
- Aligned with Dallas's demo app diagnostics endpoints for seamless validation

**Decision Recorded:** Network Evidence Reference Document

## Learnings

**2026-05-05: Azure AI Foundry Deployment Learnings (Coordinator phase)**
- AIServices kind (Foundry) is the target architecture when subscription enforces disableLocalAuth=true (no standalone Azure OpenAI)
- GlobalStandard SKU is required when Standard SKU is not available in the chosen region (centralus)
- Custom domain endpoint (foundry-demo-ai.cognitiveservices.azure.com) is essential for Private Endpoint DNS zone override in Phase 2
- Resource naming with consistent prefix (foundry-demo-*) simplifies cross-resource references in PE configuration
- Phase 2 will require: private endpoint creation, private DNS zone linking, subnet/VNet Integration, and disablePublicNetworkAccess toggle
