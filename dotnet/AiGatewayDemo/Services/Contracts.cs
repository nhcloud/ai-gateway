namespace AiGatewayDemo.Services;

// The JSON contract below is shared byte for byte with the Python app, so that
// wwwroot/app.js is identical in both implementations. The `connection` object is
// produced by AiConnection.ToJson(), so there is one definition of that shape.

public sealed record SafetyBundle(
    SafetyVerdict? PromptText, SafetyVerdict? PromptImage,
    SafetyVerdict? PromptShield, SafetyVerdict? Completion);

public sealed record RetrievedChunk(string DocName, int Ordinal, double Score, string Text);

public sealed record RetrievalInfo(bool Used, string Mode, List<RetrievedChunk> Chunks);

public sealed record UsageInfo(int? PromptTokens, int? CompletionTokens, int? TotalTokens);

public sealed record TimingInfo(int SafetyMs, int RetrievalMs, int ModelMs, int TotalMs);

public sealed record ChatResponse(
    object Connection,
    string CorrelationId,
    SafetyBundle Safety,
    RetrievalInfo Retrieval,
    UsageInfo Usage,
    TimingInfo Timings,
    // The parameters actually sent - which model you are on decides whether that
    // is max_tokens or max_completion_tokens, and whether temperature goes at all.
    object Request,
    bool Blocked,
    string? BlockedStage,
    string Reply);

public sealed record ChatRequest(
    string? Message,
    string? ImageDataUrl,
    bool? UseRag,
    List<ChatTurn>? History);
