using System.Text.Json;
using System.Text.Json.Nodes;
using AiGatewayDemo.Options;

namespace AiGatewayDemo.Services;

public sealed class UpstreamException(int status, string message, string stage = "model")
    : Exception(message)
{
    public int Status { get; } = status;
    public string Stage { get; } = stage;
}

/// <summary>
/// Chat completions and embeddings. Deliberately mode-agnostic: one request shape,
/// sent to whichever base URL the selected connection carries.
/// </summary>
public sealed class AiClient(IHttpClientFactory factory)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    // Generic on the payload: JsonContent.Create serializes the *declared* type, so an
    // `object` parameter would send an empty {} body.
    private HttpRequestMessage BuildRequest<TPayload>(AiConnection conn, string path, TPayload payload,
        string correlationId)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, $"{conn.ChatBase}{path}")
        {
            Content = JsonContent.Create(payload, options: Json),
        };
        request.Headers.TryAddWithoutValidation(conn.KeyHeader, conn.Key);
        // Ties the gateway log line to this app's trace. Never put secrets or
        // prompt content in a correlation id.
        request.Headers.TryAddWithoutValidation("x-correlation-id", correlationId);
        return request;
    }

    private static async Task<JsonNode> ReadOrThrowAsync(HttpResponseMessage response, string stage, CancellationToken ct)
    {
        var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
        {
            var detail = body;
            try
            {
                var node = JsonNode.Parse(body);
                detail = node?["error"]?["message"]?.GetValue<string>()
                         ?? node?["message"]?.GetValue<string>()
                         ?? body;
            }
            catch (JsonException) { /* Gateways often return non-JSON error bodies. */ }

            var text = $"{(int)response.StatusCode}: {detail}";
            throw new UpstreamException((int)response.StatusCode,
                text.Length > 1200 ? text[..1200] : text, stage);
        }

        return JsonNode.Parse(body) ?? new JsonObject();
    }

    /// <summary>Assembles the chat payload, including a vision part when an image is attached.</summary>
    public static List<object> BuildMessages(string systemPrompt, IEnumerable<ChatTurn> history,
        string message, string? imageDataUrl, string? context)
    {
        var system = systemPrompt;
        if (!string.IsNullOrWhiteSpace(context))
        {
            system += "\n\nUse the following document context to answer. " +
                      "Cite the source file name for each fact you use.\n\n" + context;
        }

        var messages = new List<object> { new { role = "system", content = system } };

        foreach (var turn in history)
        {
            if (turn.Role is "user" or "assistant" && !string.IsNullOrWhiteSpace(turn.Content))
                messages.Add(new { role = turn.Role, content = turn.Content });
        }

        if (!string.IsNullOrWhiteSpace(imageDataUrl))
        {
            var parts = new List<object>();
            if (!string.IsNullOrWhiteSpace(message))
                parts.Add(new { type = "text", text = message });
            parts.Add(new { type = "image_url", image_url = new { url = imageDataUrl } });
            messages.Add(new { role = "user", content = parts });
        }
        else
        {
            messages.Add(new { role = "user", content = message });
        }

        return messages;
    }

    /// <summary>
    /// Returns the completion and the parameters that actually worked.
    ///
    /// Models disagree about max_tokens vs max_completion_tokens, and about whether
    /// temperature may be set at all. The resolver decides up front; if the provider
    /// rejects the choice with a 400 that names the right parameter, it is corrected,
    /// remembered, and retried - so an unrecognised model costs a round trip or two,
    /// not a failed demo.
    ///
    /// Up to two corrections, because there are two correctable parameters and a model
    /// that rejects max_tokens usually rejects the temperature as well: the first 400
    /// names the token parameter, and only once that is fixed does the second surface.
    /// </summary>
    public async Task<(JsonNode Completion, ModelParams Used)> ChatCompletionAsync(
        AiConnection conn, List<object> messages, string correlationId,
        ModelParamResolver resolver, CancellationToken ct)
    {
        var parameters = resolver.ForModel(conn.ChatModel);
        var client = factory.CreateClient("ai");

        for (var attempt = 0; attempt < 3; attempt++)
        {
            var payload = parameters.ApplyTo(new JsonObject
            {
                ["model"] = conn.ChatModel,
                ["messages"] = JsonSerializer.SerializeToNode(messages, Json),
            });

            using var request = BuildRequest(conn, "/chat/completions", payload, correlationId);
            using var response = await client.SendAsync(request, ct);

            if (response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync(ct);
                return (JsonNode.Parse(body) ?? new JsonObject(), parameters);
            }

            if ((int)response.StatusCode == 400 && attempt < 2)
            {
                var error = await response.Content.ReadAsStringAsync(ct);
                var corrected = resolver.Correct(conn.ChatModel, parameters, error);
                if (corrected is not null)
                {
                    parameters = corrected;
                    continue;
                }
            }

            await ReadOrThrowAsync(response, "model", ct);
        }

        throw new UpstreamException(500, "chat completion did not produce a response");
    }

    /// <summary>Embeds a batch. Throws UpstreamException so callers can fall back.</summary>
    public async Task<List<float[]>> EmbedAsync(AiConnection conn, IReadOnlyList<string> inputs,
        string correlationId, CancellationToken ct)
    {
        var payload = new { model = conn.EmbeddingModel, input = inputs };

        var client = factory.CreateClient("ai");
        using var request = BuildRequest(conn, "/embeddings", payload, correlationId);
        using var response = await client.SendAsync(request, ct);
        var node = await ReadOrThrowAsync(response, "embeddings", ct);

        return (node["data"]?.AsArray() ?? [])
            .Where(item => item is not null)
            .OrderBy(item => item!["index"]?.GetValue<int>() ?? 0)
            .Select(item => (item!["embedding"]?.AsArray() ?? [])
                .Select(v => (float)(v?.GetValue<double>() ?? 0))
                .ToArray())
            .ToList();
    }
}

public sealed record ChatTurn(string Role, string Content);
