# Network Validation & Monitoring — Field Guide

A single reference for **network engineers** to verify the *configuration*, *traffic flow*,
and *monitoring* of all three scenarios in this repo. It answers three questions per
scenario:

1. **Is it configured correctly?** — the exact `az` assertions (public access disabled,
   private endpoints approved, DNS zones linked, subnet delegations, NSP profile/rules).
2. **How does traffic actually flow?** — the numbered hops that map to the README diagrams.
3. **How do I watch it?** — where the telemetry lands (Log Analytics / `NSPAccessLogs` /
   Application Insights / flow logs / private-endpoint metrics) and how to prove it live.

> This guide **cross-links** — it does not duplicate — the existing deep-dives:
> - **[network-evidence.md](network-evidence.md)** — public-vs-private evidence tables (Scenario 1).
> - **README → "Validate NSP enforcement with diagnostic logs (Scenario 3)"** — the full
>   `NSPAccessLogs` KQL walkthrough.

---

## The 60-second check (start here)

Two read-only validators assert the *intended* network state and print a **PASS / FAIL /
SKIP** table. They make **no changes** — safe to run against a live lab.

```bash
# Bash
./scripts/98-validate.sh            # validates every scenario that is deployed
./scripts/98-validate.sh -s 2       # only Scenario 2
```
```powershell
# PowerShell
pwsh scripts/98-validate.ps1                 # all deployed scenarios
pwsh scripts/98-validate.ps1 -Scenario 2     # only Scenario 2
```

- **Scenario 1** is discovered from `scripts/.deploy-suffix-s1` → RG `rg-foundry-s1-pe-<suffix>`.
- **Scenario 2** is discovered from `scripts/.deploy-suffix-s2` → RG `rg-foundry-s2-agent-<suffix>`.
- **Scenario 3** is discovered from `scripts/.deploy-suffix-s3` → RG `rg-foundry-s3-nsp-<suffix>`.
- A scenario whose suffix file / resource group is missing is reported **SKIP**, not FAIL.
- Override discovery with `-Suffix <s>` / `-ResourceGroup <rg>` (`-suffix` / `-g` in Bash).
- Exit code is **non-zero** if any *critical* check fails (handy in CI / pre-demo gates).

Prerequisite: `az login` with reader access to the resource group(s). Some data-plane
checks (curl to the Foundry endpoint, `nslookup` from Kudu) run from wherever you invoke
the script, so run them from your laptop to reproduce the "outside the VNet" contrast.

---

## Scenario 1 — Private Endpoint + VNet Integration

**Isolation layer:** network. The Foundry endpoint is reachable **only** from inside the VNet
(via a private endpoint + private DNS). The App Service is VNet-integrated so its outbound
calls resolve the Foundry FQDN to a `10.x` private IP; a laptop cannot reach it.

Resource names (suffix from `scripts/.deploy-suffix-s1`, RG `rg-foundry-s1-pe-<suffix>`, region `centralus`):

| Resource | Name |
|----------|------|
| Foundry (AI Services) | `foundry-demo-ai-<suffix>` |
| VNet (`10.0.0.0/16`) | `foundry-demo-vnet-<suffix>` |
| App Service (VNet-integrated) | `foundry-demo-app-<suffix>` |
| Private DNS zone | `privatelink.cognitiveservices.azure.com` (+ `privatelink.openai.azure.com`) |

### Config to assert

