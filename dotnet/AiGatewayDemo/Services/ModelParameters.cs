using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AiGatewayDemo.Services;

/// <summary>
/// Per-model request-parameter mapping. Mirrors python/services/modelparams.py.
///
/// Not every model takes the same knobs. The older chat models want `max_tokens`;
/// the newer reasoning families reject it and want `max_completion_tokens` instead,
/// and several accept only their default temperature:
///
///   400: Unsupported parameter: 'max_tokens' is not supported with this model.
///        Use 'max_completion_tokens' instead.
///
/// Four layers, most specific first:
///   1. AI_MODEL_PARAMS - an explicit per-model map, always wins
///   2. AI_TOKEN_PARAM / AI_TEMPERATURE / AI_MAX_TOKENS - global overrides
///   3. a small heuristic on the model name, so the common cases just work
///   4. what the provider itself said - a 400 naming the right parameter is acted
///      on, remembered for the process, and the call retried once
/// </summary>
public sealed record ModelParams(
    string TokenParam = ModelParamResolver.MaxTokens,
    int MaxTokens = 800,
    // Null means "do not send temperature at all" - which is how you satisfy a
    // model that accepts only its own default.
    double? Temperature = 0.2,
    string Source = "default")
{
    public JsonObject ApplyTo(JsonObject payload)
    {
        payload[TokenParam] = MaxTokens;
        if (Temperature is { } value) payload["temperature"] = value;
        return payload;
    }

    public object ToJson() => new
    {
        tokenParam = TokenParam,
        maxTokens = MaxTokens,
        temperature = Temperature,
        source = Source,
    };
}

public sealed partial class ModelParamResolver
{
    public const string MaxTokens = "max_tokens";
    public const string MaxCompletionTokens = "max_completion_tokens";

    // Families that reject max_tokens and accept only their default temperature.
    // A heuristic on the deployment name, nothing more - an explicit override wins,
    // and a 400 from the provider corrects it either way.
    public static readonly string[] ReasoningPrefixes = ["o1", "o3", "o4", "gpt-5"];

    private static readonly string[] OmitWords = ["omit", "none", "default", "unset", "null", ""];

    [GeneratedRegex("max_completion_tokens", RegexOptions.IgnoreCase)]
    private static partial Regex WantsCompletionTokens();

    [GeneratedRegex(@"\bmax_tokens\b.*(not supported|unsupported)|(not supported|unsupported).*\bmax_tokens\b",
        RegexOptions.IgnoreCase)]
    private static partial Regex RejectsMaxTokens();

    [GeneratedRegex("temperature", RegexOptions.IgnoreCase)]
    private static partial Regex MentionsTemperature();

    [GeneratedRegex("only the default|does not support|unsupported value", RegexOptions.IgnoreCase)]
    private static partial Regex DefaultOnly();

    private readonly Dictionary<string, JsonObject> _overrides;
    private readonly ModelParams _defaults;
    private readonly ConcurrentDictionary<string, ModelParams> _learned = new();

