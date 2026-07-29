// Scenario 3 — Private Foundry Agent (Standard Agent Setup + VNet injection).
//
// All of this runs INSIDE the VNet (executed by the VNet-integrated WebApp), because the
// Foundry project's public network access is Disabled. Grounding uses an app-side
// retrieval-augmented-generation (RAG) path over the PRIVATE Azure AI Search service:
//   • /api/seed uploads the sample appliance manuals (Manuals.cs) to the private BYO blob
//     storage (Standard Agent Setup file store) AND indexes them into a deterministic
//     keyword index on the private AI Search, then creates a no-tools agent.
//   • /api/ask BM25-queries that private index (over the private endpoint), injects the
//     matching manual excerpts into the prompt, and asks the private Foundry agent to
//     synthesise a grounded, cited answer. Thread state lives in the private Cosmos DB.
//
// Why app-side RAG instead of the managed file_search tool: in this subscription/region
// only the gpt-5 model family is deployable (gpt-4.x is blocked as "deprecating"), and the
// managed file_search query-time vector step fails for gpt-5 with an opaque server_error.
// App-side RAG keeps every resource private and in the data path, is deterministic, and
// works with gpt-5-mini. Nothing leaves the virtual network.
using System.Diagnostics;
using Azure;
using Azure.AI.Agents.Persistent;
using Azure.Identity;
using Azure.Search.Documents;
using Azure.Search.Documents.Indexes;
using Azure.Search.Documents.Indexes.Models;
using Azure.Search.Documents.Models;

// In-memory handle to the seeded agent. B1 App Service is single-instance, so a static
// cache is sufficient for the demo; a restart simply requires re-seeding (idempotent).
static class AgentState
{
    public static string? AgentId;
    public static string? VectorStoreId; // legacy (managed file_search); unused by the RAG path
    public static string? IndexName;     // private AI Search index the RAG path queries
    public static string[] FileNames = [];
    public static readonly Dictionary<string, string> FileIdToName = new();
    public static readonly SemaphoreSlim Gate = new(1, 1);
    public static bool Ready => AgentId is not null;
}

static class AgentSupport
{
    private static PersistentAgentsClient CreateClient(IConfiguration cfg)
    {
        var projectEndpoint = cfg["Agent:ProjectEndpoint"];
        if (string.IsNullOrWhiteSpace(projectEndpoint))
            throw new InvalidOperationException("Agent:ProjectEndpoint is not configured.");
        return new PersistentAgentsClient(projectEndpoint, new DefaultAzureCredential());
    }

    private static Uri SearchEndpoint(IConfiguration cfg)
    {
        var ep = cfg["Agent:SearchEndpoint"];
        if (string.IsNullOrWhiteSpace(ep))
            throw new InvalidOperationException("Agent:SearchEndpoint is not configured.");
        return new Uri(ep);
    }

    private static string IndexName(IConfiguration cfg) =>
        cfg["Agent:SearchIndexName"] ?? "manuals-idx";