| Check | Command | Expected |
|-------|---------|----------|
| Public access disabled | `az cognitiveservices account show -g rg-foundry-s1-pe-<suffix> -n foundry-demo-ai-<suffix> --query properties.publicNetworkAccess -o tsv` | `Disabled` |
| Private endpoint approved | `az network private-endpoint list -g rg-foundry-s1-pe-<suffix> --query "[].privateLinkServiceConnections[].privateLinkServiceConnectionState.status" -o tsv` | `Approved` |
| DNS zone linked to VNet | `az network private-dns link vnet list -g rg-foundry-s1-pe-<suffix> -z privatelink.cognitiveservices.azure.com --query "[].virtualNetwork.id" -o tsv` | contains `foundry-demo-vnet-<suffix>` |
| DNS A-record is private | `az network private-dns record-set a list -g rg-foundry-s1-pe-<suffix> -z privatelink.cognitiveservices.azure.com --query "[].aRecords[].ipv4Address" -o tsv` | `10.x.x.x` |
| App Service VNet integration | `az webapp show -g rg-foundry-s1-pe-<suffix> -n foundry-demo-app-<suffix> --query "virtualNetworkSubnetId" -o tsv` | subnet resource id (non-empty) |
| Route-all outbound | `az webapp config show -g rg-foundry-s1-pe-<suffix> -n foundry-demo-app-<suffix> --query vnetRouteAllEnabled -o tsv` | `true` |

### Traffic flow

1. Browser → **`foundry-demo-app-<suffix>.azurewebsites.net`** (public front door of the App Service).
2. App code calls the Foundry FQDN `foundry-demo-ai-<suffix>.cognitiveservices.azure.com`.
3. Because the app is VNet-integrated, DNS resolves via the linked private zone → **`10.x` PE IP**.
4. Traffic egresses through the integration subnet → **private endpoint** → Foundry (Azure backbone).
5. A **laptop** resolving the same FQDN gets the *public* IP and is refused (`403`/timeout) —
   public access is disabled. That laptop-vs-app contrast is the network-isolation proof.

### Monitoring