    public ModelParamResolver(Dictionary<string, JsonObject>? overrides = null,
        string defaultTokenParam = MaxTokens, int defaultMaxTokens = 800, double? defaultTemperature = 0.2)
    {
        _overrides = overrides ?? new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase);
        _defaults = new ModelParams(defaultTokenParam, defaultMaxTokens, defaultTemperature);
    }

    /// <summary>`omit`/`none`/`default`/blank -> null (send nothing); otherwise a number.</summary>
    public static double? ParseTemperature(string? raw)
    {
        var text = (raw ?? "").Trim().ToLowerInvariant();
        if (OmitWords.Contains(text)) return null;
        return double.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var value)
            ? value : null;
    }

    /// <summary>Accepts the parameter name, or a shorthand like `completion`.</summary>
    public static string ParseTokenParam(string? raw, string fallback = MaxTokens)
    {
        var text = (raw ?? "").Trim().ToLowerInvariant();
        if (text.Length == 0) return fallback;
        if (text is MaxCompletionTokens or "completion" or "max-completion-tokens") return MaxCompletionTokens;
        if (text is MaxTokens or "tokens" or "max-tokens") return MaxTokens;
        return fallback;
    }

    /// <summary>
    /// Parses AI_MODEL_PARAMS. Two accepted spellings, both single-line:
    ///   JSON     {"gpt-5.6-terra": {"tokenParam": "max_completion_tokens", "temperature": "omit"}}
    ///   compact  gpt-5.6-terra=max_completion_tokens/omit, gpt-4o=max_tokens/0.2
    /// </summary>
    public static Dictionary<string, JsonObject> Parse(string? raw)
    {
        var entries = new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase);
        raw = (raw ?? "").Trim();
        if (raw.Length == 0) return entries;

        if (raw.StartsWith('{'))
        {
            try
            {
                foreach (var (key, value) in JsonNode.Parse(raw)?.AsObject() ?? [])
                    if (value is JsonObject entry) entries[key] = entry;
            }
            catch (JsonException) { /* a malformed map is treated as absent */ }
            return entries;
        }

        foreach (var chunk in raw.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var equals = chunk.IndexOf('=');
            if (equals <= 0) continue;

            var model = chunk[..equals].Trim();
            var spec = chunk[(equals + 1)..];
            var slash = spec.IndexOf('/');
            var tokenPart = (slash >= 0 ? spec[..slash] : spec).Trim();
            var temperaturePart = slash >= 0 ? spec[(slash + 1)..].Trim() : "";

            var entry = new JsonObject { ["tokenParam"] = tokenPart };
            if (temperaturePart.Length > 0) entry["temperature"] = temperaturePart;
            entries[model] = entry;
        }

        return entries;
    }

    public ModelParams ForModel(string model)
    {
        var key = model ?? "";

        if (_learned.TryGetValue(key, out var learned)) return learned;

        if (_overrides.TryGetValue(key, out var over))
        {
            var temperature = over.ContainsKey("temperature")
                ? ParseTemperature(over["temperature"]?.ToString())
                : _defaults.Temperature;

            return new ModelParams(
                ParseTokenParam(over["tokenParam"]?.ToString(), _defaults.TokenParam),
                over.TryGetPropertyValue("maxTokens", out var max) && max is not null
                    ? max.GetValue<int>() : _defaults.MaxTokens,
                temperature,
                "AI_MODEL_PARAMS");
        }

        var prefix = ReasoningPrefixes.FirstOrDefault(p =>
            key.StartsWith(p, StringComparison.OrdinalIgnoreCase));

        if (prefix is not null)
        {
            // These families reject max_tokens and accept only their own temperature.
            return _defaults with
            {
                TokenParam = MaxCompletionTokens,
                Temperature = null,
                Source = $"model name starts with '{prefix}'",
            };
        }

        return _defaults;
    }

    /// <summary>Remembers a correction for the rest of the process.</summary>
    public void Learn(string model, ModelParams parameters) => _learned[model ?? ""] = parameters;

    /// <summary>
    /// Reads a provider 400 and returns adjusted parameters, or null if the error is
    /// not about a parameter we know how to move.
    /// </summary>
    public ModelParams? Correct(string model, ModelParams current, string error)
    {
        var corrected = current;
        var changed = new List<string>();

        if ((WantsCompletionTokens().IsMatch(error) || RejectsMaxTokens().IsMatch(error))
            && current.TokenParam != MaxCompletionTokens)
        {
            corrected = corrected with { TokenParam = MaxCompletionTokens };
            changed.Add($"{MaxTokens} -> {MaxCompletionTokens}");
        }

        if (MentionsTemperature().IsMatch(error) && DefaultOnly().IsMatch(error)
            && current.Temperature is not null)
        {
            corrected = corrected with { Temperature = null };
            changed.Add("temperature omitted");
        }

        if (changed.Count == 0) return null;

        corrected = corrected with { Source = $"corrected after a 400 ({string.Join("; ", changed)})" };
        Learn(model, corrected);
        return corrected;
    }
}
