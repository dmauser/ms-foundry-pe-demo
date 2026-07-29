// Scenario 3 — Private Foundry Agent (Standard Agent Setup + VNet injection).
//
// All of this runs INSIDE the VNet (executed by the VNet-integrated WebApp), because
// the Foundry project's public network access is Disabled. The agent grounds answers on
// the sample appliance manuals (Manuals.cs) via the File Search tool, backed by the
// private AI Search vector store; thread state lives in the private Cosmos DB. Nothing
// leaves the virtual network.
using System.Diagnostics;
using Azure;
using Azure.AI.Agents.Persistent;
using Azure.Identity;

// In-memory handle to the seeded agent. B1 App Service is single-instance, so a static
// cache is sufficient for the demo; a restart simply requires re-seeding (idempotent).
static class AgentState
{
    public static string? AgentId;
    public static string? VectorStoreId;
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

    // Upload the manuals to the private data plane, build the File Search vector store,
    // and create the agent. Idempotent: if an agent already exists this reuses it.
    public static async Task<object> SeedAsync(IConfiguration cfg, bool force = false)
    {
        var model = cfg["Agent:ModelDeployment"] ?? "gpt-4o-mini";
        await AgentState.Gate.WaitAsync();
        try
        {
            var client = CreateClient(cfg);
            if (force)
            {
                // Rebuild from scratch: drop the cached handles so a fresh agent + vector
                // store are created (used when the model or embedding config changed).
                AgentState.AgentId = null;
                AgentState.VectorStoreId = null;
            }
            if (AgentState.Ready)
                return new
                {
                    seeded = true,
                    reused = true,
                    agentId = AgentState.AgentId,
                    vectorStoreId = AgentState.VectorStoreId,
                    files = AgentState.FileNames,
                    model
                };

            var fileIds = new List<string>();
            var names = new List<string>();
            AgentState.FileIdToName.Clear();

            foreach (var (fileName, content) in Manuals.All)
            {
                var path = Path.Combine(Path.GetTempPath(), fileName);
                await File.WriteAllTextAsync(path, content);
                try
                {
                    PersistentAgentFileInfo uploaded =
                        await client.Files.UploadFileAsync(path, PersistentAgentFilePurpose.Agents);
                    fileIds.Add(uploaded.Id);
                    AgentState.FileIdToName[uploaded.Id] = fileName;
                    names.Add(fileName);
                }
                finally
                {
                    try { File.Delete(path); } catch { /* best effort */ }
                }
            }

            PersistentAgentsVectorStore vectorStore =
                await client.VectorStores.CreateVectorStoreAsync(fileIds: fileIds, name: "appliance-manuals");

            // CreateVectorStore returns before the async ingestion into the private AI Search
            // vector store finishes. Querying an incomplete store makes the file_search tool
            // fail at run time with a generic server_error, so wait for a terminal status and
            // surface per-file ingestion errors (the real signal when the private data path
            // is misconfigured).
            var vsWaitMs = 0;
            while (vectorStore.Status == VectorStoreStatus.InProgress && vsWaitMs < 120_000)
            {
                await Task.Delay(2000);
                vsWaitMs += 2000;
                vectorStore = await client.VectorStores.GetVectorStoreAsync(vectorStore.Id);
            }

            var fileErrors = new List<string>();
            try
            {
                await foreach (VectorStoreFile vsf in client.VectorStores.GetVectorStoreFilesAsync(vectorStore.Id))
                {
                    var fname = AgentState.FileIdToName.TryGetValue(vsf.Id, out var fn) ? fn : vsf.Id;
                    if (vsf.LastError is not null)
                        fileErrors.Add($"{fname}: {vsf.Status} [{vsf.LastError.Code}] {vsf.LastError.Message}");
                    else if (vsf.Status != VectorStoreFileStatus.Completed)
                        fileErrors.Add($"{fname}: {vsf.Status}");
                }
            }
            catch (Exception ve) { fileErrors.Add($"(file status fetch failed: {ve.Message})"); }

            var fileCounts = new
            {
                total = vectorStore.FileCounts?.Total ?? 0,
                completed = vectorStore.FileCounts?.Completed ?? 0,
                failed = vectorStore.FileCounts?.Failed ?? 0,
                inProgress = vectorStore.FileCounts?.InProgress ?? 0,
            };

            var fileSearch = new FileSearchToolResource();
            fileSearch.VectorStoreIds.Add(vectorStore.Id);

            PersistentAgent agent = await client.Administration.CreateAgentAsync(
                model: model,
                name: "appliance-support-bot",
                instructions:
                    "You are a product support assistant for home appliances. " +
                    "Answer ONLY from the uploaded product manuals using the file_search tool, " +
                    "and always cite the manual you relied on. If the answer is not in the manuals, say so.",
                tools: new List<ToolDefinition> { new FileSearchToolDefinition() },
                toolResources: new ToolResources { FileSearch = fileSearch });

            AgentState.AgentId = agent.Id;
            AgentState.VectorStoreId = vectorStore.Id;
            AgentState.FileNames = names.ToArray();

            return new
            {
                seeded = true,
                reused = false,
                agentId = agent.Id,
                vectorStoreId = vectorStore.Id,
                vectorStoreStatus = vectorStore.Status.ToString(),
                fileCounts,
                fileErrors,
                files = names,
                model
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

    // Run one grounded turn: create a thread, ask, poll the run, return the answer with
    // file citations rewritten to the friendly manual file names.
    public static async Task<object> AskAsync(IConfiguration cfg, string prompt)
    {
        if (!AgentState.Ready)
            return new { error = "Agent not seeded yet. Click 'Seed manuals & create agent' first.", needsSeed = true, prompt };

        var client = CreateClient(cfg);
        var sw = Stopwatch.StartNew();

        PersistentAgentThread thread = await client.Threads.CreateThreadAsync();
        try
        {
            await client.Messages.CreateMessageAsync(thread.Id, MessageRole.User, prompt);
            ThreadRun run = await client.Runs.CreateRunAsync(thread.Id, AgentState.AgentId!);

            var waitedMs = 0;
            while (run.Status == RunStatus.Queued || run.Status == RunStatus.InProgress)
            {
                if (waitedMs >= 90_000)
                    return new { error = "Agent run timed out after 90s.", prompt };
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
                    {
                        if (step.LastError is not null)
                            stepErrors.Add($"{step.Type}/{step.Status}: [{step.LastError.Code}] {step.LastError.Message}");
                        else
                            stepErrors.Add($"{step.Type}/{step.Status}");
                    }
                }
                catch (Exception se) { stepErrors.Add($"(step fetch failed: {se.Message})"); }

                return new
                {
                    error = $"Run did not complete: {reason}",
                    runStatus = run.Status.ToString(),
                    lastErrorCode = code,
                    steps = stepErrors,
                    model = cfg["Agent:ModelDeployment"],
                    prompt
                };
            }

            string answer = "(no response)";
            var citations = new List<string>();

            AsyncPageable<PersistentThreadMessage> messages =
                client.Messages.GetMessagesAsync(threadId: thread.Id, order: ListSortOrder.Descending);

            await foreach (PersistentThreadMessage message in messages)
            {
                if (message.Role != MessageRole.Agent) continue;

                foreach (MessageContent contentItem in message.ContentItems)
                {
                    if (contentItem is not MessageTextContent textItem) continue;

                    var text = textItem.Text;
                    foreach (MessageTextAnnotation annotation in textItem.Annotations)
                    {
                        string? fileId = annotation switch
                        {
                            MessageTextFileCitationAnnotation fc => fc.FileId,
                            MessageTextFilePathAnnotation fp => fp.FileId,
                            _ => null
                        };
                        if (fileId is null) continue;

                        var name = AgentState.FileIdToName.TryGetValue(fileId, out var n) ? n : fileId;
                        if (!citations.Contains(name)) citations.Add(name);
                        if (!string.IsNullOrEmpty(annotation.Text))
                            text = text.Replace(annotation.Text, $" [{name}]");
                    }
                    answer = text;
                }
                break; // newest agent message only
            }

            sw.Stop();

            return new
            {
                prompt,
                response = answer,
                citations,
                grounded = citations.Count > 0,
                latencyMs = sw.ElapsedMilliseconds,
                model = cfg["Agent:ModelDeployment"] ?? "gpt-4o-mini",
                agentId = AgentState.AgentId,
                timestamp = DateTime.UtcNow
            };
        }
        finally
        {
            try { await client.Threads.DeleteThreadAsync(thread.Id); } catch { /* best effort cleanup */ }
        }
    }
}
