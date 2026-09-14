using System.Diagnostics;
using AiGatewayDemo.Options;
using AiGatewayDemo.Services;

var builder = WebApplication.CreateBuilder(args);

// One .env file drives this app and the Python app identically.
DotEnv.Load(builder.Environment.ContentRootPath, builder.Configuration);

var options = GatewayOptions.FromConfiguration(builder.Configuration);
var connection = options.Connection;

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(connection);
builder.Services.AddSingleton(options.ModelParams);
builder.Services.AddSingleton<VectorIndex>();
builder.Services.AddSingleton<AiClient>();
builder.Services.AddSingleton<ContentSafetyClient>();
builder.Services.AddSingleton<DocumentIntelligenceClient>();
builder.Services.AddRazorPages();

builder.Services.AddHttpClient("ai").ConfigureHttpClient(c => c.Timeout = TimeSpan.FromSeconds(120));
builder.Services.AddHttpClient("safety").ConfigureHttpClient(c => c.Timeout = TimeSpan.FromSeconds(30));
builder.Services.AddHttpClient("docintel").ConfigureHttpClient(c => c.Timeout = TimeSpan.FromSeconds(120));

var app = builder.Build();

app.UseStaticFiles();
app.MapRazorPages();

string NewCorrelationId() => $"demo-{Guid.NewGuid():n}"[..17];

// Embeddings over the configured connection, with a local fallback so the demo never dead-ends.
async Task<(List<float[]> Vectors, string Mode)> VectoriseAsync(AiClient ai,
    IReadOnlyList<string> texts, string correlationId, CancellationToken ct)
{
    if (!string.IsNullOrWhiteSpace(connection.EmbeddingModel) && connection.Enabled)
    {
        try
        {
            var vectors = await ai.EmbedAsync(connection, texts, correlationId, ct);
            if (vectors.Count == texts.Count)
                return (vectors, $"{connection.EmbeddingModel} ({connection.Label})");
        }
        catch (Exception ex) when (ex is UpstreamException or HttpRequestException or TaskCanceledException)
        {
            // Fall through to the local vectoriser.
        }
    }

    return (texts.Select(t => VectorIndex.HashedVector(t)).ToList(),
            "local hashed TF (no embedding model)");
}

// ── config ────────────────────────────────────────────────────────────
app.MapGet("/api/config", () => Results.Ok(new
{
    connection = connection.ToJson(),
    safetyConfigured = ContentSafetyClient.Configured(connection),
    docIntelConfigured = DocumentIntelligenceClient.Configured(connection),
    safetyThreshold = options.SafetyThreshold,
    implementation = ".NET 10 / Razor Pages",
}));

// ── documents ─────────────────────────────────────────────────────────
app.MapGet("/api/documents", (VectorIndex index) =>
{
    var docs = index.Documents();
    return Results.Ok(new
    {
        documents = docs.Select(d => d.ToJson()),
        totalChunks = index.TotalChunks(),
        embeddingMode = docs.Count > 0 ? docs[^1].IndexedVia : "-",
    });
});

app.MapPost("/api/upload", async (IFormFile file, VectorIndex index,
    AiClient ai, DocumentIntelligenceClient docIntel, CancellationToken ct) =>
{
    // No connection check: a .txt/.md/.csv file is parsed and vectorised locally,
    // so it indexes fine before any Azure resource exists.
    var correlationId = NewCorrelationId();
    var stopwatch = Stopwatch.StartNew();

    if (file.Length == 0)
        return Results.BadRequest(new { error = "The uploaded file is empty." });

    if (file.Length > options.MaxUploadMb * 1024L * 1024L)
        return Results.Json(new { error = $"File exceeds the {options.MaxUploadMb} MB limit." }, statusCode: 413);

    byte[] data;
    await using (var stream = file.OpenReadStream())
    using (var memory = new MemoryStream())
    {
        await stream.CopyToAsync(memory, ct);
        data = memory.ToArray();
    }

    ExtractionResult extraction;
    try
    {
        extraction = await docIntel.ExtractAsync(connection, file.FileName, data, correlationId, ct);
    }
    catch (ExtractionException ex)
    {
        return Results.BadRequest(new { error = ex.Message });
    }

    var chunks = VectorIndex.ChunkText(extraction.Text, options.ChunkChars, options.ChunkOverlap);
    if (chunks.Count == 0)
        return Results.BadRequest(new { error = "Nothing indexable was extracted from this file." });

    var (vectors, indexedVia) = await VectoriseAsync(ai, chunks, correlationId, ct);
    stopwatch.Stop();

    var doc = index.Add(file.FileName, file.Length, extraction.ExtractedVia, indexedVia,
        extraction.Pages, chunks, vectors, (int)stopwatch.ElapsedMilliseconds);

    return Results.Ok(new
    {
        id = doc.Id,
        name = doc.Name,
        sizeBytes = doc.SizeBytes,
        chunks = doc.Chunks.Count,
        pages = doc.Pages,
        extractedVia = doc.ExtractedVia,
        indexedVia = doc.IndexedVia,
        elapsedMs = doc.ElapsedMs,
        note = extraction.Note,
        correlationId,
    });
}).DisableAntiforgery();

