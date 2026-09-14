"""In-memory semantic index.

Chunks are embedded with the embedding model reached over the currently selected
mode (direct / APIM / AI Gateway). If no embedding model is configured the index
falls back to a deterministic hashed TF-IDF vector so the demo still works
end to end - the UI reports which of the two produced the vectors.
"""
from __future__ import annotations

import math
import re
import uuid
import zlib
from dataclasses import dataclass, field
from threading import Lock

HASH_DIMS = 512
# Hyphen and underscore are separators, not word characters: a document saying
# "Operation-Location" has to match a question asking about "operation location".
_TOKEN = re.compile(r"[a-z0-9][a-z0-9']*")


# ── chunking ──────────────────────────────────────────────────────────
def chunk_text(text: str, size: int = 1200, overlap: int = 150) -> list[str]:
    """Split on paragraph boundaries, packing up to `size` characters per chunk."""
    text = re.sub(r"\n{3,}", "\n\n", (text or "").strip())
    if not text:
        return []

    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    chunks: list[str] = []
    current = ""

    for para in paragraphs:
        # A single oversized paragraph is hard-split.
        while len(para) > size:
            if current:
                chunks.append(current)
                current = ""
            cut = para.rfind(" ", 0, size)
            cut = cut if cut > size // 2 else size
            chunks.append(para[:cut].strip())
            para = para[cut:].lstrip()

        if not current:
            current = para
        elif len(current) + len(para) + 2 <= size:
            current = f"{current}\n\n{para}"
        else:
            chunks.append(current)
            tail = current[-overlap:] if overlap else ""
            current = f"{tail}\n\n{para}".strip() if tail else para

    if current:
        chunks.append(current)
    return chunks


# ── vectors ───────────────────────────────────────────────────────────
def hashed_vector(text: str, dims: int = HASH_DIMS) -> list[float]:
    """Deterministic hashed TF vector with sub-linear term weighting, L2 normalised."""
    counts: dict[int, float] = {}
    for token in _TOKEN.findall(text.lower()):
        if len(token) < 2:
            continue
        # crc32 rather than hash(): stable across processes and restarts.
        slot = zlib.crc32(token.encode("utf-8")) % dims
        counts[slot] = counts.get(slot, 0.0) + 1.0

    vec = [0.0] * dims
    for slot, count in counts.items():
        vec[slot] = 1.0 + math.log(count)

    norm = math.sqrt(sum(v * v for v in vec))
    return [v / norm for v in vec] if norm else vec


def cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = na = nb = 0.0
    for x, y in zip(a, b):
        dot += x * y
        na += x * x
        nb += y * y
    if na == 0 or nb == 0:
        return 0.0
    return dot / math.sqrt(na * nb)


# ── index ─────────────────────────────────────────────────────────────
@dataclass
class Chunk:
    doc_id: str
    doc_name: str
    ordinal: int
    text: str
    vector: list[float]


@dataclass
class Document:
    id: str
    name: str
    size_bytes: int
    extracted_via: str
    indexed_via: str
    pages: int | None = None
    elapsed_ms: int = 0
    chunks: list[Chunk] = field(default_factory=list)

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "sizeBytes": self.size_bytes,
            "chunks": len(self.chunks),
            "pages": self.pages,
            "extractedVia": self.extracted_via,
            "indexedVia": self.indexed_via,
            "elapsedMs": self.elapsed_ms,
        }


class VectorIndex:
    """Process-lifetime store. Nothing is persisted - restart clears the index."""

    def __init__(self) -> None:
        self._docs: dict[str, Document] = {}
        self._lock = Lock()

    def add(self, name: str, size_bytes: int, extracted_via: str, indexed_via: str,
            pages: int | None, texts: list[str], vectors: list[list[float]],
            elapsed_ms: int) -> Document:
        doc = Document(
            id=uuid.uuid4().hex[:12], name=name, size_bytes=size_bytes,
            extracted_via=extracted_via, indexed_via=indexed_via,
            pages=pages, elapsed_ms=elapsed_ms,
        )
        doc.chunks = [
            Chunk(doc.id, name, i, t, v)
            for i, (t, v) in enumerate(zip(texts, vectors))
        ]
        with self._lock:
            self._docs[doc.id] = doc
        return doc

    def remove(self, doc_id: str) -> bool:
        with self._lock:
            return self._docs.pop(doc_id, None) is not None

    def documents(self) -> list[Document]:
        with self._lock:
            return list(self._docs.values())

    def total_chunks(self) -> int:
        return sum(len(d.chunks) for d in self.documents())

    def is_empty(self) -> bool:
        return self.total_chunks() == 0

    def search(self, query_vector: list[float], top_k: int = 4,
               min_score: float = 0.05) -> list[tuple[Chunk, float]]:
        scored = [
            (chunk, cosine(query_vector, chunk.vector))
            for doc in self.documents()
            for chunk in doc.chunks
        ]
        scored.sort(key=lambda pair: pair[1], reverse=True)
        return [(c, s) for c, s in scored[:top_k] if s >= min_score]


index = VectorIndex()
