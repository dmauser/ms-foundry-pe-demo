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

    // Scenario 3 — route to the private Foundry Agent (File Search grounded).
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

// --- Agent seed API (Scenario 3): upload manuals -> vector store -> create agent ---
app.MapPost("/api/seed", async (HttpRequest req) =>
{
    if (!string.Equals(Scenario(app.Configuration), "Agent", StringComparison.OrdinalIgnoreCase))
        return Results.Json(new { error = "Seeding is only available in the Agent scenario." }, statusCode: 400);
    var force = string.Equals(req.Query["force"], "true", StringComparison.OrdinalIgnoreCase)
             || string.Equals(req.Query["force"], "1", StringComparison.OrdinalIgnoreCase);
    try { return Results.Json(await AgentSupport.SeedAsync(app.Configuration, force)); }
    catch (Exception ex) { return Results.Json(new { error = ex.Message }, statusCode: 502); }
});

// --- Agent info API (Scenario 3): current agent / vector store / manuals ---
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
.error{color:#ef5350}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid #4fc3f7;border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
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

<!-- Agent / Private Data Panel (Scenario 3 only) -->
<div class="panel" id="agentPanel" style="display:none">
  <h2>🤖 Private Agent &amp; Data Stores <span id="agentBadge" class="badge badge-unknown">⏳ CHECKING</span></h2>
  <div class="info-grid">
    <span class="label">Agent status:</span><span class="value" id="aReady">—</span>
    <span class="label">Agent ID:</span><span class="value" id="aAgentId">—</span>
    <span class="label">Vector store:</span><span class="value" id="aVectorStore">—</span>
    <span class="label">Manuals:</span><span class="value" id="aFiles">—</span>
    <span class="label">Data path:</span><span class="value" id="aDataPath">Private (VNet-injected)</span>
  </div>
  <p class="chat-meta" id="agentNote">The agent runtime is injected into a delegated subnet; Storage, Cosmos DB and AI Search are reachable only over private endpoints (public access disabled).</p>
  <br/>
  <button class="btn" id="btnSeed" onclick="seedAgent()">🌱 Seed manuals &amp; create agent</button>
  <button class="btn" id="btnAgentInfo" onclick="loadAgentInfo()">🔄 Refresh</button>
</div>

<!-- Chat Test Panel -->
<div class="panel">
  <h2>💬 Chat Test</h2>
  <div class="chat-input">
    <input type="text" id="promptInput" placeholder="Type a prompt to send to Azure OpenAI..." onkeydown="if(event.key==='Enter')sendChat()"/>
    <button class="btn" id="btnChat" onclick="sendChat()">Send</button>
  </div>
  <div class="chat-response" id="chatResponse">Response will appear here...</div>
  <div class="chat-meta" id="chatMeta"></div>
</div>

</div>

<script>
const SCENARIO="__SCENARIO__";
const IS_NSP=SCENARIO==="NSP";
const IS_AGENT=SCENARIO==="Agent";

function applyScenario(){
  if(IS_AGENT){applyAgent();return;}
  if(!IS_NSP)return;
  document.title="Scenario 2 — Azure OpenAI Network Security Perimeter Demo";
  document.getElementById('pageTitle').textContent='🛡️ Scenario 2 — Azure OpenAI Network Security Perimeter Demo';
  document.getElementById('pageSubtitle').textContent='Protecting Azure OpenAI with a Network Security Perimeter + Managed Identity — no VNet Integration required';
  document.getElementById('lblPrivate').textContent='Endpoint DNS:';
  document.getElementById('lblVnetIP').textContent='Access control:';
  document.getElementById('lblVnet').textContent='VNet Integrated:';
  document.getElementById('scenarioNote').innerHTML='Endpoint stays public in DNS by design — the boundary is at the <strong>identity layer</strong>. Use the Chat Test below as the allow/deny proof: from the App Service (managed identity) it succeeds; from a laptop (user token) it is blocked by the perimeter.';
}

function applyAgent(){
  document.title="Scenario 3 — Private Foundry Agent + VNet Injection";
  document.getElementById('pageTitle').textContent='🤖 Scenario 3 — Private Foundry Agent (VNet Injection)';
  document.getElementById('pageSubtitle').textContent='A Foundry Agent injected into a VNet, grounding answers on private appliance manuals in Storage + AI Search — everything private, public access disabled';
  document.getElementById('scenarioNote').innerHTML='This WebApp is VNet-integrated on <code>app-subnet</code> — the only client that can reach the private agent. Seed the manuals, then ask <em>“why is my washer showing error E4?”</em> for a grounded answer with a citation to the private manual.';
  document.getElementById('agentPanel').style.display='block';
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
    document.getElementById('aVectorStore').textContent=d.vectorStoreId||'—';
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