    // Upload the manuals to the private blob store, index them into the private AI Search,
    // and create the (no-tools) agent. Idempotent: if an agent already exists this reuses it.
    public static async Task<object> SeedAsync(IConfiguration cfg, bool force = false)
    {
        var model = cfg["Agent:ModelDeployment"] ?? "gpt-4o-mini";
        var indexName = IndexName(cfg);
        await AgentState.Gate.WaitAsync();
        try
        {
            var client = CreateClient(cfg);
            if (force)
            {
                // Rebuild from scratch: drop the cached handles so a fresh agent + index
                // are created (used when the model or grounding config changed).
                AgentState.AgentId = null;
                AgentState.VectorStoreId = null;
                AgentState.IndexName = null;
            }
            if (AgentState.Ready)
                return new
                {
                    seeded = true,
                    reused = true,
                    agentId = AgentState.AgentId,
                    index = AgentState.IndexName,
                    files = AgentState.FileNames,
                    model
                };

            var names = new List<string>();
            var blobUploads = new List<string>();
            AgentState.FileIdToName.Clear();

            // 1) Upload the manuals to the PRIVATE blob storage (Standard Agent Setup file
            //    store). This proves the private-storage data path even though the RAG
            //    retrieval below uses AI Search. Best-effort: a storage hiccup must not
            //    block the grounding path.
            foreach (var (fileName, content) in Manuals.All)
            {
                names.Add(fileName);
                var path = Path.Combine(Path.GetTempPath(), fileName);
                await File.WriteAllTextAsync(path, content);
                try
                {
                    PersistentAgentFileInfo uploaded =
                        await client.Files.UploadFileAsync(path, PersistentAgentFilePurpose.Agents);
                    AgentState.FileIdToName[uploaded.Id] = fileName;
                    blobUploads.Add(fileName);
                }
                catch { /* non-fatal: storage upload is a proof, not a dependency of RAG */ }
                finally { try { File.Delete(path); } catch { /* best effort */ } }
            }

            // 2) Build the deterministic keyword index on the PRIVATE AI Search and push the
            //    manuals as documents. Reached over the private endpoint via the WebApp MI.
            var cred = new DefaultAzureCredential();
            var indexClient = new SearchIndexClient(SearchEndpoint(cfg), cred);
            var index = new SearchIndex(indexName)
            {
                Fields =
                {
                    new SimpleField("id", SearchFieldDataType.String) { IsKey = true },
                    new SearchableField("title") { IsFilterable = true },
                    new SearchableField("content"),
                }
            };
            await indexClient.CreateOrUpdateIndexAsync(index);

            var searchClient = new SearchClient(SearchEndpoint(cfg), indexName, cred);
            var docs = Manuals.All.Select((m, i) => new SearchDocument
            {
                ["id"] = i.ToString(),
                ["title"] = m.FileName,
                ["content"] = m.Content,
            }).ToList();
            await searchClient.MergeOrUploadDocumentsAsync(docs);

            // 3) Create the agent with NO tools. Grounding is injected from the private
            //    Search at ask time, so the model only needs to synthesise + cite.
            PersistentAgent agent = await client.Administration.CreateAgentAsync(
                model: model,
                name: "appliance-support-bot",
                instructions:
                    "You are a product support assistant for home appliances. " +
                    "Answer ONLY from the product manual excerpts provided in the user's message. " +
                    "Always cite the manual title in square brackets, e.g. [AquaWash-3000-Washer-Manual.md]. " +
                    "If the answer is not in the provided excerpts, say you don't have that information.");

            AgentState.AgentId = agent.Id;
            AgentState.IndexName = indexName;
            AgentState.FileNames = names.ToArray();

            // Give the index a moment to become queryable before the first ask.
            await Task.Delay(1500);

            return new
            {
                seeded = true,
                reused = false,
                agentId = agent.Id,
                index = indexName,
                searchEndpoint = cfg["Agent:SearchEndpoint"],
                blobUploads,
                docCount = docs.Count,
                files = names,
                model,
                grounding = "app-side-rag-over-private-ai-search"
            };
        }
        finally
        {
            AgentState.Gate.Release();
        }
    }

    // Diagnostic: run a throwaway agent with NO tools to isolate whether the agent compute
    // path (thread + run + Cosmos) works independently of the file_search / private-Search
    // tool path. If this succeeds while /api/ask fails, the failure is specific to the
    // file_search tool execution, not the agent runtime.
    public static async Task<object> DiagNoToolAsync(IConfiguration cfg)
    {
        var model = cfg["Agent:ModelDeployment"] ?? "gpt-4o-mini";
        var client = CreateClient(cfg);
        PersistentAgent agent = await client.Administration.CreateAgentAsync(
            model: model,
            name: "diag-notool-bot",
            instructions: "You are a helpful assistant. Answer briefly.");
        try
        {
            PersistentAgentThread thread = await client.Threads.CreateThreadAsync();
            await client.Messages.CreateMessageAsync(thread.Id, MessageRole.User, "Say the single word: OK");
            ThreadRun run = await client.Runs.CreateRunAsync(thread.Id, agent.Id);
            var waited = 0;
            while (run.Status == RunStatus.Queued || run.Status == RunStatus.InProgress)
            {
                if (waited >= 60_000) return new { tool = "none", ok = false, status = "timeout", model };
                await Task.Delay(700); waited += 700;
                run = await client.Runs.GetRunAsync(thread.Id, run.Id);
            }
            var steps = new List<string>();
            await foreach (RunStep step in client.Runs.GetRunStepsAsync(thread.Id, run.Id))
                steps.Add(step.LastError is not null ? $"{step.Type}/{step.Status}: [{step.LastError.Code}] {step.LastError.Message}" : $"{step.Type}/{step.Status}");
            return new { tool = "none", ok = run.Status == RunStatus.Completed, status = run.Status.ToString(), lastErrorCode = run.LastError?.Code, steps, model };
        }
        finally { try { await client.Administration.DeleteAgentAsync(agent.Id); } catch { } }
    }

