using System.Diagnostics;
using System.Text.Json.Nodes;
using AiGatewayDemo.Options;

namespace AiGatewayDemo.Services;

public sealed record SafetyCategory(string Category, int Severity);

public sealed class SafetyVerdict
{
    public bool Checked { get; init; }
    public bool Blocked { get; init; }
    public List<SafetyCategory> Categories { get; init; } = [];
    public string Via { get; init; } = "n/a";
    public int LatencyMs { get; init; }
    public int Threshold { get; init; }
    public string? Reason { get; init; }
    public string? Error { get; init; }
    /// <summary>Custom blocklists that matched - a hit blocks regardless of severity.</summary>
    public List<string> BlocklistHits { get; init; } = [];
    /// <summary>Which guardrail produced this verdict, for the UI.</summary>
    public string Stage { get; init; } = "";

    public static SafetyVerdict NotChecked(string reason, int threshold, string stage = "") =>
        new() { Checked = false, Reason = reason, Threshold = threshold, Stage = stage };
}

/// <summary>
/// Azure AI Content Safety guardrails, run before the model on every turn.
/// Mirrors python/services/safety.py.
///
/// Three checks, all of them inbound-first:
///   text:analyze       four harm categories, severity 0-6, plus any custom blocklists
///   image:analyze      the same four categories for an attached image
///   text:shieldPrompt  Prompt Shields - jailbreak and prompt-injection attempts
///
/// A word about what the four categories do and do not cover. They are Hate, SelfHarm,
/// Sexual and Violence. A request like "how to loot a bank" scores 0 on all four: it is
/// criminal facilitation, not one of those four harms, so no threshold will catch it.
/// That is what custom blocklists are for - CONTENT_SAFETY_BLOCKLISTS - and what the
/// model's own alignment is for.
///
/// Two ways to run these guardrails exist, and the demo shows the first so the verdicts
/// are visible in the UI:
///   1. App-side (here): call the APIs and block before spending a token at the provider.
///   2. Policy-side: the APIM llm-content-safety policy does it inline, with no client
///      code. See scripts/policies/.
/// </summary>
public sealed class ContentSafetyClient(IHttpClientFactory factory, GatewayOptions options)
{
    private const string ApiVersion = "2024-09-01";
    private static readonly string[] Categories = ["Hate", "SelfHarm", "Sexual", "Violence"];

    private static string Via(AiConnection conn) =>
        !conn.SafetyConfigured ? "not configured"
        : conn.SafetyEndpoint.Contains(".azure-api.net", StringComparison.OrdinalIgnoreCase) ? "via gateway"
        : "direct";

    public static bool Configured(AiConnection conn) => conn.SafetyConfigured;

    /// <summary>POSTs and returns (body, elapsedMs, error) - the shared half of every check.</summary>
    private async Task<(JsonNode? Body, int ElapsedMs, string Error)> PostAsync<TPayload>(
        AiConnection conn, string path, TPayload payload, string correlationId, CancellationToken ct)
    {
        var url = $"{conn.SafetyEndpoint.TrimEnd('/')}/contentsafety/{path}?api-version={ApiVersion}";
        var client = factory.CreateClient("safety");
        var stopwatch = Stopwatch.StartNew();

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = JsonContent.Create(payload),
            };
            request.Headers.TryAddWithoutValidation(conn.SafetyHeader, conn.SafetyKey);
            request.Headers.TryAddWithoutValidation("x-correlation-id", correlationId);

            using var response = await client.SendAsync(request, ct);
            var body = await response.Content.ReadAsStringAsync(ct);
            stopwatch.Stop();

            if (!response.IsSuccessStatusCode)
            {
                return (null, (int)stopwatch.ElapsedMilliseconds,
                    $"{(int)response.StatusCode}: {(body.Length > 400 ? body[..400] : body)}");
            }

