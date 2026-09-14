using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiGatewayDemo.Options;

namespace AiGatewayDemo.Services;

public sealed class ExtractionException(string message) : Exception(message);

public sealed record ExtractionResult(string Text, int? Pages, string ExtractedVia, string Note);

/// <summary>
/// Document Intelligence through the gateway. Shows the long-running-operation shape:
///   POST :analyze  -> 202 + Operation-Location
///   GET  that URL  -> poll until "succeeded"
///
/// The Operation-Location the service builds carries the *resource's* hostname. A client
/// that follows it verbatim leaves the gateway and gets a 401, because it holds a gateway
/// key rather than the resource key - which is why the APIM API carries an outbound policy
/// that rewrites the host back to the gateway. This client reports which host it was
/// handed, so the rewrite is visible in the demo.
/// </summary>
public sealed class DocumentIntelligenceClient(IHttpClientFactory factory)
{
    private const string ApiVersion = "2024-11-30";
    private const string ModelId = "prebuilt-layout";
    private const int MaxPolls = 60;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1.5);

    // Handled locally - no reason to spend a Document Intelligence page on them.
    private static readonly HashSet<string> PlainText =
        [".txt", ".md", ".markdown", ".log", ".json", ".csv", ".tsv", ".xml", ".yaml", ".yml"];

    // Everything prebuilt-layout accepts.
    private static readonly HashSet<string> DocumentTypes =
        [".pdf", ".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".tif", ".heif",
         ".docx", ".xlsx", ".pptx", ".html", ".htm"];

    public static bool Configured(AiConnection conn) => conn.DocIntelConfigured;

    public async Task<ExtractionResult> ExtractAsync(AiConnection conn, string name, byte[] data,
        string correlationId, CancellationToken ct)
    {
        var extension = Path.GetExtension(name).ToLowerInvariant();
        var stopwatch = Stopwatch.StartNew();

        if (PlainText.Contains(extension))
        {
            var text = ExtractPlainText(extension, data);
            if (string.IsNullOrWhiteSpace(text))
                throw new ExtractionException($"'{name}' is empty.");

            stopwatch.Stop();
            return new ExtractionResult(text, null, "local text parsing",
                $"Plain text - no Document Intelligence call ({stopwatch.ElapsedMilliseconds} ms).");
        }

        if (DocumentTypes.Contains(extension) || extension.Length == 0)
        {
            var (content, pages, note) = await AnalyzeAsync(conn, name, data, correlationId, ct);
            return new ExtractionResult(content, pages, $"Document Intelligence ({ModelId})", note);
        }

        throw new ExtractionException(
            $"Unsupported file type '{(extension.Length == 0 ? "unknown" : extension)}' for '{name}'.");
    }

    /// <summary>Decodes a text-ish upload, flattening CSV/JSON into something worth embedding.</summary>
    private static string ExtractPlainText(string extension, byte[] data)
    {
        var text = Encoding.UTF8.GetString(data);

        if (extension == ".json")
        {
            try
            {
                using var document = JsonDocument.Parse(text);
                return JsonSerializer.Serialize(document,
                    new JsonSerializerOptions { WriteIndented = true });
            }
            catch (JsonException) { return text; }
        }

        if (extension is ".csv" or ".tsv")
        {
            var delimiter = extension == ".tsv" ? '\t' : ',';
            var lines = text.Replace("\r\n", "\n").Split('\n', StringSplitOptions.RemoveEmptyEntries);
            if (lines.Length < 2) return text;

            var header = lines[0].Split(delimiter);
            // One record per paragraph reads far better to an embedding model than a grid.
            var records = lines.Skip(1)
                .Select(line => line.Split(delimiter))
                .Select(cells => string.Join("; ", header
                    .Zip(cells, (h, v) => (Header: h.Trim(), Value: v.Trim()))
                    .Where(pair => pair.Value.Length > 0)
                    .Select(pair => $"{pair.Header}: {pair.Value}")))
                .Where(record => record.Length > 0);

            var flattened = string.Join("\n\n", records);
            return flattened.Length > 0 ? flattened : text;
        }

        return text;
    }

    private async Task<(string Content, int? Pages, string Note)> AnalyzeAsync(AiConnection conn, string name,
        byte[] data, string correlationId, CancellationToken ct)
    {
        if (!conn.DocIntelConfigured)
        {
            throw new ExtractionException(
                $"'{name}' needs Document Intelligence, which is not configured for this mode. " +
                "Upload a .txt/.md/.csv/.json file, or set DOC_INTEL_ENDPOINT / DOC_INTEL_KEY.");
        }

        var endpoint = conn.DocIntelEndpoint.TrimEnd('/');
        var url = $"{endpoint}/documentintelligence/documentModels/{ModelId}:analyze" +
                  $"?api-version={ApiVersion}&outputContentFormat=markdown";

        var client = factory.CreateClient("docintel");

        using var submit = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = JsonContent.Create(new { base64Source = Convert.ToBase64String(data) }),
        };
        submit.Headers.TryAddWithoutValidation(conn.DocIntelHeader, conn.DocIntelKey);
        submit.Headers.TryAddWithoutValidation("x-correlation-id", correlationId);

        using var accepted = await client.SendAsync(submit, ct);
        if (accepted.StatusCode is not (System.Net.HttpStatusCode.OK or System.Net.HttpStatusCode.Accepted))
        {
            var error = await accepted.Content.ReadAsStringAsync(ct);
            throw new ExtractionException(
                $"Document Intelligence returned {(int)accepted.StatusCode}: {Trim(error)}");
        }

        if (!accepted.Headers.TryGetValues("Operation-Location", out var values) ||
            values.FirstOrDefault() is not { } operationLocation)
        {
            throw new ExtractionException(
                "Document Intelligence accepted the document but returned no Operation-Location.");
        }

        var gatewayHost = new Uri(endpoint).Host;
        var pollHost = new Uri(operationLocation).Host;
        var pollHeaderName = conn.DocIntelHeader;
        string note;

        if (string.Equals(pollHost, gatewayHost, StringComparison.OrdinalIgnoreCase))
        {
            note = $"202 accepted; polled {pollHost} (stayed on the gateway).";
        }
        else
        {
            note = $"202 accepted; Operation-Location pointed at {pollHost}, not {gatewayHost}. " +
                   "Add the outbound Operation-Location rewrite policy to keep polling on the gateway.";
            // Fall back to the resource key so the demo still completes.
            pollHeaderName = "Ocp-Apim-Subscription-Key";
        }

        for (var attempt = 0; attempt < MaxPolls; attempt++)
        {
            await Task.Delay(PollInterval, ct);

            using var poll = new HttpRequestMessage(HttpMethod.Get, operationLocation);
            poll.Headers.TryAddWithoutValidation(pollHeaderName, conn.DocIntelKey);
            poll.Headers.TryAddWithoutValidation("x-correlation-id", correlationId);

            using var response = await client.SendAsync(poll, ct);
            var body = await response.Content.ReadAsStringAsync(ct);

            if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                throw new ExtractionException(
                    $"Polling {pollHost} returned 401 - the client holds a gateway key, not the resource key. " +
                    "This is exactly what the Operation-Location rewrite policy fixes.");
            }

            if (!response.IsSuccessStatusCode)
                throw new ExtractionException($"Polling returned {(int)response.StatusCode}: {Trim(body)}");

            var node = JsonNode.Parse(body);
            var status = node?["status"]?.GetValue<string>()?.ToLowerInvariant();

            if (status == "succeeded")
            {
                var result = node!["analyzeResult"];
                var content = result?["content"]?.GetValue<string>() ?? "";
                var pages = result?["pages"]?.AsArray().Count;

                if (string.IsNullOrWhiteSpace(content))
                    throw new ExtractionException("Document Intelligence found no text content in this file.");

                return (content, pages == 0 ? null : pages, note);
            }

            if (status == "failed")
            {
                var message = node?["error"]?["message"]?.GetValue<string>() ?? "unknown error";
                throw new ExtractionException($"Analysis failed: {message}");
            }
        }

        throw new ExtractionException("Timed out waiting for Document Intelligence to finish.");
    }

    private static string Trim(string value) => value.Length > 400 ? value[..400] : value;
}