app.MapDelete("/api/documents/{id}", (string id, VectorIndex index) =>
    index.Remove(id)
        ? Results.Ok(new { removed = id })
        : Results.NotFound(new { error = "No such document." }));

// ── chat ──────────────────────────────────────────────────────────────
app.MapPost("/api/chat", async (ChatRequest request, VectorIndex index, AiClient ai,
    ContentSafetyClient safety, CancellationToken ct) =>
{
    if (!connection.Enabled)
        return Results.BadRequest(new { error = $"No AI connection configured. {connection.Reason}" });

    var correlationId = NewCorrelationId();
    var message = (request.Message ?? "").Trim();
    var imageDataUrl = request.ImageDataUrl;
    var useRag = request.UseRag ?? true;
    var history = request.History ?? [];

    if (message.Length == 0 && string.IsNullOrWhiteSpace(imageDataUrl))
        return Results.BadRequest(new { error = "Send a message or attach an image." });

    var total = Stopwatch.StartNew();
    var connectionJson = connection.ToJson();

    // 1 - guardrail the inbound prompt, before a token is spent upstream.
    var safetyWatch = Stopwatch.StartNew();
    var promptVerdict = await safety.AnalyzeTextAsync(connection, message, correlationId, ct);
    SafetyVerdict? imageVerdict = null;
    if (!string.IsNullOrWhiteSpace(imageDataUrl))
        imageVerdict = await safety.AnalyzeImageAsync(connection, imageDataUrl, correlationId, ct);

    // Prompt Shields answers a different question from the severity categories:
    // "is this an attack on the system", not "is this harmful content".
    var shieldVerdict = await safety.ShieldPromptAsync(connection, message, [], correlationId, ct);

    safetyWatch.Stop();
    var safetyMs = (int)safetyWatch.ElapsedMilliseconds;

    foreach (var (stage, verdict) in new (string, SafetyVerdict?)[]
             { ("prompt-text", promptVerdict), ("prompt-image", imageVerdict),
               ("prompt-shield", shieldVerdict) })
    {
        if (verdict is { Blocked: true })
        {
            return Results.Ok(new ChatResponse(
                connectionJson, correlationId,
                new SafetyBundle(promptVerdict, imageVerdict, shieldVerdict, null),
                new RetrievalInfo(false, "-", []),
                new UsageInfo(null, null, null),
                new TimingInfo(safetyMs, 0, 0, (int)total.ElapsedMilliseconds),
                Request: options.ModelParams.ForModel(connection.ChatModel).ToJson(),
                Blocked: true, BlockedStage: stage,
                Reply: safety.RefusalMessage(stage, verdict)));
        }
    }

    // 2 - retrieve from the in-memory index.
    string? context = null;
    var retrieval = new RetrievalInfo(false, "-", []);
    var retrievalMs = 0;

    if (useRag && !index.IsEmpty && message.Length > 0)
    {
        var retrievalWatch = Stopwatch.StartNew();
        var (queryVectors, mode) = await VectoriseAsync(ai, [message], correlationId, ct);
        var hits = index.Search(queryVectors[0], options.TopK);
        retrievalWatch.Stop();
        retrievalMs = (int)retrievalWatch.ElapsedMilliseconds;

        if (hits.Count > 0)
        {
            context = string.Join("\n\n---\n\n", hits.Select(h =>
                $"[source: {h.Chunk.DocName}, chunk {h.Chunk.Ordinal + 1}]\n{h.Chunk.Text}"));

            retrieval = new RetrievalInfo(true, mode, hits
                .Select(h => new RetrievedChunk(h.Chunk.DocName, h.Chunk.Ordinal,
                    Math.Round(h.Score, 4), h.Chunk.Text))
                .ToList());
        }
    }

    // 3 - the model call. This is the code that does not change between modes.
    var modelWatch = Stopwatch.StartNew();
    var messages = AiClient.BuildMessages(options.SystemPrompt, history,
        message.Length > 0 ? message : "Describe the attached image.", imageDataUrl, context);

    System.Text.Json.Nodes.JsonNode completion;
    ModelParams usedParams;
    try
    {
        (completion, usedParams) = await ai.ChatCompletionAsync(
            connection, messages, correlationId, options.ModelParams, ct);
    }
    catch (UpstreamException ex)
    {
        return Results.Json(new { error = $"{connection.Label} call failed - {ex.Message}", stage = ex.Stage },
            statusCode: 502);
    }
    catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
    {
        return Results.Json(new { error = $"{connection.Label} unreachable - {ex.Message}" }, statusCode: 502);
    }
    modelWatch.Stop();

    var reply = completion["choices"]?[0]?["message"]?["content"]?.GetValue<string>() ?? "";
    var usageNode = completion["usage"];
    var usage = new UsageInfo(
        usageNode?["prompt_tokens"]?.GetValue<int>(),
        usageNode?["completion_tokens"]?.GetValue<int>(),
        usageNode?["total_tokens"]?.GetValue<int>());

    // 4 - guardrail the outbound completion too.
    SafetyVerdict? completionVerdict = null;
    var blocked = false;
    string? blockedStage = null;

    if (options.CheckCompletion && reply.Length > 0)
    {
        completionVerdict = await safety.AnalyzeTextAsync(connection, reply, correlationId, ct);
        safetyMs += completionVerdict.LatencyMs;

        if (completionVerdict.Blocked)
        {
            blocked = true;
            blockedStage = "completion";
            reply = safety.RefusalMessage("completion", completionVerdict);
        }
    }

    if (reply.Length == 0) reply = "(the model returned an empty response)";

    return Results.Ok(new ChatResponse(
        connectionJson, correlationId,
        new SafetyBundle(promptVerdict, imageVerdict, shieldVerdict, completionVerdict),
        retrieval, usage,
        new TimingInfo(safetyMs, retrievalMs, (int)modelWatch.ElapsedMilliseconds,
            (int)total.ElapsedMilliseconds),
        usedParams.ToJson(),
        blocked, blockedStage, reply));
});

