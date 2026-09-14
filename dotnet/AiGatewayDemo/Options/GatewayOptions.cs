using Microsoft.Extensions.Configuration.EnvironmentVariables;
using Microsoft.Extensions.Configuration.Json;
using Microsoft.Extensions.Configuration.Memory;
// Required for ModelParamResolver below - an editor's "remove unused usings" will
// drop this if its analysis is stale, and the build then fails with CS0246.
using AiGatewayDemo.Services;

namespace AiGatewayDemo.Options;

/// <summary>
/// The one way this instance reaches the AI services.
///
/// Direct Azure OpenAI, a classic APIM instance and the AI Gateway tier (which is APIM
/// underneath) all need exactly the same three things: an endpoint, a deployment name,
/// and a key in a header. The application code is identical for all three - so the
/// configuration is a single connection, AI_ENDPOINT plus AI_KEY.
///
/// There is deliberately no AI_MODE setting: <see cref="Mode"/> is derived from the
/// endpoint, so the page can never disagree with reality.
/// </summary>
public sealed class AiConnection
{
    public required string Mode { get; init; }
    public required string Label { get; init; }
    public required string Note { get; init; }
    /// <summary>The part of the URL the mode was decided on, so the UI can show its working.</summary>
    public required string Evidence { get; init; }
    public required string Endpoint { get; init; }
    public required string Key { get; init; }
    public required string KeyHeader { get; init; }
    public required string ChatModel { get; init; }
    public required string EmbeddingModel { get; init; }
    /// <summary>Where AI_ENDPOINT came from. Configuration has several layers and the
    /// winner is not always the one you edited - so the page says which it was.</summary>
    public string ConfigSource { get; init; } = "default";

    public string SafetyEndpoint { get; init; } = "";
    public string SafetyKey { get; init; } = "";
    public string SafetyHeader { get; init; } = GatewayOptions.ResourceKeyHeader;
    public string DocIntelEndpoint { get; init; } = "";
    public string DocIntelKey { get; init; } = "";
    public string DocIntelHeader { get; init; } = GatewayOptions.ResourceKeyHeader;

    /// <summary>Normalises the configured endpoint to the Azure OpenAI v1 base path.</summary>
    public string ChatBase
    {
        get
        {
            var root = Endpoint.TrimEnd('/');
            if (root.Length == 0) return "";
            return root.EndsWith("/openai/v1", StringComparison.OrdinalIgnoreCase)
                ? root
                : $"{root}/openai/v1";
        }
    }

    public bool Enabled => !string.IsNullOrWhiteSpace(Endpoint) && !string.IsNullOrWhiteSpace(Key);

    public string Reason => Enabled
        ? ""
        : string.IsNullOrWhiteSpace(Endpoint) ? "AI_ENDPOINT is not set." : "AI_KEY is not set.";

    public bool IsGateway => Mode is "apim" or "aigateway";

    public bool SafetyConfigured =>
        !string.IsNullOrWhiteSpace(SafetyEndpoint) && !string.IsNullOrWhiteSpace(SafetyKey);

    public bool DocIntelConfigured =>
        !string.IsNullOrWhiteSpace(DocIntelEndpoint) && !string.IsNullOrWhiteSpace(DocIntelKey);

    /// <summary>The shape the page reads; identical to the Python app's.</summary>
    public object ToJson() => new
    {
        mode = Mode,
        label = Label,
        note = Note,
        evidence = Evidence,
        chatBaseUrl = string.IsNullOrEmpty(ChatBase) ? "(not configured)" : ChatBase,
        keyHeader = KeyHeader,
        model = ChatModel,
        embeddingModel = EmbeddingModel,
        isGateway = IsGateway,
        enabled = Enabled,
        reason = Reason,
        configSource = ConfigSource,
        safetyVia = GatewayOptions.DetectMode(SafetyEndpoint).Mode,
        docIntelVia = GatewayOptions.DetectMode(DocIntelEndpoint).Mode,
    };
}

public sealed class GatewayOptions
{
    public const string ResourceKeyHeader = "Ocp-Apim-Subscription-Key";

    // Hosts that mean "you are talking straight to the provider".
    private static readonly string[] ProviderSuffixes =
    [
        ".openai.azure.com",
        ".cognitiveservices.azure.com",
        ".api.cognitive.microsoft.com",
        ".services.ai.azure.com",
    ];

    private const string GatewaySuffix = ".azure-api.net";