- **App-level functional proof:** `GET /api/diagnostics` → `{ "isPrivate": true, "resolvedIp": "10.x.x.x" }`.
- **Kudu DNS proof:** in the App Service SCM console, `nslookup foundry-demo-ai-<suffix>.cognitiveservices.azure.com` → `10.x` (laptop → public). See **[network-evidence.md](network-evidence.md)**.
- **Private-endpoint health:** `az network private-endpoint-connection list` / the PE's **Connection state** in the portal (`Approved`).
- **Optional NSG / VNet flow logs** on the integration subnet to see the app→PE 443 flows (enable a flow log + Traffic Analytics on the subnet's NSG).

### Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| App gets `403`/timeout after Phase 2 | DNS still returns public IP (zone not linked, or app not route-all) | Verify DNS link + `vnetRouteAllEnabled=true`; restart the app to refresh DNS |
| Kudu `nslookup` → public IP | Private DNS zone missing the A record or not linked to the VNet | Re-check PE created the record-set; confirm the vnet-link |
| Laptop still gets `200` | `publicNetworkAccess` not `Disabled` | Run Phase 2 / set it Disabled |

---

## Scenario 2 — Private Agent + Virtual Network Injection

**Isolation layer:** the whole agent platform. The Foundry **agent runtime is injected** into a
delegated subnet and talks to BYO **Storage + Cosmos DB + AI Search** exclusively over
**private endpoints**, all with **public access disabled**. The only client that can reach it
is the **VNet-integrated test WebApp**. This is the biggest surface — and previously had **no
validation guidance**.

Names here derive from an internal `uniqueString(resourceGroup().id)` (not the suffix file),
so the validator **discovers resources by listing within the RG** rather than constructing
names. Suffix file `scripts/.deploy-suffix-s2` → RG `rg-foundry-s2-agent-<suffix>`, region `westus3`.

VNet layout: `192.168.0.0/16` with `agent-subnet` (`.0.0/24`, delegated
`Microsoft.App/environments`), `pe-subnet` (`.1.0/24`, private endpoints), `app-subnet`
(`.2.0/24`, delegated `Microsoft.Web/serverFarms` for the WebApp).

### Config to assert

| Check | Command (RG = `rg-foundry-s2-agent-<suffix>`) | Expected |
|-------|--------------------------------------------|----------|
| Storage public access off | `az storage account list -g <rg> --query "[].publicNetworkAccess" -o tsv` | `Disabled` |
| Cosmos public access off | `az cosmosdb list -g <rg> --query "[].publicNetworkAccess" -o tsv` | `Disabled` |
| AI Search public access off | `az search service list -g <rg> --query "[].publicNetworkAccess" -o tsv` | `disabled` |
| Foundry public access off | `az cognitiveservices account list -g <rg> --query "[].properties.publicNetworkAccess" -o tsv` | `Disabled` |
| Private endpoints approved | `az network private-endpoint list -g <rg> --query "[].privateLinkServiceConnections[].privateLinkServiceConnectionState.status" -o tsv` | all `Approved` |
| 6 private DNS zones present | `az network private-dns zone list -g <rg> --query "[].name" -o tsv` | includes `services.ai`, `openai`, `cognitiveservices`, `search.windows.net`, `blob.core.windows.net`, `documents.azure.com` privatelink zones |
| DNS zones VNet-linked | `az network private-dns link vnet list -g <rg> -z privatelink.blob.core.windows.net --query "[].virtualNetwork.id" -o tsv` | the agent VNet id (repeat per zone) |
| Agent subnet delegation | `az network vnet subnet show -g <rg> --vnet-name <vnet> -n agent-subnet --query "delegations[].serviceName" -o tsv` | `Microsoft.App/environments` |
| App subnet delegation | `az network vnet subnet show -g <rg> --vnet-name <vnet> -n app-subnet --query "delegations[].serviceName" -o tsv` | `Microsoft.Web/serverFarms` |
| WebApp VNet-integrated | `az webapp show -g <rg> -n <webAppName> --query virtualNetworkSubnetId -o tsv` | id ending `/subnets/app-subnet` |

`<vnet>` and `<webAppName>` are the deployment outputs (`vnetName`, `webAppName`); the
validator resolves them by listing the RG.

### Traffic flow

1. Browser → **test WebApp** public front door (`<webAppName>.azurewebsites.net`).
2. WebApp is integrated into **`app-subnet`** — the only network path to the private agent.
3. WebApp → **Foundry project / agent** (network-injected in `agent-subnet`) over private DNS.
4. The agent grounds answers on the **private AI Search** vector store, whose data came from
   the **private blob Storage** (product manuals); **Cosmos DB** holds threads — all reached
   over **private endpoints** in `pe-subnet`. No data leaves the VNet.
5. The reply carries a **citation to the private manual** → functional proof the private data
   path works. A laptop hitting the Foundry/agent endpoint directly is **blocked**.

### Monitoring

- **Functional proof (from the WebApp):** `GET /api/agent-info` shows the agent/data-store
  status = "Private (injected)"; the **Seed** then **Ask** flow returns a **grounded answer
  with a citation** — end-to-end proof the private stores are reachable *only* from the VNet.
- **Application Insights** (workspace-based, deployed by the scenario) captures agent traces;
  a **Monitor Private Link Scope (AMPLS)** keeps that telemetry on the private link.
- **Private-endpoint connection state** per store: `az network private-endpoint-connection list`
  → all `Approved`. Portal → each store → *Networking* → *Private endpoint connections*.
- **DNS resolution from inside the VNet** (Kudu console of the WebApp): `nslookup` each store
  FQDN → `192.168.1.x` (pe-subnet). From a laptop the same names resolve public and are refused.
- **NSG / VNet flow logs** on `pe-subnet` / `app-subnet` to observe the 443 flows to the PEs.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Seed/Ask fails with a connectivity error | a store still resolves public, or a DNS zone isn't VNet-linked | verify all 6 zones are linked; confirm PEs `Approved`; restart the WebApp |
| Agent can't read Search/Blob | capability-host ordering / RBAC not yet propagated | re-check project→connections→capability-host order; wait for role propagation |
| WebApp can't reach the agent | WebApp not integrated into `app-subnet` | confirm `virtualNetworkSubnetId` ends in `/subnets/app-subnet` |
| Answer has no citation | vector store not seeded / manuals not uploaded | re-run `/api/seed`; confirm blobs landed and the index built |

---

## Scenario 3 — Network Security Perimeter + Managed Identity

**Isolation layer:** identity. The Foundry endpoint has **public access disabled** but is
wrapped in a **Network Security Perimeter (NSP)**. Access is allowed by an **inbound rule
keyed on the App Service's managed identity** — no VNet, no private endpoint. A laptop bearing
a user token is **denied by the perimeter** even with the right RBAC role.

Resource names (same suffix / RG / region as Scenario 1):

| Resource | Name |
|----------|------|
| App Service (no VNet) | `foundry-demo-nsp-app-<suffix>` |
| Network Security Perimeter | `foundry-demo-nsp-<suffix>` |
| Log Analytics workspace | `foundry-demo-law-<suffix>` |
| NSP diagnostic setting | `nsp-access-logs` → table `NSPAccessLogs` |

### Config to assert

| Check | Command | Expected |
|-------|---------|----------|
| Public access disabled | `az cognitiveservices account show -g rg-foundry-s3-nsp-<suffix> -n foundry-demo-ai-<suffix> --query properties.publicNetworkAccess -o tsv` | `Disabled` |
| NSP exists | `az network perimeter list -g rg-foundry-s3-nsp-<suffix> --query "[].name" -o tsv` | `foundry-demo-nsp-<suffix>` |
| Foundry associated to NSP | `az network perimeter association list --perimeter-name foundry-demo-nsp-<suffix> -g rg-foundry-s3-nsp-<suffix> --query "[].properties.accessMode" -o tsv` | `Enforced` (or `Learning` while tuning) |
| Inbound access rule present | `az network perimeter profile access-rule list --perimeter-name foundry-demo-nsp-<suffix> -g rg-foundry-s3-nsp-<suffix> --profile-name <profile> --query "[].name" -o tsv` | at least one rule |
| NSP app has **no** VNet integration | `az webapp show -g rg-foundry-s3-nsp-<suffix> -n foundry-demo-nsp-app-<suffix> --query virtualNetworkSubnetId -o tsv` | empty / `None` |
| Diagnostic logs wired | `az monitor diagnostic-settings list --resource <nsp-id> --query "[?name=='nsp-access-logs'] | length(@)"` | `1` |

> `<profile>` is the NSP's default profile (list with `az network perimeter profile list`).
> The NSP resource id for the diagnostic-settings check comes from
> `az network perimeter show -g rg-foundry-s3-nsp-<suffix> -n foundry-demo-nsp-<suffix> --query id -o tsv`.

### Traffic flow

1. Browser → **`foundry-demo-nsp-app-<suffix>.azurewebsites.net`**.
2. App acquires a token for **its own system-assigned managed identity** (no keys).
3. Call goes to the Foundry **public FQDN** (no PE) but hits the **NSP** first.
4. NSP evaluates the inbound rule → the app's MI **principal is allowed** → request proceeds.
5. A **laptop** with a user token + `Cognitive Services OpenAI User` RBAC still gets
   **denied by the perimeter** (identity not in the allow rule). Each evaluation is logged.

### Monitoring — the perimeter is only trustworthy if you can *see* it

- **`NSPAccessLogs`** in `foundry-demo-law-<suffix>` records every evaluation with
  `ResultAction` = **`Approved`** / **`Denied`**. Full KQL walkthrough (allowed-vs-denied,
  ingestion latency ~30–45 min, the `allLogs`-collects-nothing gotcha, the 13 explicit
  categories) is in the **README → "Validate NSP enforcement with diagnostic logs (Scenario 3)"**.
- Quick query:

  ```kusto
  NSPAccessLogs
  | where ServiceFqdn has "foundry-demo-ai"
  | project TimeGenerated, ResultAction, Profile, MatchedRule, SourceIpAddress
  | order by TimeGenerated desc
  ```

- **Learning vs Enforced:** run in **Learning** mode first to observe would-be denials
  without blocking, then flip to **Enforced**. The association's `accessMode` tells you which.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Laptop gets `401 "…lacks the required data action…"` | RBAC rejected *before* the perimeter | Grant the tester `Cognitive Services OpenAI User`; wait a few min; retry (now you'll see the NSP *Denied*) |
