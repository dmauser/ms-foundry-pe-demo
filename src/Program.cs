using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Azure.AI.OpenAI;
using Azure.Identity;
using OpenAI.Chat;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// --- Scenario flag: "PrivateEndpoint" (default) or "NSP" ---
static string Scenario(IConfiguration cfg) => cfg["Demo:Scenario"] ?? "PrivateEndpoint";

// --- HTML UI ---
app.MapGet("/", () => Results.Content(Html.Render(Scenario(app.Configuration)), "text/html"));

// --- Diagnostics API ---
app.MapGet("/api/diagnostics", async () =>
{
    var endpoint = app.Configuration["AzureOpenAI:Endpoint"] ?? "";
    var hostname = "";
    try { hostname = new Uri(endpoint).Host; } catch { hostname = endpoint; }

    var websitePrivateIp = Environment.GetEnvironmentVariable("WEBSITE_PRIVATE_IP");

    string[] resolvedIPs = [];
    bool isPrivate = false;

    try
    {
        var addresses = await Dns.GetHostAddressesAsync(hostname);
        resolvedIPs = addresses
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork || a.AddressFamily == AddressFamily.InterNetworkV6)
            .Select(a => a.ToString())
            .ToArray();
        isPrivate = resolvedIPs.Length > 0 && resolvedIPs.All(IsRfc1918);
    }
    catch (Exception ex)
    {
        resolvedIPs = [$"ERROR: {ex.Message}"];
    }

    return Results.Json(new
    {
        scenario = Scenario(app.Configuration),
        hostname,
        resolvedIPs,
        isPrivate,
        websitePrivateIP = websitePrivateIp,
        vnetIntegrated = !string.IsNullOrEmpty(websitePrivateIp),
        timestamp = DateTime.UtcNow
    });
});

// --- Foundry configuration status API (control-plane: public vs restricted) ---
app.MapGet("/api/foundry-status", async () =>
{
    var resourceId = app.Configuration["AzureOpenAI:ResourceId"] ?? "";
    if (string.IsNullOrWhiteSpace(resourceId))
        return Results.Json(new { status = "Unknown", error = "AzureOpenAI:ResourceId is not configured", publicNetworkAccess = "Unknown" }, statusCode: 500);

    try
    {
        var credential = new DefaultAzureCredential();
        var token = (await credential.GetTokenAsync(
            new Azure.Core.TokenRequestContext(["https://management.azure.com/.default"]))).Token;

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

        // 1) Account properties -> publicNetworkAccess
        var publicNetworkAccess = "Unknown";
        var acctResp = await http.GetAsync($"https://management.azure.com{resourceId}?api-version=2024-10-01");
        if (acctResp.StatusCode == HttpStatusCode.Forbidden)
            return Results.Json(new { status = "Unknown", error = "Managed identity lacks Reader on the Foundry resource (control-plane read denied).", publicNetworkAccess = "Unknown" });
        if (acctResp.IsSuccessStatusCode)
        {
            using var doc = System.Text.Json.JsonDocument.Parse(await acctResp.Content.ReadAsStringAsync());
            if (doc.RootElement.TryGetProperty("properties", out var props) &&
                props.TryGetProperty("publicNetworkAccess", out var pna))
                publicNetworkAccess = pna.GetString() ?? "Unknown";
        }

        // 2) Network Security Perimeter configurations -> accessMode / provisioningState
        var nspAssociated = false;
        var nspMode = "None";
        var nspProvisioningState = "";
        var nspResp = await http.GetAsync($"https://management.azure.com{resourceId}/networkSecurityPerimeterConfigurations?api-version=2024-10-01");
        if (nspResp.IsSuccessStatusCode)
        {
            using var doc = System.Text.Json.JsonDocument.Parse(await nspResp.Content.ReadAsStringAsync());
            if (doc.RootElement.TryGetProperty("value", out var vals) && vals.GetArrayLength() > 0)
            {
                nspAssociated = true;
                var p = vals[0];
                if (p.TryGetProperty("properties", out var props))
                {
                    if (props.TryGetProperty("provisioningState", out var ps)) nspProvisioningState = ps.GetString() ?? "";
                    if (props.TryGetProperty("resourceAssociation", out var ra) &&
                        ra.TryGetProperty("accessMode", out var am)) nspMode = am.GetString() ?? "None";
                }
            }
        }

        var nspEnforced = nspAssociated && string.Equals(nspMode, "Enforced", StringComparison.OrdinalIgnoreCase);
        var restricted = nspEnforced
            || string.Equals(publicNetworkAccess, "Disabled", StringComparison.OrdinalIgnoreCase)
            || string.Equals(publicNetworkAccess, "SecuredByPerimeter", StringComparison.OrdinalIgnoreCase);

        return Results.Json(new
        {
            status = restricted ? "Restricted" : "Public",
            publicNetworkAccess,
            nspAssociated,
            nspMode,
            nspProvisioningState,
            restricted,
            timestamp = DateTime.UtcNow
        });
    }
    catch (Exception ex)
    {
        return Results.Json(new { status = "Unknown", error = ex.Message }, statusCode: 502);
    }
});

