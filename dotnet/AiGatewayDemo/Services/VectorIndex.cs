using System.Collections.Concurrent;
using System.Text;
using System.Text.RegularExpressions;

namespace AiGatewayDemo.Services;

public sealed record Chunk(string DocId, string DocName, int Ordinal, string Text, float[] Vector);

public sealed class IndexedDocument
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required long SizeBytes { get; init; }
    public required string ExtractedVia { get; init; }
    public required string IndexedVia { get; init; }
    public int? Pages { get; init; }
    public int ElapsedMs { get; set; }
    public List<Chunk> Chunks { get; } = [];

    public object ToJson() => new
    {
        id = Id,
        name = Name,
        sizeBytes = SizeBytes,
        chunks = Chunks.Count,
        pages = Pages,
        extractedVia = ExtractedVia,
        indexedVia = IndexedVia,
        elapsedMs = ElapsedMs,
    };
}

/// <summary>
/// In-memory semantic index. Chunks are embedded over the selected mode; when no
/// embedding model is reachable the hashed term-frequency fallback keeps the demo
/// working end to end, and the UI reports which one produced the vectors.
/// Process lifetime only - a restart clears it.
/// </summary>
public sealed partial class VectorIndex
{
    public const int HashDims = 512;

    // Hyphen and underscore are separators, not word characters: a document saying
    // "Operation-Location" has to match a question asking about "operation location".
    [GeneratedRegex("[a-z0-9][a-z0-9']*", RegexOptions.Compiled)]
    private static partial Regex TokenRegex();

    [GeneratedRegex("\n{3,}", RegexOptions.Compiled)]
    private static partial Regex BlankRunRegex();

    private readonly ConcurrentDictionary<string, IndexedDocument> _docs = new();

    // ── chunking ──────────────────────────────────────────────────────
    public static List<string> ChunkText(string text, int size = 1200, int overlap = 150)
    {
        var chunks = new List<string>();
        text = BlankRunRegex().Replace((text ?? "").Replace("\r\n", "\n").Trim(), "\n\n");
        if (text.Length == 0) return chunks;

        var paragraphs = text.Split("\n\n", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var current = new StringBuilder();

        foreach (var original in paragraphs)
        {
            var para = original;

            // A single oversized paragraph is hard-split.
            while (para.Length > size)
            {
                if (current.Length > 0)
                {
                    chunks.Add(current.ToString());
                    current.Clear();
                }

                var cut = para.LastIndexOf(' ', Math.Min(size, para.Length - 1));
                if (cut <= size / 2) cut = size;
                chunks.Add(para[..cut].Trim());
                para = para[cut..].TrimStart();
            }

            if (para.Length == 0) continue;

            if (current.Length == 0)
            {
                current.Append(para);
            }
            else if (current.Length + para.Length + 2 <= size)
            {
                current.Append("\n\n").Append(para);
            }
            else
            {
                var finished = current.ToString();
                chunks.Add(finished);
                current.Clear();
                var tail = overlap > 0 && finished.Length > overlap ? finished[^overlap..] : "";
                if (tail.Length > 0) current.Append(tail).Append("\n\n");
                current.Append(para);
            }
        }

        if (current.Length > 0) chunks.Add(current.ToString());
        return chunks;
    }

    // ── vectors ───────────────────────────────────────────────────────
    /// <summary>Deterministic hashed term-frequency vector, L2 normalised.</summary>
    public static float[] HashedVector(string text, int dims = HashDims)
    {
        var counts = new Dictionary<int, float>();
        foreach (Match match in TokenRegex().Matches((text ?? "").ToLowerInvariant()))
        {
            if (match.Length < 2) continue;
            var slot = (int)(StableHash(match.ValueSpan) % (uint)dims);
            counts[slot] = counts.GetValueOrDefault(slot) + 1f;
        }

        var vector = new float[dims];
        foreach (var (slot, count) in counts)
            vector[slot] = 1f + MathF.Log(count);

        var norm = MathF.Sqrt(vector.Sum(v => v * v));
        if (norm > 0)
            for (var i = 0; i < dims; i++) vector[i] /= norm;

        return vector;
    }

    /// <summary>FNV-1a: stable across processes, unlike string.GetHashCode.</summary>
    private static uint StableHash(ReadOnlySpan<char> text)
    {
        uint hash = 2166136261;
        foreach (var c in text)
        {
            hash = (hash ^ (byte)c) * 16777619;
            hash = (hash ^ (byte)(c >> 8)) * 16777619;
        }
        return hash;
    }

    public static double Cosine(float[] a, float[] b)
    {
        if (a.Length == 0 || a.Length != b.Length) return 0;
        double dot = 0, na = 0, nb = 0;
        for (var i = 0; i < a.Length; i++)
        {
            dot += a[i] * b[i];
            na += a[i] * a[i];
            nb += b[i] * b[i];
        }
        return na == 0 || nb == 0 ? 0 : dot / Math.Sqrt(na * nb);
    }

    // ── index ─────────────────────────────────────────────────────────
    public IndexedDocument Add(string name, long sizeBytes, string extractedVia, string indexedVia,
        int? pages, IReadOnlyList<string> texts, IReadOnlyList<float[]> vectors, int elapsedMs)
    {
        var doc = new IndexedDocument
        {
            Id = Guid.NewGuid().ToString("n")[..12],
            Name = name,
            SizeBytes = sizeBytes,
            ExtractedVia = extractedVia,
            IndexedVia = indexedVia,
            Pages = pages,
            ElapsedMs = elapsedMs,
        };

        for (var i = 0; i < texts.Count; i++)
            doc.Chunks.Add(new Chunk(doc.Id, name, i, texts[i], vectors[i]));

        _docs[doc.Id] = doc;
        return doc;
    }

    public bool Remove(string id) => _docs.TryRemove(id, out _);

    public IReadOnlyList<IndexedDocument> Documents() => _docs.Values.ToList();

    public int TotalChunks() => _docs.Values.Sum(d => d.Chunks.Count);

    public bool IsEmpty => TotalChunks() == 0;

    public List<(Chunk Chunk, double Score)> Search(float[] queryVector, int topK = 4, double minScore = 0.05)
        => _docs.Values
            .SelectMany(d => d.Chunks)
            .Select(c => (Chunk: c, Score: Cosine(queryVector, c.Vector)))
            .OrderByDescending(x => x.Score)
            .Take(topK)
            .Where(x => x.Score >= minScore)
            .ToList();
}