    // Diagnostic: run a throwaway agent with the code_interpreter tool (self-contained,
    // no BYO data path) to isolate whether the configured model can use ANY tool in this
    // runtime. If this succeeds while file_search fails, the problem is the file_search /
    // private-Search path; if this also fails with server_error, the model itself is not
    // supported for tool-calling in the agents runtime.
    public static async Task<object> DiagToolAsync(IConfiguration cfg)
    {
        var model = cfg["Agent:ModelDeployment"] ?? "gpt-4o-mini";
        var client = CreateClient(cfg);
        PersistentAgent agent = await client.Administration.CreateAgentAsync(
            model: model,
            name: "diag-tool-bot",
            instructions: "Use the code interpreter to compute the answer. Reply with only the number.",
            tools: new List<ToolDefinition> { new CodeInterpreterToolDefinition() });
        try
        {
            PersistentAgentThread thread = await client.Threads.CreateThreadAsync();
            await client.Messages.CreateMessageAsync(thread.Id, MessageRole.User, "What is 21 * 2? Use code interpreter.");
            ThreadRun run = await client.Runs.CreateRunAsync(thread.Id, agent.Id);
            var waited = 0;
            while (run.Status == RunStatus.Queued || run.Status == RunStatus.InProgress)
            {
                if (waited >= 90_000) return new { tool = "code_interpreter", ok = false, status = "timeout", model };
                await Task.Delay(700); waited += 700;
                run = await client.Runs.GetRunAsync(thread.Id, run.Id);
            }
            var steps = new List<string>();
            await foreach (RunStep step in client.Runs.GetRunStepsAsync(thread.Id, run.Id))
                steps.Add(step.LastError is not null ? $"{step.Type}/{step.Status}: [{step.LastError.Code}] {step.LastError.Message}" : $"{step.Type}/{step.Status}");
            return new { tool = "code_interpreter", ok = run.Status == RunStatus.Completed, status = run.Status.ToString(), lastErrorCode = run.LastError?.Code, steps, model };
        }
        finally { try { await client.Administration.DeleteAgentAsync(agent.Id); } catch { } }
    }