            return (JsonNode.Parse(body), (int)stopwatch.ElapsedMilliseconds, "");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            stopwatch.Stop();
            return (null, (int)stopwatch.ElapsedMilliseconds, $"Content Safety unreachable: {ex.Message}");
        }
    }

    private async Task<SafetyVerdict> AnalyzeAsync<TPayload>(AiConnection conn, string path,
        TPayload payload, string correlationId, string stage, CancellationToken ct)
    {
        if (!conn.SafetyConfigured)
            return SafetyVerdict.NotChecked("Content Safety is not configured for this mode.",
                options.SafetyThreshold, stage);

        var (body, elapsed, error) = await PostAsync(conn, path, payload, correlationId, ct);

        if (error.Length > 0)
        {
            return new SafetyVerdict
            {
                Checked = true, Via = Via(conn), LatencyMs = elapsed,
                Threshold = options.SafetyThreshold, Stage = stage, Error = error,
            };
        }

        var categories = (body?["categoriesAnalysis"]?.AsArray() ?? [])
            .Where(item => item is not null)
            .Select(item => new SafetyCategory(
                item!["category"]?.GetValue<string>() ?? "?",
                item["severity"]?.GetValue<int>() ?? 0))
            .ToList();

        // A custom blocklist hit is a block regardless of the category severities -
        // this is how you stop requests the four harm categories never covered.
        var hits = (body?["blocklistsMatch"]?.AsArray() ?? [])
            .Where(item => item is not null)
            .Select(item => item!["blocklistName"]?.GetValue<string>() ?? "?")
            .ToList();

        return new SafetyVerdict
        {
            Checked = true,
            Blocked = hits.Count > 0 || categories.Any(c => c.Severity >= options.SafetyThreshold),
            Categories = categories,
            BlocklistHits = hits,
            Via = Via(conn),
            LatencyMs = elapsed,
            Threshold = options.SafetyThreshold,
            Stage = stage,
        };
    }

    public Task<SafetyVerdict> AnalyzeTextAsync(AiConnection conn, string text, string correlationId,
        CancellationToken ct, string stage = "prompt-text")
    {
        if (string.IsNullOrWhiteSpace(text))
            return Task.FromResult(SafetyVerdict.NotChecked("No text to screen.",
                options.SafetyThreshold, stage));

        var payload = new JsonObject
        {
            ["text"] = text.Length > 10000 ? text[..10000] : text,
            ["categories"] = new JsonArray(Categories.Select(c => (JsonNode)c!).ToArray()),
            ["outputType"] = "FourSeverityLevels",
        };

        // Added only when configured. These cannot be optional properties on an
        // anonymous type: System.Text.Json writes nulls for them, and Content Safety
        // rejects the whole request with
        //   400 Invalid value type for field [haltOnBlocklistHit], it should be bool.
        // image:analyze carries no such fields, which is why only text calls broke.
        if (options.SafetyBlocklists.Length > 0)
        {
            payload["blocklistNames"] =
                new JsonArray(options.SafetyBlocklists.Select(b => (JsonNode)b!).ToArray());
            payload["haltOnBlocklistHit"] = true;
        }

        return AnalyzeAsync(conn, "text:analyze", payload, correlationId, stage, ct);
    }

    /// <summary>The browser sends a data: URL; Content Safety wants the bare base64 bytes.</summary>
    public Task<SafetyVerdict> AnalyzeImageAsync(AiConnection conn, string dataUrl,
        string correlationId, CancellationToken ct)
    {
        var raw = dataUrl.StartsWith("data:", StringComparison.OrdinalIgnoreCase)
            ? dataUrl[(dataUrl.IndexOf(',') + 1)..]
            : dataUrl;

        if (!IsBase64(raw))
        {
            return Task.FromResult(new SafetyVerdict
            {
                Checked = true,
                Threshold = options.SafetyThreshold,
                Stage = "prompt-image",
                Error = "Attachment is not valid base64 image data.",
            });
        }

        return AnalyzeAsync(conn, "image:analyze", new { image = new { content = raw } },
            correlationId, "prompt-image", ct);
    }

    /// <summary>
    /// Prompt Shields: jailbreak and indirect prompt-injection detection. Separate from
    /// the severity categories - it answers "is this an attack on the system", not "is
    /// this harmful content". Off unless CONTENT_SAFETY_PROMPT_SHIELD.
    ///
    /// It answers with attackDetected flags rather than severities, so it parses its own
    /// response shape rather than going through AnalyzeAsync.
    /// </summary>
    public async Task<SafetyVerdict> ShieldPromptAsync(AiConnection conn, string text,
        IReadOnlyList<string> documents, string correlationId, CancellationToken ct)
    {
        const string stage = "prompt-shield";

        if (!options.PromptShield)
            return SafetyVerdict.NotChecked("Prompt Shields is off (CONTENT_SAFETY_PROMPT_SHIELD).",
                options.SafetyThreshold, stage);
        if (!conn.SafetyConfigured)
            return SafetyVerdict.NotChecked("Content Safety is not configured for this mode.",
                options.SafetyThreshold, stage);
        if (string.IsNullOrWhiteSpace(text) && documents.Count == 0)
            return SafetyVerdict.NotChecked("Nothing to screen.", options.SafetyThreshold, stage);

        var payload = new
        {
            userPrompt = text.Length > 10000 ? text[..10000] : text,
            documents = documents.Take(5).Select(d => d.Length > 10000 ? d[..10000] : d).ToArray(),
        };

        var (body, elapsed, error) = await PostAsync(conn, "text:shieldPrompt", payload, correlationId, ct);

        if (error.Length > 0)
        {
            return new SafetyVerdict
            {
                Checked = true, Via = Via(conn), LatencyMs = elapsed,
                Threshold = options.SafetyThreshold, Stage = stage, Error = error,
            };
        }

        var promptAttack = body?["userPromptAnalysis"]?["attackDetected"]?.GetValue<bool>() ?? false;
        var documentAttack = (body?["documentsAnalysis"]?.AsArray() ?? [])
            .Any(item => item?["attackDetected"]?.GetValue<bool>() ?? false);

        return new SafetyVerdict
        {
            Checked = true,
            Blocked = promptAttack || documentAttack,
            Via = Via(conn),
            LatencyMs = elapsed,
            Threshold = options.SafetyThreshold,
            Stage = stage,
            Reason = promptAttack ? "Jailbreak attempt detected in the prompt."
                : documentAttack ? "Injection detected in the retrieved documents."
                : "No attack detected.",
        };
    }

    private static bool IsBase64(string value)
    {
        var buffer = new Span<byte>(new byte[value.Length]);
        return Convert.TryFromBase64String(value, buffer, out _);
    }

    public string RefusalMessage(string stage, SafetyVerdict verdict)
    {
        string reason;
        if (verdict.BlocklistHits.Count > 0)
        {
            reason = $"a custom blocklist ({string.Join(", ", verdict.BlocklistHits)})";
        }
        else if (stage == "prompt-shield")
        {
            reason = verdict.Reason ?? "Prompt Shields";
        }
        else
        {
            reason = string.Join(", ", verdict.Categories
                .Where(c => c.Severity >= verdict.Threshold)
                .Select(c => $"{c.Category} (severity {c.Severity})"));
            if (reason.Length == 0) reason = "policy categories";
        }

        var where = stage switch
        {
            "prompt-text" => "Your message",
            "prompt-image" => "The attached image",
            "prompt-shield" => "Your message",
            "completion" => "The model's reply",
            _ => "The content",
        };

        return $"{where} was blocked by the Content Safety guardrail: {reason}. " +
               "The request was stopped at the gateway, so nothing was spent at the model provider.";
    }
}