// --- Chat / Ask API ---
app.MapGet("/api/ask", async (string? prompt) =>
{
    if (string.IsNullOrWhiteSpace(prompt))
        return Results.BadRequest(new { error = "prompt query parameter is required" });

    // Scenario 2 — route to the private Foundry Agent (File Search grounded).
    if (string.Equals(Scenario(app.Configuration), "Agent", StringComparison.OrdinalIgnoreCase))
    {
        try { return Results.Json(await AgentSupport.AskAsync(app.Configuration, prompt)); }
        catch (Exception ex) { return Results.Json(new { error = ex.Message, prompt }, statusCode: 502); }
    }

    var endpoint = app.Configuration["AzureOpenAI:Endpoint"] ?? "";
    var deploymentName = app.Configuration["AzureOpenAI:DeploymentName"] ?? "gpt-5-mini";

    if (string.IsNullOrEmpty(endpoint))
        return Results.Json(new { error = "AzureOpenAI:Endpoint configuration is missing" }, statusCode: 500);

    try
    {
        var credential = new DefaultAzureCredential();
        var client = new AzureOpenAIClient(new Uri(endpoint), credential);
        var chatClient = client.GetChatClient(deploymentName);

        var sw = Stopwatch.StartNew();
        var response = await chatClient.CompleteChatAsync(
            [new UserChatMessage(prompt)]);
        sw.Stop();

        var content = response.Value.Content.Count > 0 ? response.Value.Content[0].Text : "(no response)";

        return Results.Json(new
        {
            prompt,
            response = content,
            latencyMs = sw.ElapsedMilliseconds,
            model = deploymentName,
            timestamp = DateTime.UtcNow
        });
    }
    catch (Exception ex)
    {
        return Results.Json(new { error = ex.Message, prompt }, statusCode: 502);
    }
});

// --- Agent seed API (Scenario 2): upload manuals -> vector store -> create agent ---
app.MapPost("/api/seed", async (HttpRequest req) =>
{
    if (!string.Equals(Scenario(app.Configuration), "Agent", StringComparison.OrdinalIgnoreCase))
        return Results.Json(new { error = "Seeding is only available in the Agent scenario." }, statusCode: 400);
    var force = string.Equals(req.Query["force"], "true", StringComparison.OrdinalIgnoreCase)
             || string.Equals(req.Query["force"], "1", StringComparison.OrdinalIgnoreCase);
    try { return Results.Json(await AgentSupport.SeedAsync(app.Configuration, force)); }
    catch (Exception ex) { return Results.Json(new { error = ex.Message }, statusCode: 502); }
});

// --- Agent info API (Scenario 2): current agent / vector store / manuals ---
app.MapGet("/api/diag-notool", async () =>
{
    if (!string.Equals(Scenario(app.Configuration), "Agent", StringComparison.OrdinalIgnoreCase))
        return Results.Json(new { error = "Agent scenario only." }, statusCode: 400);
    try { return Results.Json(await AgentSupport.DiagNoToolAsync(app.Configuration)); }
    catch (Exception ex) { return Results.Json(new { error = ex.Message }, statusCode: 502); }
});

app.MapGet("/api/diag-tool", async () =>
{
    if (!string.Equals(Scenario(app.Configuration), "Agent", StringComparison.OrdinalIgnoreCase))
        return Results.Json(new { error = "Agent scenario only." }, statusCode: 400);
    try { return Results.Json(await AgentSupport.DiagToolAsync(app.Configuration)); }
    catch (Exception ex) { return Results.Json(new { error = ex.Message }, statusCode: 502); }
});

app.MapGet("/api/agent-info", () => Results.Json(new
{
    scenario = Scenario(app.Configuration),
    ready = AgentState.Ready,
    agentId = AgentState.AgentId,
    index = AgentState.IndexName,
    grounding = "app-side-rag-over-private-ai-search",
    files = AgentState.FileNames,
    projectEndpoint = app.Configuration["Agent:ProjectEndpoint"],
    projectName = app.Configuration["Agent:ProjectName"],
    model = app.Configuration["Agent:ModelDeployment"],
    timestamp = DateTime.UtcNow
}));

app.Run();

// --- Helpers ---
static bool IsRfc1918(string ip)
{
    if (!IPAddress.TryParse(ip, out var addr)) return false;
    var bytes = addr.GetAddressBytes();
    if (bytes.Length != 4) return false;
    // 10.0.0.0/8
    if (bytes[0] == 10) return true;
    // 172.16.0.0/12
    if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
    // 192.168.0.0/16
    if (bytes[0] == 192 && bytes[1] == 168) return true;
    return false;
}