    public AiConnection Connection { get; private set; } = null!;
    public int SafetyThreshold { get; set; } = 4;
    public bool CheckCompletion { get; set; } = true;
    /// <summary>Custom blocklists catch what the four harm categories were never meant
    /// to: criminal facilitation, competitor names, anything you define on the resource.</summary>
    public string[] SafetyBlocklists { get; set; } = [];
    public bool PromptShield { get; set; } = false;
    public int TopK { get; set; } = 4;
    public int ChunkChars { get; set; } = 1200;
    public int ChunkOverlap { get; set; } = 150;
    public int MaxUploadMb { get; set; } = 20;
    public string SystemPrompt { get; set; } = "";

    /// <summary>Decides max_tokens vs max_completion_tokens, and whether temperature
    /// is sent, per model. See Services/ModelParameters.cs.</summary>
    public ModelParamResolver ModelParams { get; private set; } = new();

    /// <summary>
    /// Works out how we are connected, from the endpoint alone. Mirrors detect_mode()
    /// in the Python app exactly.
    /// </summary>
    public static (string Mode, string Label, string Note, string Evidence) DetectMode(string endpoint)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            return ("unconfigured", "Not configured",
                "Set AI_ENDPOINT to the provider, an APIM instance, or the AI Gateway tier.",
                "no endpoint set");
        }

        var absolute = endpoint.Contains("//", StringComparison.Ordinal) ? endpoint : $"https://{endpoint}";
        if (!Uri.TryCreate(absolute, UriKind.Absolute, out var uri))
        {
            return ("custom", "Custom endpoint",
                "The endpoint could not be parsed as a URL, but the app will still try it.",
                endpoint);
        }

        var host = uri.Host.ToLowerInvariant();
        var segments = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);

        if (host.EndsWith(GatewaySuffix, StringComparison.Ordinal))
        {
            // The AI Gateway tier's runtime endpoint is /<workspace>/models/openai/v1,
            // e.g. https://<gateway>.azure-api.net/default/models. A classic APIM
            // instance has an ordinary API suffix instead, e.g. /aoai.
            if (segments.Length >= 2 && segments[1].Equals("models", StringComparison.OrdinalIgnoreCase))
            {
                return ("aigateway", "AI Gateway",
                    "APIM's AI Gateway tier. Routing is by the model value in the request " +
                    "body, not by path. Public preview.",
                    $"{host}/{segments[0]}/models");
            }

            return ("apim", "Classic APIM",
                "The gateway holds the provider credential; the app carries a revocable " +
                "subscription key, and policies apply before the backend is called.",
                host);
        }

        if (ProviderSuffixes.Any(suffix => host.EndsWith(suffix, StringComparison.Ordinal))
            || host == "api.openai.com")
        {
            return ("direct", "Direct",
                "Straight to the provider. The app holds the provider key; no shared " +
                "throttling, quotas or cost view.",
                host);
        }

        return ("custom", "Custom endpoint",
            "Not an Azure host - a self-hosted or OpenAI-compatible endpoint, or the " +
            "demo's local mock. The app treats it exactly like the others.",
            host);
    }

    /// <summary>
    /// Names the configuration provider that supplied a key. Precedence is lowest to
    /// highest: appsettings.json, appsettings.{Environment}.json, user-secrets,
    /// environment variables, and last the .env reader - so an environment variable
    /// set by a launcher silently outranks a value you put in appsettings.
    /// </summary>
    public static string DescribeSource(IConfiguration config, string key)
    {
        if (config is IConfigurationRoot root)
        {
            // The last provider holding the key is the one that wins.
            foreach (var provider in root.Providers.Reverse())
            {
                if (!provider.TryGet(key, out var value) || string.IsNullOrWhiteSpace(value))
                    continue;

                return provider switch
                {
                    EnvironmentVariablesConfigurationProvider => "environment variable",
                    MemoryConfigurationProvider =>
                        DotEnvSource.Length > 0 ? DotEnvSource : "in-memory",
                    JsonConfigurationProvider json =>
                        (json.Source.Path ?? "").Contains("UserSecrets", StringComparison.OrdinalIgnoreCase)
                            ? "user-secrets"
                            : Path.GetFileName(json.Source.Path ?? "a JSON file"),
                    _ => provider.GetType().Name,
                };
            }
        }

        return string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(key))
            ? "not set"
            : "environment variable";
    }

    /// <summary>Set by the .env reader in Program.cs, for DescribeSource to name.</summary>
    public static string DotEnvSource { get; set; } = "";

    /// <summary>A gateway takes the subscription-key header; a resource takes its own.</summary>
    private static string HeaderFor(string endpoint, string explicitHeader, string gatewayHeader)
    {
        if (explicitHeader.Length > 0) return explicitHeader;
        var mode = DetectMode(endpoint).Mode;
        return mode is "apim" or "aigateway" ? gatewayHeader : ResourceKeyHeader;
    }

    /// <summary>
    /// Binds from the same flat keys the Python app reads, so one .env drives both.
    /// </summary>
    public static GatewayOptions FromConfiguration(IConfiguration config)
    {
        // A key present but empty (as appsettings.json ships them) counts as unset.
        string Get(string key, string fallback = "")
        {
            var value = config[key];
            if (string.IsNullOrWhiteSpace(value))
                value = Environment.GetEnvironmentVariable(key);
            return string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
        }

        int GetInt(string key, int fallback) =>
            int.TryParse(Get(key), out var value) ? value : fallback;

        bool GetBool(string key, bool fallback) =>
            bool.TryParse(Get(key), out var value) ? value : fallback;

        var endpoint = Get("AI_ENDPOINT");
        var (mode, label, note, evidence) = DetectMode(endpoint);

        // Azure OpenAI and the APIM Foundry import both accept api-key, so one name works
        // whichever the endpoint turns out to be. The import names it api-key rather than
        // the APIM default Ocp-Apim-Subscription-Key - the most common cause of a 401.
        var keyHeader = Get("AI_KEY_HEADER", "api-key");
        var safetyEndpoint = Get("CONTENT_SAFETY_ENDPOINT");
        var docIntelEndpoint = Get("DOC_INTEL_ENDPOINT");

        return new GatewayOptions
        {
            SafetyThreshold = GetInt("CONTENT_SAFETY_THRESHOLD", 4),
            CheckCompletion = GetBool("CONTENT_SAFETY_CHECK_COMPLETION", true),
            SafetyBlocklists = Get("CONTENT_SAFETY_BLOCKLISTS")
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
            PromptShield = GetBool("CONTENT_SAFETY_PROMPT_SHIELD", false),
            TopK = GetInt("RAG_TOP_K", 4),
            ChunkChars = GetInt("RAG_CHUNK_CHARS", 1200),
            ChunkOverlap = GetInt("RAG_CHUNK_OVERLAP", 150),
            MaxUploadMb = GetInt("MAX_UPLOAD_MB", 20),
            SystemPrompt = Get("SYSTEM_PROMPT",
                "You are a concise assistant demonstrating Azure API Management in front of the Azure AI stack. " +
                "When document context is supplied, answer only from it and name the source file; " +
                "if the context does not contain the answer, say so plainly."),

            ModelParams = new ModelParamResolver(
                ModelParamResolver.Parse(Get("AI_MODEL_PARAMS")),
                ModelParamResolver.ParseTokenParam(Get("AI_TOKEN_PARAM"), ModelParamResolver.MaxTokens),
                GetInt("AI_MAX_TOKENS", 800),
                ModelParamResolver.ParseTemperature(Get("AI_TEMPERATURE", "0.2"))),

            Connection = new AiConnection
            {
                Mode = mode,
                Label = label,
                Note = note,
                Evidence = evidence,
                Endpoint = endpoint,
                Key = Get("AI_KEY"),
                KeyHeader = keyHeader,
                ConfigSource = DescribeSource(config, "AI_ENDPOINT"),
                ChatModel = Get("AI_CHAT_MODEL", "gpt-4o"),
                EmbeddingModel = Get("AI_EMBEDDING_MODEL", "text-embedding-3-small"),
                // Point these at the resources, or at the gateway's paths for them - the
                // header follows from which one it is, and can be overridden.
                SafetyEndpoint = safetyEndpoint,
                SafetyKey = Get("CONTENT_SAFETY_KEY"),
                SafetyHeader = HeaderFor(safetyEndpoint, Get("CONTENT_SAFETY_KEY_HEADER"), keyHeader),
                DocIntelEndpoint = docIntelEndpoint,
                DocIntelKey = Get("DOC_INTEL_KEY"),
                DocIntelHeader = HeaderFor(docIntelEndpoint, Get("DOC_INTEL_KEY_HEADER"), keyHeader),
            },
        };
    }
}