| `NSPAccessLogs` table never appears | diag setting used `allLogs` (unsupported) or no traffic yet | Ensure the 13 categories are explicit (the bicep does this); generate traffic; wait ~30–45 min |
| App call denied too | app MI not in an inbound allow rule | Add/verify the inbound rule keyed on the app's managed identity |

---

## Cross-scenario verification matrix

| What a network engineer checks | Scenario 1 (PE + VNet) | Scenario 2 (Injected agent) | Scenario 3 (NSP + MI) |
|--------------------------------|------------------------|------------------------------|------------------------|
| **Isolation layer** | Network (private endpoint) | Network — whole agent platform | Identity (managed identity) |
| **Foundry `publicNetworkAccess`** | `Disabled` | `Disabled` | `Disabled` |
| **Private endpoint(s)** | 1 (Foundry) `Approved` | Storage + Cosmos + Search + Foundry, all `Approved` | none (by design) |
| **Private DNS zones** | 1–2 (`cognitiveservices`/`openai`) | 6 (ai/openai/cognitive/search/blob/cosmos) | none |
| **App VNet integration** | Yes (`foundry-demo-app`) | Yes (test WebApp in `app-subnet`) | **No** (identity-only) |
| **Subnet delegations** | integration subnet | `agent-subnet`→App, `app-subnet`→Web | none |
| **What blocks a laptop** | Public access off + private DNS | Public access off + private DNS | NSP identity rule |
| **Primary telemetry** | `/api/diagnostics`, PE state, flow logs | App Insights + PE state + grounded citation | **`NSPAccessLogs`** (Approved/Denied) |
| **Functional proof** | `isPrivate:true`, `10.x` | grounded answer w/ private-manual citation | app allowed / laptop denied in logs |
| **One-command check** | `98-validate -s 1` | `98-validate -s 2` | `98-validate -s 3` |

