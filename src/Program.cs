using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Azure;
using Azure.AI.OpenAI;
using OpenAI.Chat;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// --- HTML UI ---
app.MapGet("/", () => Results.Content(Html.Index, "text/html"));

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
        hostname,
        resolvedIPs,
        isPrivate,
        websitePrivateIP = websitePrivateIp,
        vnetIntegrated = !string.IsNullOrEmpty(websitePrivateIp),
        timestamp = DateTime.UtcNow
    });
});

// --- Chat API ---
app.MapGet("/api/ask", async (string? prompt) =>
{
    if (string.IsNullOrWhiteSpace(prompt))
        return Results.BadRequest(new { error = "prompt query parameter is required" });

    var endpoint = app.Configuration["AzureOpenAI:Endpoint"] ?? "";
    var deploymentName = app.Configuration["AzureOpenAI:DeploymentName"] ?? "gpt-4o-mini";
    var apiKey = app.Configuration["AzureOpenAI:ApiKey"] ?? "";

    if (string.IsNullOrEmpty(endpoint) || string.IsNullOrEmpty(apiKey))
        return Results.Json(new { error = "AzureOpenAI configuration is missing" }, statusCode: 500);

    try
    {
        var client = new AzureOpenAIClient(new Uri(endpoint), new AzureKeyCredential(apiKey));
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
public const string Index = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Azure OpenAI — Private Endpoint Demo</title>
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
<h1>🔒 Azure OpenAI — Private Endpoint Demo</h1>
<p class="subtitle">Proving private network connectivity to Azure OpenAI via VNet Integration + Private Endpoint</p>
<div class="container">

<!-- Network Diagnostics Panel -->
<div class="panel">
  <h2>🌐 Network Diagnostics <span id="netBadge" class="badge badge-unknown">⏳ CHECKING</span></h2>
  <div class="info-grid">
    <span class="label">Hostname:</span><span class="value" id="dnsHost">—</span>
    <span class="label">Resolved IPs:</span><span class="value" id="dnsIPs">—</span>
    <span class="label">Private (RFC1918):</span><span class="value" id="dnsPrivate">—</span>
    <span class="label">WEBSITE_PRIVATE_IP:</span><span class="value" id="vnetIP">—</span>
    <span class="label">VNet Integrated:</span><span class="value" id="vnetStatus">—</span>
    <span class="label">Checked at:</span><span class="value" id="dnsTime">—</span>
  </div>
  <br/>
  <button class="btn" id="btnDiag" onclick="runDiagnostics()">🔄 Run Diagnostics</button>
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
    document.getElementById('dnsPrivate').textContent=d.isPrivate?'Yes ✓':'No ✗';
    document.getElementById('vnetIP').textContent=d.websitePrivateIP||'(not set — not VNet integrated)';
    document.getElementById('vnetStatus').textContent=d.vnetIntegrated?'Yes ✓':'No ✗';
    document.getElementById('dnsTime').textContent=d.timestamp?new Date(d.timestamp).toLocaleString():'—';
    if(d.isPrivate){
      badge.className='badge badge-private';
      badge.textContent='🟢 PRIVATE';
    }else{
      badge.className='badge badge-public';
      badge.textContent='🔴 PUBLIC';
    }
  }catch(e){
    badge.className='badge badge-public';
    badge.textContent='⚠️ ERROR';
    document.getElementById('dnsIPs').innerHTML='<span class="error">'+e.message+'</span>';
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
      meta.textContent=`Model: ${d.model} | Latency: ${d.latencyMs}ms | ${new Date(d.timestamp).toLocaleString()}`;
    }
  }catch(e){
    resp.innerHTML='<span class="error">Network error: '+e.message+'</span>';
  }
  btn.disabled=false;
}

// Auto-run diagnostics on load
runDiagnostics();
</script>
</body>
</html>
""";
}