// --- Embedded HTML ---
static class Html
{
    public static string Render(string scenario) =>
        Template.Replace("__SCENARIO__", scenario);

private const string Template = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Scenario 1 — Azure OpenAI Private Endpoint Demo</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#1a1a2e;color:#e0e0e0;min-height:100vh;padding:2rem}
h1{text-align:center;font-size:1.6rem;margin-bottom:.3rem;color:#fff}
.subtitle{text-align:center;color:#888;margin-bottom:2rem;font-size:.9rem}
.container{max-width:900px;margin:0 auto;display:grid;gap:1.5rem}
.panel{background:#16213e;border-radius:12px;padding:1.5rem;border:1px solid #0f3460}
.panel h2{font-size:1.1rem;margin-bottom:1rem;color:#4fc3f7;display:flex;align-items:center;gap:.5rem}
.badge{display:inline-flex;align-items:center;gap:.4rem;padding:.35rem .8rem;border-radius:20px;font-weight:600;font-size:.85rem}
.badge-private{background:#1b5e20;color:#a5d6a7;border:1px solid #388e3c}
.badge-public{background:#b71c1c;color:#ef9a9a;border:1px solid #d32f2f}
.badge-unknown{background:#37474f;color:#90a4ae;border:1px solid #546e7a}
.info-grid{display:grid;grid-template-columns:140px 1fr;gap:.5rem .8rem;font-size:.9rem}
.info-grid .label{color:#90a4ae;font-weight:500}
.info-grid .value{color:#e0e0e0;word-break:break-all;font-family:'Cascadia Code',monospace,monospace;font-size:.82rem}
.btn{background:#1976d2;color:#fff;border:none;padding:.6rem 1.2rem;border-radius:8px;cursor:pointer;font-size:.85rem;font-weight:500;transition:background .2s}
.btn:hover{background:#1565c0}
.btn:disabled{opacity:.5;cursor:not-allowed}
.chat-input{display:flex;gap:.5rem;margin-bottom:1rem}
.chat-input input{flex:1;background:#0d1b2a;border:1px solid #0f3460;color:#e0e0e0;padding:.6rem .8rem;border-radius:8px;font-size:.9rem}
.chat-input input:focus{outline:none;border-color:#4fc3f7}
.chat-response{background:#0d1b2a;border-radius:8px;padding:1rem;min-height:60px;font-size:.88rem;line-height:1.5;white-space:pre-wrap;border:1px solid #0f3460}
.chat-meta{margin-top:.5rem;font-size:.75rem;color:#607d8b}
.examples{display:flex;flex-wrap:wrap;gap:.4rem;margin:.75rem 0 1rem}
.examples .lbl{width:100%;font-size:.75rem;color:#607d8b;margin-bottom:.15rem}
.chip{background:#0d2a4a;border:1px solid #0f3460;color:#90caf9;padding:.35rem .7rem;border-radius:16px;font-size:.78rem;cursor:pointer;transition:background .2s,border-color .2s}
.chip:hover{background:#123a63;border-color:#4fc3f7}
.error{color:#ef5350}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid #4fc3f7;border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.flow svg{width:100%;height:auto;max-width:920px;display:block;margin:.25rem auto 0}
.flow svg text{font-family:'Segoe UI',system-ui,sans-serif}
</style>
</head>
<body>
<h1 id="pageTitle">🔒 Scenario 1 — Azure OpenAI Private Endpoint Demo</h1>
<p class="subtitle" id="pageSubtitle">Proving private network connectivity to Azure OpenAI via VNet Integration + Private Endpoint</p>
<div class="container">

<!-- Network Diagnostics Panel -->
<div class="panel">
  <h2>🌐 Network Diagnostics <span id="netBadge" class="badge badge-unknown">⏳ CHECKING</span></h2>
  <div class="info-grid">
    <span class="label">Hostname:</span><span class="value" id="dnsHost">—</span>
    <span class="label">Resolved IPs:</span><span class="value" id="dnsIPs">—</span>
    <span class="label" id="lblPrivate">Private (RFC1918):</span><span class="value" id="dnsPrivate">—</span>
    <span class="label" id="lblVnetIP">WEBSITE_PRIVATE_IP:</span><span class="value" id="vnetIP">—</span>
    <span class="label" id="lblVnet">VNet Integrated:</span><span class="value" id="vnetStatus">—</span>
    <span class="label">Checked at:</span><span class="value" id="dnsTime">—</span>
  </div>
  <p class="chat-meta" id="scenarioNote"></p>
  <br/>
  <button class="btn" id="btnDiag" onclick="runDiagnostics()">🔄 Run Diagnostics</button>
</div>

<!-- Foundry Configuration Panel -->
<div class="panel">
  <h2>⚙️ Foundry Configuration <span id="foundryBadge" class="badge badge-unknown">⏳ CHECKING</span></h2>
  <div class="info-grid">
    <span class="label">Public network access:</span><span class="value" id="fPublicAccess">—</span>
    <span class="label">NSP perimeter:</span><span class="value" id="fNsp">—</span>
    <span class="label">NSP access mode:</span><span class="value" id="fNspMode">—</span>
    <span class="label">Provisioning state:</span><span class="value" id="fNspState">—</span>
    <span class="label">Checked at:</span><span class="value" id="fTime">—</span>
  </div>
  <p class="chat-meta" id="foundryNote"></p>
  <br/>
  <button class="btn" id="btnFoundry" onclick="runFoundryStatus()">🔄 Check Foundry</button>
</div>

<!-- Agent / Private Data Panel (Scenario 2 only) -->
<div class="panel" id="agentPanel" style="display:none">
  <h2>🤖 Private Agent &amp; Data Stores <span id="agentBadge" class="badge badge-unknown">⏳ CHECKING</span></h2>
  <div class="info-grid">
    <span class="label">Agent status:</span><span class="value" id="aReady">—</span>
    <span class="label">Agent ID:</span><span class="value" id="aAgentId">—</span>
    <span class="label">Search index:</span><span class="value" id="aIndex">—</span>
    <span class="label">Grounding:</span><span class="value" id="aGrounding">—</span>
    <span class="label">Manuals:</span><span class="value" id="aFiles">—</span>
    <span class="label">Data path:</span><span class="value" id="aDataPath">Private (VNet-injected)</span>
  </div>
  <p class="chat-meta" id="agentNote">The agent runtime is injected into a delegated subnet; Storage, Cosmos DB and AI Search are reachable only over private endpoints (public access disabled).</p>
  <br/>
  <button class="btn" id="btnSeed" onclick="seedAgent()">🌱 Seed manuals &amp; create agent</button>
  <button class="btn" id="btnAgentInfo" onclick="loadAgentInfo()">🔄 Refresh</button>
</div>

<!-- Traffic Flow Diagram (all scenarios) -->
<div class="panel flow" id="flowPanel" style="display:none">

<!-- Scenario 1 — Private Endpoint + VNet Integration -->
<div id="flowS1" style="display:none">
  <h2>🗺️ Traffic Flow — Private Endpoint + VNet Integration</h2>
  <svg viewBox="0 0 900 470" role="img" aria-label="Scenario 1 private-endpoint traffic flow diagram">
    <defs>
      <marker id="ok1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L8,3 L0,6 Z" fill="#66bb6a"/></marker>
      <marker id="blue1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L8,3 L0,6 Z" fill="#4fc3f7"/></marker>
      <marker id="block1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L8,3 L0,6 Z" fill="#ef5350"/></marker>
    </defs>

    <!-- VNet boundary -->
    <rect x="210" y="25" width="505" height="420" rx="12" fill="#0f1f3a" stroke="#7e57c2" stroke-width="2" stroke-dasharray="8 6"/>
    <text x="225" y="47" fill="#b39ddb" font-size="13" font-weight="600">Virtual Network — private · Foundry public access disabled</text>

    <!-- User -->
    <rect x="25" y="95" width="150" height="80" rx="10" fill="#263238" stroke="#90a4ae" stroke-width="1.5"/>
    <text x="100" y="130" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🧑 User</text>
    <text x="100" y="152" fill="#b0bec5" font-size="12" text-anchor="middle">Browser</text>

    <!-- Laptop (direct-to-Foundry blocked) -->
    <rect x="25" y="330" width="150" height="80" rx="10" fill="#3a1414" stroke="#ef5350" stroke-width="1.5"/>
    <text x="100" y="365" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">💻 Laptop</text>
    <text x="100" y="387" fill="#ef9a9a" font-size="12" text-anchor="middle">direct → Foundry</text>

    <!-- App Service (public front door stays reachable) -->
    <rect x="245" y="95" width="190" height="90" rx="10" fill="#0d2a4a" stroke="#4fc3f7" stroke-width="1.5"/>
    <text x="340" y="128" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🌐 App Service</text>
    <text x="340" y="150" fill="#90caf9" font-size="11.5" text-anchor="middle">VNet-integrated · app-subnet</text>

    <!-- Private DNS zone -->
    <rect x="485" y="100" width="205" height="85" rx="10" fill="#1a2740" stroke="#90a4ae" stroke-width="1.5"/>
    <text x="587" y="126" fill="#e0e0e0" font-size="13.5" font-weight="600" text-anchor="middle">🧭 Private DNS zone</text>
    <text x="587" y="147" fill="#b0bec5" font-size="11" text-anchor="middle">privatelink.*.azure.com</text>
    <text x="587" y="165" fill="#a5d6a7" font-size="11" text-anchor="middle">→ private-endpoint IP</text>

    <!-- Private Endpoint -->
    <rect x="245" y="310" width="190" height="90" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="340" y="343" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🔌 Private Endpoint</text>
    <text x="340" y="365" fill="#a5d6a7" font-size="11.5" text-anchor="middle">pe-subnet · private IP</text>

    <!-- Azure OpenAI / Foundry (PaaS behind the PE) -->
    <rect x="735" y="310" width="150" height="90" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="810" y="338" fill="#e0e0e0" font-size="13.5" font-weight="600" text-anchor="middle">🧠 Azure OpenAI</text>
    <text x="810" y="358" fill="#a5d6a7" font-size="11" text-anchor="middle">Foundry · public</text>
    <text x="810" y="375" fill="#ef9a9a" font-size="11" text-anchor="middle">access disabled</text>

    <!-- User -> App Service (public HTTPS, allowed) -->
    <line x1="175" y1="135" x2="241" y2="135" stroke="#4fc3f7" stroke-width="2" marker-end="url(#blue1)"/>
    <rect x="176" y="112" width="62" height="16" rx="4" fill="#16213e"/>
    <text x="207" y="124" fill="#90caf9" font-size="10" text-anchor="middle">HTTPS ▶</text>

    <!-- App Service -> Private DNS (resolve) -->
    <line x1="435" y1="140" x2="483" y2="140" stroke="#66bb6a" stroke-width="2" marker-end="url(#ok1)"/>
    <rect x="415" y="80" width="108" height="16" rx="4" fill="#16213e"/>
    <text x="469" y="92" fill="#a5d6a7" font-size="11" text-anchor="middle">① resolve FQDN</text>

    <!-- App Service -> Private Endpoint (private route) -->
    <line x1="340" y1="185" x2="340" y2="306" stroke="#66bb6a" stroke-width="2" marker-end="url(#ok1)"/>
    <rect x="345" y="235" width="104" height="16" rx="4" fill="#16213e"/>
    <text x="397" y="247" fill="#a5d6a7" font-size="11" text-anchor="middle">② private route</text>

    <!-- Private Endpoint -> Foundry (crosses VNet boundary) -->
    <line x1="435" y1="355" x2="733" y2="355" stroke="#66bb6a" stroke-width="2" marker-end="url(#ok1)"/>
    <rect x="505" y="333" width="150" height="16" rx="4" fill="#16213e"/>
    <text x="580" y="345" fill="#a5d6a7" font-size="11" text-anchor="middle">③ Azure OpenAI call</text>

    <!-- Laptop -> Foundry (direct, blocked) -->
    <line x1="175" y1="370" x2="205" y2="370" stroke="#ef5350" stroke-width="2" stroke-dasharray="6 4" marker-end="url(#block1)"/>
    <text x="216" y="376" fill="#ef5350" font-size="18" font-weight="700" text-anchor="middle">✕</text>
    <text x="100" y="405" fill="#ef9a9a" font-size="10" text-anchor="middle">direct → Foundry blocked</text>
  </svg>
  <p class="chat-meta">The browser reaches the VNet-integrated App Service over <strong>public HTTPS</strong> — the app's front door stays public. The App Service resolves the Foundry FQDN through the <strong>private DNS zone</strong> to the private-endpoint IP, connects over the VNet to the <strong>Private Endpoint</strong>, which forwards to <strong>Azure OpenAI</strong> (public access disabled). A laptop calling Foundry <em>directly</em> is blocked — the public endpoint is off and the name resolves to an unreachable private IP. <span style="color:#90caf9">Blue = public HTTPS (allowed)</span>; <span style="color:#a5d6a7">green = private path (allowed)</span>; <span style="color:#ef9a9a">red dashed = blocked</span>.</p>
</div>

<!-- Scenario 3 — Network Security Perimeter + Managed Identity -->
<div id="flowS3" style="display:none">
  <h2>🗺️ Traffic Flow — Network Security Perimeter (Identity Boundary)</h2>
  <svg viewBox="0 0 900 430" role="img" aria-label="Scenario 3 network security perimeter traffic flow diagram">
    <defs>
      <marker id="ok2" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L8,3 L0,6 Z" fill="#66bb6a"/></marker>
      <marker id="blue2" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L8,3 L0,6 Z" fill="#4fc3f7"/></marker>
      <marker id="block2" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L8,3 L0,6 Z" fill="#ef5350"/></marker>
    </defs>

    <!-- NSP perimeter boundary -->
    <rect x="545" y="35" width="335" height="350" rx="12" fill="#0f2a28" stroke="#4db6ac" stroke-width="2" stroke-dasharray="8 6"/>
    <text x="560" y="57" fill="#80cbc4" font-size="13" font-weight="600">🛡️ Network Security Perimeter — identity boundary</text>

    <!-- User -->
    <rect x="25" y="80" width="150" height="80" rx="10" fill="#263238" stroke="#90a4ae" stroke-width="1.5"/>
    <text x="100" y="115" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🧑 User</text>
    <text x="100" y="137" fill="#b0bec5" font-size="12" text-anchor="middle">Browser</text>

    <!-- Laptop (user token, blocked by NSP) -->
    <rect x="25" y="285" width="150" height="80" rx="10" fill="#3a1414" stroke="#ef5350" stroke-width="1.5"/>
    <text x="100" y="320" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">💻 Laptop</text>
    <text x="100" y="342" fill="#ef9a9a" font-size="12" text-anchor="middle">user token</text>

    <!-- App Service (no VNet integration) -->
    <rect x="250" y="80" width="210" height="95" rx="10" fill="#0d2a4a" stroke="#4fc3f7" stroke-width="1.5"/>
    <text x="355" y="112" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🌐 App Service</text>
    <text x="355" y="133" fill="#90caf9" font-size="11.5" text-anchor="middle">Managed Identity</text>
    <text x="355" y="152" fill="#b0bec5" font-size="11" text-anchor="middle">(no VNet integration)</text>

    <!-- NSP inbound access rule -->
    <rect x="580" y="90" width="270" height="75" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="715" y="116" fill="#e0e0e0" font-size="13.5" font-weight="600" text-anchor="middle">✅ Inbound access rule</text>
    <text x="715" y="137" fill="#a5d6a7" font-size="11" text-anchor="middle">subscription managed identities</text>
    <text x="715" y="155" fill="#a5d6a7" font-size="11" text-anchor="middle">accessMode: Enforced</text>

    <!-- Foundry (public DNS, NSP-enforced) -->
    <rect x="580" y="240" width="270" height="95" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="715" y="272" fill="#e0e0e0" font-size="13.5" font-weight="600" text-anchor="middle">🧠 Azure OpenAI / Foundry</text>
    <text x="715" y="293" fill="#b0bec5" font-size="11" text-anchor="middle">public DNS · NSP-enforced</text>
    <text x="715" y="312" fill="#a5d6a7" font-size="11" text-anchor="middle">public access: Restricted</text>

    <!-- User -> App Service (public HTTPS, allowed) -->
    <line x1="175" y1="120" x2="246" y2="120" stroke="#4fc3f7" stroke-width="2" marker-end="url(#blue2)"/>
    <rect x="176" y="97" width="62" height="16" rx="4" fill="#16213e"/>
    <text x="207" y="109" fill="#90caf9" font-size="10" text-anchor="middle">HTTPS ▶</text>

    <!-- App Service -> Access rule (managed identity, allowed) -->
    <line x1="460" y1="122" x2="578" y2="125" stroke="#66bb6a" stroke-width="2" marker-end="url(#ok2)"/>
    <rect x="478" y="100" width="82" height="16" rx="4" fill="#16213e"/>
    <text x="519" y="112" fill="#a5d6a7" font-size="11" text-anchor="middle">① MI token</text>

    <!-- Access rule -> Foundry -->
    <line x1="715" y1="165" x2="715" y2="238" stroke="#66bb6a" stroke-width="2" marker-end="url(#ok2)"/>
    <rect x="720" y="192" width="74" height="16" rx="4" fill="#16213e"/>
    <text x="757" y="204" fill="#a5d6a7" font-size="11" text-anchor="middle">✓ allowed</text>

    <!-- Laptop -> Foundry (user token, blocked at perimeter) -->
    <line x1="175" y1="325" x2="543" y2="300" stroke="#ef5350" stroke-width="2" stroke-dasharray="6 4" marker-end="url(#block2)"/>
    <text x="553" y="305" fill="#ef5350" font-size="18" font-weight="700" text-anchor="middle">✕</text>
    <rect x="300" y="299" width="150" height="16" rx="4" fill="#16213e"/>
    <text x="375" y="311" fill="#ef9a9a" font-size="11" text-anchor="middle">✕ blocked by NSP</text>
    <text x="375" y="331" fill="#ef9a9a" font-size="10" text-anchor="middle">user identity not in perimeter</text>
  </svg>
  <p class="chat-meta">The App Service is <strong>not</strong> VNet-integrated. It calls Azure OpenAI over the <strong>public</strong> endpoint, but the <strong>Network Security Perimeter</strong> only admits callers whose <strong>managed identity</strong> matches the subscription inbound rule (<code>accessMode: Enforced</code>) — so the App Service (①) is allowed. A laptop using a <strong>user token</strong> is blocked at the perimeter even though the DNS name is public. The boundary is the <strong>identity layer</strong>, not the network. <span style="color:#90caf9">Blue = public HTTPS</span>; <span style="color:#a5d6a7">green = allowed (identity in perimeter)</span>; <span style="color:#ef9a9a">red dashed = blocked by NSP</span>.</p>
</div>

<!-- Scenario 2 — Private Data Path -->
<div id="flowS2" style="display:none">
  <h2>🗺️ Traffic Flow — Private Data Path</h2>
  <svg viewBox="0 0 900 560" role="img" aria-label="Scenario 2 private traffic flow diagram">
    <defs>
      <marker id="arrOk" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth">
        <path d="M0,0 L8,3 L0,6 Z" fill="#66bb6a"/>
      </marker>
      <marker id="arrBlue" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth">
        <path d="M0,0 L8,3 L0,6 Z" fill="#4fc3f7"/>
      </marker>
      <marker id="arrBlock" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth">
        <path d="M0,0 L8,3 L0,6 Z" fill="#ef5350"/>
      </marker>
    </defs>

    <!-- VNet boundary -->
    <rect x="205" y="25" width="680" height="515" rx="12" fill="#0f1f3a" stroke="#7e57c2" stroke-width="2" stroke-dasharray="8 6"/>
    <text x="220" y="47" fill="#b39ddb" font-size="13" font-weight="600">Virtual Network — private · public access disabled</text>

    <!-- User browser -->
    <rect x="25" y="150" width="155" height="85" rx="10" fill="#263238" stroke="#90a4ae" stroke-width="1.5"/>
    <text x="102" y="185" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🧑 User</text>
    <text x="102" y="208" fill="#b0bec5" font-size="12" text-anchor="middle">Browser</text>

    <!-- Laptop (blocked) -->
    <rect x="25" y="380" width="155" height="85" rx="10" fill="#3a1414" stroke="#ef5350" stroke-width="1.5"/>
    <text x="102" y="415" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">💻 Laptop</text>
    <text x="102" y="438" fill="#ef9a9a" font-size="12" text-anchor="middle">direct → Foundry</text>

    <!-- Test WebApp -->
    <rect x="235" y="150" width="175" height="90" rx="10" fill="#0d2a4a" stroke="#4fc3f7" stroke-width="1.5"/>
    <text x="322" y="184" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🌐 Test WebApp</text>
    <text x="322" y="206" fill="#90caf9" font-size="12" text-anchor="middle">VNet-integrated</text>

    <!-- Foundry Agent (network-injected) -->
    <rect x="235" y="350" width="175" height="90" rx="10" fill="#1a1436" stroke="#b39ddb" stroke-width="1.5"/>
    <text x="322" y="384" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🤖 Foundry Agent</text>
    <text x="322" y="406" fill="#d1c4e9" font-size="12" text-anchor="middle">network-injected</text>

    <!-- AI Search -->
    <rect x="610" y="55" width="255" height="70" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="737" y="86" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🔍 Azure AI Search</text>
    <text x="737" y="107" fill="#a5d6a7" font-size="11" text-anchor="middle">vectors · public access disabled</text>

    <!-- Blob Storage -->
    <rect x="610" y="165" width="255" height="70" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="737" y="196" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">📦 Blob Storage</text>
    <text x="737" y="217" fill="#a5d6a7" font-size="11" text-anchor="middle">manuals · public access disabled</text>

    <!-- Cosmos DB -->
    <rect x="610" y="305" width="255" height="70" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="737" y="336" fill="#e0e0e0" font-size="14" font-weight="600" text-anchor="middle">🗄️ Cosmos DB</text>
    <text x="737" y="357" fill="#a5d6a7" font-size="11" text-anchor="middle">threads · public access disabled</text>

    <!-- Foundry account + AOAI -->
    <rect x="610" y="415" width="255" height="70" rx="10" fill="#12351f" stroke="#66bb6a" stroke-width="1.5"/>
    <text x="737" y="446" fill="#e0e0e0" font-size="13.5" font-weight="600" text-anchor="middle">🧠 Foundry + Azure OpenAI</text>
    <text x="737" y="467" fill="#a5d6a7" font-size="11" text-anchor="middle">gpt-5-mini · public access disabled</text>

    <!-- Browser -> WebApp (public inbound, allowed) -->
    <line x1="180" y1="193" x2="231" y2="193" stroke="#4fc3f7" stroke-width="2" marker-end="url(#arrBlue)"/>
    <rect x="176" y="168" width="60" height="16" rx="4" fill="#16213e"/>
    <text x="206" y="180" fill="#90caf9" font-size="10" text-anchor="middle">HTTPS ▶</text>

    <!-- Laptop -> VNet boundary (blocked) -->
    <line x1="180" y1="422" x2="201" y2="422" stroke="#ef5350" stroke-width="2" stroke-dasharray="6 4" marker-end="url(#arrBlock)"/>
    <text x="214" y="429" fill="#ef5350" font-size="18" font-weight="700" text-anchor="middle">✕</text>
    <text x="150" y="460" fill="#ef9a9a" font-size="10" text-anchor="middle">blocked — public access disabled</text>

    <!-- WebApp -> AI Search / Blob (private, allowed) -->
    <line x1="410" y1="185" x2="606" y2="98"  stroke="#66bb6a" stroke-width="2" marker-end="url(#arrOk)"/>
    <line x1="410" y1="205" x2="606" y2="200" stroke="#66bb6a" stroke-width="2" marker-end="url(#arrOk)"/>
    <!-- WebApp -> Foundry Agent (grounded run) -->
    <line x1="322" y1="240" x2="322" y2="346" stroke="#66bb6a" stroke-width="2" marker-end="url(#arrOk)"/>
    <!-- Foundry Agent -> Cosmos / Foundry+AOAI (private, allowed) -->
    <line x1="410" y1="378" x2="606" y2="342" stroke="#66bb6a" stroke-width="2" marker-end="url(#arrOk)"/>
    <line x1="410" y1="405" x2="606" y2="452" stroke="#66bb6a" stroke-width="2" marker-end="url(#arrOk)"/>

    <rect x="450" y="130" width="118" height="16" rx="4" fill="#16213e"/>
    <text x="509" y="142" fill="#a5d6a7" font-size="11" text-anchor="middle">① retrieve (BM25)</text>
    <rect x="458" y="194" width="96" height="16" rx="4" fill="#16213e"/>
    <text x="506" y="206" fill="#a5d6a7" font-size="11" text-anchor="middle">② read manual</text>
    <rect x="330" y="285" width="118" height="16" rx="4" fill="#16213e"/>
    <text x="389" y="297" fill="#a5d6a7" font-size="11" text-anchor="middle">③ grounded run</text>
    <rect x="470" y="346" width="76" height="16" rx="4" fill="#16213e"/>
    <text x="508" y="358" fill="#a5d6a7" font-size="11" text-anchor="middle">threads</text>
    <rect x="444" y="424" width="128" height="16" rx="4" fill="#16213e"/>
    <text x="508" y="436" fill="#a5d6a7" font-size="11" text-anchor="middle">model · gpt-5-mini</text>
  </svg>
  <p class="chat-meta">The browser reaches only the VNet-integrated WebApp over public HTTPS. The WebApp ① retrieves the best-matching manual from private AI Search (BM25) and ② reads manuals from private Blob Storage, then ③ runs the network-injected Foundry Agent — which persists <em>threads</em> to private Cosmos DB and calls the private <em>gpt-5-mini</em> model. Every backend has public access disabled. <span style="color:#ef9a9a">Green = private (allowed); red dashed = direct public access, blocked.</span></p>
</div>
</div>

<!-- Chat Test Panel -->
<div class="panel">
  <h2>💬 Chat Test</h2>
  <div class="chat-input">
    <input type="text" id="promptInput" placeholder="Type a prompt to send to Azure OpenAI..." onkeydown="if(event.key==='Enter')sendChat()"/>
    <button class="btn" id="btnChat" onclick="sendChat()">Send</button>
  </div>
  <div class="examples" id="examples" style="display:none">
    <span class="lbl">Try one of these — each is answered from the private appliance manuals:</span>
    <span class="chip" onclick="askExample(this)">Why is my washer showing error E4?</span>
    <span class="chip" onclick="askExample(this)">My dishwasher won't drain — what does code C2 mean?</span>
    <span class="chip" onclick="askExample(this)">The DryMaster dryer isn't heating. What should I check?</span>
    <span class="chip" onclick="askExample(this)">How often should I clean the washer's drain pump filter?</span>
    <span class="chip" onclick="askExample(this)">What's the #1 cause of long dry times on the DryMaster 500?</span>
    <span class="chip" onclick="askExample(this)">My dishwasher shows leak error C3 — what do I do?</span>
    <span class="chip" onclick="askExample(this)">Which detergent should I use to avoid oversudsing?</span>
  </div>
  <div class="chat-response" id="chatResponse">Response will appear here...</div>
  <div class="chat-meta" id="chatMeta"></div>
</div>

</div>

<script>
const SCENARIO="__SCENARIO__";
const IS_NSP=SCENARIO==="NSP";
const IS_AGENT=SCENARIO==="Agent";

function showFlow(id){
  document.getElementById('flowPanel').style.display='block';
  ['flowS1','flowS2','flowS3'].forEach(function(f){document.getElementById(f).style.display=(f===id)?'block':'none';});
}

function applyScenario(){
  if(IS_AGENT){applyAgent();return;}
  if(!IS_NSP){showFlow('flowS1');return;}
  document.title="Scenario 3 — Azure OpenAI Network Security Perimeter Demo";
  document.getElementById('pageTitle').textContent='🛡️ Scenario 3 — Azure OpenAI Network Security Perimeter Demo';
  document.getElementById('pageSubtitle').textContent='Protecting Azure OpenAI with a Network Security Perimeter + Managed Identity — no VNet Integration required';
  document.getElementById('lblPrivate').textContent='Endpoint DNS:';
  document.getElementById('lblVnetIP').textContent='Access control:';
  document.getElementById('lblVnet').textContent='VNet Integrated:';
  document.getElementById('scenarioNote').innerHTML='Endpoint stays public in DNS by design — the boundary is at the <strong>identity layer</strong>. Use the Chat Test below as the allow/deny proof: from the App Service (managed identity) it succeeds; from a laptop (user token) it is blocked by the perimeter.';
  showFlow('flowS3');
}

function applyAgent(){
  document.title="Scenario 2 — Private Foundry Agent + VNet Injection";
  document.getElementById('pageTitle').textContent='🤖 Scenario 2 — Private Foundry Agent (VNet Injection)';
  document.getElementById('pageSubtitle').textContent='A Foundry Agent injected into a VNet, grounding answers on private appliance manuals in Storage + AI Search — everything private, public access disabled';
  document.getElementById('scenarioNote').innerHTML='This WebApp is VNet-integrated on <code>app-subnet</code> — the only client that can reach the private agent. Seed the manuals, then ask <em>“why is my washer showing error E4?”</em> for a grounded answer with a citation to the private manual.';
  document.getElementById('agentPanel').style.display='block';
  showFlow('flowS2');
  document.getElementById('examples').style.display='flex';
  document.getElementById('promptInput').placeholder='e.g. Why is my washer showing error E4?';
  loadAgentInfo();
}

async function loadAgentInfo(){
  const badge=document.getElementById('agentBadge');
  try{
    const r=await fetch('/api/agent-info');
    const d=await r.json();
    document.getElementById('aReady').textContent=d.ready?'Ready ✓':'Not seeded';
    document.getElementById('aAgentId').textContent=d.agentId||'—';
    document.getElementById('aIndex').textContent=d.index||'—';
    document.getElementById('aGrounding').textContent=d.grounding||'—';
    document.getElementById('aFiles').textContent=(d.files&&d.files.length)?d.files.join(', '):'—';
    if(d.ready){badge.className='badge badge-private';badge.textContent='🟢 AGENT READY';}
    else{badge.className='badge badge-unknown';badge.textContent='🌱 NEEDS SEED';}
  }catch(e){badge.className='badge badge-public';badge.textContent='⚠️ ERROR';}
}

async function seedAgent(){
  const btn=document.getElementById('btnSeed');
  const badge=document.getElementById('agentBadge');
  const note=document.getElementById('agentNote');
  btn.disabled=true;
  badge.className='badge badge-unknown';
  badge.innerHTML='<span class="spinner"></span> SEEDING';
  try{
    const r=await fetch('/api/seed',{method:'POST'});
    const d=await r.json();
    if(d.error){
      badge.className='badge badge-public';badge.textContent='⚠️ ERROR';
      note.innerHTML='<span class="error">'+d.error+'</span>';
    }else{
      await loadAgentInfo();
      note.textContent=d.reused?'Agent already existed — reused.':'Seeded '+((d.files&&d.files.length)||0)+' manuals and created the agent.';
    }
  }catch(e){
    badge.className='badge badge-public';badge.textContent='⚠️ ERROR';
    note.innerHTML='<span class="error">'+e.message+'</span>';
  }
  btn.disabled=false;
}

async function runDiagnostics(){
  const btn=document.getElementById('btnDiag');
  const badge=document.getElementById('netBadge');
  btn.disabled=true;
  badge.className='badge badge-unknown';
  badge.innerHTML='<span class="spinner"></span> CHECKING';
  try{
    const r=await fetch('/api/diagnostics');
    const d=await r.json();
    document.getElementById('dnsHost').textContent=d.hostname||'—';
    document.getElementById('dnsIPs').textContent=(d.resolvedIPs||[]).join(', ')||'—';
    document.getElementById('dnsTime').textContent=d.timestamp?new Date(d.timestamp).toLocaleString():'—';
    if(IS_NSP){
      document.getElementById('dnsPrivate').textContent='Public (by design)';
      document.getElementById('vnetIP').textContent='Managed Identity (NSP subscription inbound rule)';
      document.getElementById('vnetStatus').textContent=d.vnetIntegrated?'Yes':'Not required ✓';
      badge.className='badge badge-private';
      badge.textContent='🛡️ NSP PERIMETER';
    }else{
      document.getElementById('dnsPrivate').textContent=d.isPrivate?'Yes ✓':'No ✗';
      document.getElementById('vnetIP').textContent=d.websitePrivateIP||'(not set — not VNet integrated)';
      document.getElementById('vnetStatus').textContent=d.vnetIntegrated?'Yes ✓':'No ✗';
      if(d.isPrivate){
        badge.className='badge badge-private';
        badge.textContent='🟢 PRIVATE';
      }else{
        badge.className='badge badge-public';
        badge.textContent='🔴 PUBLIC';
      }
    }
  }catch(e){
    badge.className='badge badge-public';
    badge.textContent='⚠️ ERROR';
    document.getElementById('dnsIPs').innerHTML='<span class="error">'+e.message+'</span>';
  }
  btn.disabled=false;
}

async function runFoundryStatus(){
  const btn=document.getElementById('btnFoundry');
  const badge=document.getElementById('foundryBadge');
  btn.disabled=true;
  badge.className='badge badge-unknown';
  badge.innerHTML='<span class="spinner"></span> CHECKING';
  try{
    const r=await fetch('/api/foundry-status');
    const d=await r.json();
    document.getElementById('fPublicAccess').textContent=d.publicNetworkAccess||'—';
    document.getElementById('fNsp').textContent=d.nspAssociated?'Associated':(d.status==='Unknown'?'—':'Not associated');
    document.getElementById('fNspMode').textContent=(d.nspMode&&d.nspMode!=='None')?d.nspMode:'—';
    document.getElementById('fNspState').textContent=d.nspProvisioningState||'—';
    document.getElementById('fTime').textContent=d.timestamp?new Date(d.timestamp).toLocaleString():'—';
    if(d.status==='Restricted'){
      badge.className='badge badge-private';
      badge.textContent='🔒 RESTRICTED';
      document.getElementById('foundryNote').innerHTML=d.nspAssociated
        ?'Foundry is protected by a <strong>Network Security Perimeter</strong> ('+d.nspMode+') — only managed identities in the subscription can reach it.'
        :'Foundry public network access is <strong>'+d.publicNetworkAccess+'</strong> — inbound is restricted.';
    }else if(d.status==='Public'){
      badge.className='badge badge-public';
      badge.textContent='🌐 PUBLIC';
      document.getElementById('foundryNote').innerHTML='Foundry is reachable from the public internet — no NSP enforcement and public network access is enabled.';
    }else{
      badge.className='badge badge-unknown';
      badge.textContent='❔ UNKNOWN';
      document.getElementById('foundryNote').innerHTML='<span class="error">'+(d.error||'Could not determine Foundry configuration.')+'</span>';
    }
  }catch(e){
    badge.className='badge badge-unknown';
    badge.textContent='⚠️ ERROR';
    document.getElementById('foundryNote').innerHTML='<span class="error">'+e.message+'</span>';
  }
  btn.disabled=false;
}

function askExample(el){
  document.getElementById('promptInput').value=el.textContent;
  sendChat();
}

async function sendChat(){
  const input=document.getElementById('promptInput');
  const resp=document.getElementById('chatResponse');
  const meta=document.getElementById('chatMeta');
  const btn=document.getElementById('btnChat');
  const prompt=input.value.trim();
  if(!prompt)return;
  btn.disabled=true;
  resp.textContent='Sending...';
  meta.textContent='';
  try{
    const r=await fetch('/api/ask?prompt='+encodeURIComponent(prompt));
    const d=await r.json();
    if(d.error){
      resp.innerHTML='<span class="error">Error: '+d.error+'</span>';
    }else{
      resp.textContent=d.response;
      let m=`Model: ${d.model} | Latency: ${d.latencyMs}ms | ${new Date(d.timestamp).toLocaleString()}`;
      if(d.citations&&d.citations.length)m='📎 Sources: '+d.citations.join(', ')+'  •  '+m;
      meta.textContent=m;
    }
  }catch(e){
    resp.innerHTML='<span class="error">Network error: '+e.message+'</span>';
  }
  btn.disabled=false;
}

// Auto-run diagnostics on load
applyScenario();
runDiagnostics();
runFoundryStatus();
</script>
</body>
</html>
""";
}