## Monitoring stack per scenario

| Telemetry source | Scenario 1 | Scenario 2 | Scenario 3 |
|------------------|:---------:|:---------:|:---------:|
| App `/api/diagnostics` (isPrivate/resolvedIp) | ✅ | ✅ (`/api/agent-info`) | – (identity path) |
| Log Analytics **`NSPAccessLogs`** | – | – | ✅ (`foundry-demo-law-<suffix>`) |
| Application Insights (agent traces) | – | ✅ (AMPLS private) | – |
| Private-endpoint connection state / metrics | ✅ | ✅ (per store) | – |
| Private-DNS resolution from Kudu (`nslookup`) | ✅ | ✅ | – |
| NSG / VNet flow logs (+ Traffic Analytics) | optional | optional (`pe`/`app` subnets) | – |
| Connection Monitor (synthetic 443 to PE) | optional | optional | – |

---

## Notes

- The `98-validate` scripts are **read-only** — assertions only, no writes — so they are safe
  to run against a live, billing lab. They do **not** deploy or tear anything down.
- A scenario that isn't currently deployed is reported **SKIP** (missing suffix file / RG),
  never FAIL, so `98-validate` (all) is safe to run at any time.
- `az` output shapes vary slightly across extension versions; the scripts prefer `--query` +
  `-o tsv` and treat a genuinely-missing optional field as **SKIP** rather than **FAIL**.
- For the Scenario-1 public-vs-private evidence deep-dive (nslookup/curl/diagnostics tables
  with example output), see **[network-evidence.md](network-evidence.md)**.