    // Run one grounded turn (app-side RAG): BM25-query the private AI Search for the most
    // relevant manual excerpts, inject them into the prompt, and ask the private agent to
    // synthesise a cited answer. Citations are the manual titles the model actually used.
    public static async Task<object> AskAsync(IConfiguration cfg, string prompt)
    {
        if (!AgentState.Ready)
            return new { error = "Agent not seeded yet. Click 'Seed manuals & create agent' first.", needsSeed = true, prompt };

        var model = cfg["Agent:ModelDeployment"] ?? "gpt-4o-mini";
        var indexName = AgentState.IndexName ?? IndexName(cfg);
        var client = CreateClient(cfg);
        var sw = Stopwatch.StartNew();

        // 1) Retrieve grounding from the PRIVATE AI Search (over the private endpoint).
        var hits = new List<(string Title, string Content, double Score)>();
        try
        {
            var searchClient = new SearchClient(SearchEndpoint(cfg), indexName, new DefaultAzureCredential());
            SearchResults<SearchDocument> results =
                (await searchClient.SearchAsync<SearchDocument>(prompt, new SearchOptions { Size = 3 })).Value;
            await foreach (SearchResult<SearchDocument> r in results.GetResultsAsync())
            {
                var d = r.Document;
                var title = d.TryGetValue("title", out var t) ? t?.ToString() ?? "" : "";
                var content = d.TryGetValue("content", out var c) ? c?.ToString() ?? "" : "";
                hits.Add((title, content, r.Score ?? 0));
            }
        }
        catch (Exception ex)
        {
            return new { error = $"Private AI Search query failed: {ex.Message}", prompt, model };
        }

        if (hits.Count == 0)
            return new
            {
                prompt,
                response = "I couldn't find anything relevant in the product manuals.",
                citations = Array.Empty<string>(),
                grounded = false,
                latencyMs = sw.ElapsedMilliseconds,
                model,
                timestamp = DateTime.UtcNow
            };

        var context = string.Join("\n\n", hits.Select(h => $"### Manual: {h.Title}\n{h.Content}"));

        // 2) Ask the private agent (no tools) to synthesise a grounded, cited answer.
        PersistentAgentThread thread = await client.Threads.CreateThreadAsync();
        try
        {
            var userMsg =
                "Use ONLY the following product manual excerpts to answer the question. " +
                "Cite the manual title in square brackets. If the excerpts do not contain the " +
                "answer, say you don't have that information.\n\n" +
                context +
                "\n\n---\nQuestion: " + prompt;

            await client.Messages.CreateMessageAsync(thread.Id, MessageRole.User, userMsg);
            ThreadRun run = await client.Runs.CreateRunAsync(thread.Id, AgentState.AgentId!);

            var waitedMs = 0;
            while (run.Status == RunStatus.Queued || run.Status == RunStatus.InProgress)
            {
                if (waitedMs >= 90_000)
                    return new { error = "Agent run timed out after 90s.", prompt, model };
                await Task.Delay(700);
                waitedMs += 700;
                run = await client.Runs.GetRunAsync(thread.Id, run.Id);
            }

            if (run.Status != RunStatus.Completed)
            {
                var reason = run.LastError?.Message ?? run.Status.ToString();
                var code = run.LastError?.Code;
                var stepErrors = new List<string>();
                try
                {
                    await foreach (RunStep step in client.Runs.GetRunStepsAsync(thread.Id, run.Id))
                        stepErrors.Add(step.LastError is not null
                            ? $"{step.Type}/{step.Status}: [{step.LastError.Code}] {step.LastError.Message}"
                            : $"{step.Type}/{step.Status}");
                }
                catch (Exception se) { stepErrors.Add($"(step fetch failed: {se.Message})"); }

                return new
                {
                    error = $"Run did not complete: {reason}",
                    runStatus = run.Status.ToString(),
                    lastErrorCode = code,
                    steps = stepErrors,
                    model,
                    prompt
                };
            }

            string answer = "(no response)";
            AsyncPageable<PersistentThreadMessage> messages =
                client.Messages.GetMessagesAsync(threadId: thread.Id, order: ListSortOrder.Descending);
            await foreach (PersistentThreadMessage message in messages)
            {
                if (message.Role != MessageRole.Agent) continue;
                foreach (MessageContent contentItem in message.ContentItems)
                    if (contentItem is MessageTextContent textItem) answer = textItem.Text;
                break; // newest agent message only
            }

            // Citations = the manuals the model actually referenced; fall back to the top hit.
            var citations = hits
                .Where(h => !string.IsNullOrEmpty(h.Title) && answer.Contains(h.Title, StringComparison.OrdinalIgnoreCase))
                .Select(h => h.Title)
                .Distinct()
                .ToList();
            if (citations.Count == 0) citations.Add(hits[0].Title);

            sw.Stop();
            return new
            {
                prompt,
                response = answer,
                citations,
                grounded = true,
                retrievalHits = hits.Select(h => new { title = h.Title, score = Math.Round(h.Score, 3) }),
                latencyMs = sw.ElapsedMilliseconds,
                model,
                agentId = AgentState.AgentId,
                grounding = "app-side-rag-over-private-ai-search",
                timestamp = DateTime.UtcNow
            };
        }
        finally
        {
            try { await client.Threads.DeleteThreadAsync(thread.Id); } catch { /* best effort cleanup */ }
        }
    }
}