app.Run();

/// <summary>Minimal .env reader, so this app and the Python app can share one config file.</summary>
internal static class DotEnv
{
    public static void Load(string contentRoot, ConfigurationManager configuration)
    {
        // This stack's own .env first, then one at the repo root. Note that
        // scripts/03-set-local-env.ps1 configures this app through
        // appsettings.Development.json, which outranks every .env here.
        // A dotnet/.env overrides the
        // shared file for this stack only, which is how you point the two apps at
        // different endpoints and compare them side by side.
        var candidates = new[]
        {
            Path.Combine(contentRoot, ".env"),                    // dotnet/AiGatewayDemo/.env
            Path.Combine(contentRoot, "..", ".env"),              // dotnet/.env
            Path.Combine(contentRoot, "..", "..", ".env"),        // repo root
        };

        var values = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

        foreach (var path in candidates.Where(File.Exists))
        {
            foreach (var line in File.ReadAllLines(path))
            {
                var trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith('#')) continue;

                var separator = trimmed.IndexOf('=');
                if (separator <= 0) continue;

                var key = trimmed[..separator].Trim();
                var value = trimmed[(separator + 1)..].Trim().Trim('"');
                // Real environment variables and appsettings win over the .env file.
                if (value.Length > 0 && string.IsNullOrEmpty(configuration[key]))
                    values.TryAdd(key, value);
            }
            // Named so the UI can say which file a value came from.
            GatewayOptions.DotEnvSource = Path.GetFileName(Path.GetDirectoryName(path) ?? "") is { Length: > 0 } dir
                ? $"{dir}/.env"
                : ".env";
            break; // First .env found wins.
        }

        if (values.Count > 0)
            configuration.AddInMemoryCollection(values);
    }
}
