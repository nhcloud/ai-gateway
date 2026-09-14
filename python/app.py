"""AI Gateway demo - Python / FastAPI edition.

One page, one JSON contract, one connection. Whether AI_ENDPOINT points straight at
Azure OpenAI, at a classic APIM instance, or at the AI Gateway tier, this code is
identical - which is the entire argument the demo makes. Which of the three it is
gets derived from the endpoint and reported to the page, never configured.

Mirrors the .NET 10 Razor app in ../dotnet feature for feature.

Run:  ./start.sh          (or: uvicorn app:app --reload --port 8080)
"""
from __future__ import annotations

import time
import uuid
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from config import Connection, settings
from services import aiclient, docintel, safety
from services.vectorindex import chunk_text, hashed_vector, index

STATIC = Path(__file__).parent / "static"

app = FastAPI(title="AI Gateway Demo", docs_url="/swagger", redoc_url=None)


# ── plumbing ──────────────────────────────────────────────────────────
def require_connection() -> Connection:
    conn = settings.connection
    if not conn.enabled:
        raise HTTPException(400, f"No AI connection configured. {conn.reason}")
    return conn


async def vectorise(conn: Connection, texts: list[str], correlation_id: str) -> tuple[list[list[float]], str]:
    """Embeddings over the configured connection, with a local fallback so the demo
    never dead-ends."""
    if conn.embedding_model and conn.enabled:
        try:
            vectors = await aiclient.embed(conn, texts, correlation_id)
            if len(vectors) == len(texts):
                return vectors, f"{conn.embedding_model} ({conn.label})"
        except aiclient.UpstreamError:
            pass  # Fall through to the local vectoriser.
        except Exception:  # noqa: BLE001
            pass
    return [hashed_vector(t) for t in texts], "local hashed TF (no embedding model)"


def new_correlation_id() -> str:
    return f"demo-{uuid.uuid4().hex[:12]}"


@app.exception_handler(aiclient.UpstreamError)
async def upstream_error_handler(_: Request, exc: aiclient.UpstreamError) -> JSONResponse:
    return JSONResponse({"error": str(exc), "stage": exc.stage}, status_code=502)


# ── static page ───────────────────────────────────────────────────────
@app.get("/", include_in_schema=False)
async def home() -> FileResponse:
    return FileResponse(STATIC / "index.html")


# ── config ────────────────────────────────────────────────────────────
@app.get("/api/config")
async def get_config() -> dict:
    conn = settings.connection
    return {
        "connection": conn.to_json(),
        "safetyConfigured": safety.configured(conn),
        "docIntelConfigured": docintel.configured(conn),
        "safetyThreshold": settings.safety_threshold,
        "implementation": "Python / FastAPI",
    }


# ── documents ─────────────────────────────────────────────────────────
@app.get("/api/documents")
async def list_documents() -> dict:
    docs = index.documents()
    return {
        "documents": [d.to_json() for d in docs],
        "totalChunks": index.total_chunks(),
        "embeddingMode": docs[-1].indexed_via if docs else "-",
    }


@app.post("/api/upload")
async def upload(file: UploadFile) -> dict:
    # Not require_connection(): a .txt/.md/.csv file is parsed and vectorised
    # locally, so it indexes fine before any Azure resource exists.
    conn = settings.connection
    correlation_id = new_correlation_id()
    started = time.perf_counter()

    data = await file.read()
    if not data:
        raise HTTPException(400, "The uploaded file is empty.")
    if len(data) > settings.max_upload_mb * 1024 * 1024:
        raise HTTPException(413, f"File exceeds the {settings.max_upload_mb} MB limit.")

    try:
        text, pages, extracted_via, note = await docintel.extract(
            conn, file.filename or "upload", data, correlation_id
        )
    except docintel.ExtractionError as exc:
        raise HTTPException(400, str(exc)) from exc

    chunks = chunk_text(text, settings.chunk_chars, settings.chunk_overlap)
    if not chunks:
        raise HTTPException(400, "Nothing indexable was extracted from this file.")

    vectors, indexed_via = await vectorise(conn, chunks, correlation_id)
    elapsed = int((time.perf_counter() - started) * 1000)

    doc = index.add(
        name=file.filename or "upload", size_bytes=len(data), extracted_via=extracted_via,
        indexed_via=indexed_via, pages=pages, texts=chunks, vectors=vectors, elapsed_ms=elapsed,
    )
    return {**doc.to_json(), "note": note, "correlationId": correlation_id}


@app.delete("/api/documents/{doc_id}")
async def delete_document(doc_id: str) -> dict:
    if not index.remove(doc_id):
        raise HTTPException(404, "No such document.")
    return {"removed": doc_id}


# ── chat ──────────────────────────────────────────────────────────────
@app.post("/api/chat")
async def chat(body: dict) -> dict:
    conn = require_connection()
    correlation_id = new_correlation_id()
    message = (body.get("message") or "").strip()
    image_data_url = body.get("imageDataUrl")
    use_rag = bool(body.get("useRag", True))
    history = body.get("history") or []

    if not message and not image_data_url:
        raise HTTPException(400, "Send a message or attach an image.")

    started = time.perf_counter()
    result: dict = {
        "connection": conn.to_json(),
        "correlationId": correlation_id,
        "safety": {"promptText": None, "promptImage": None,
                   "promptShield": None, "completion": None},
        "retrieval": {"used": False, "mode": "-", "chunks": []},
        "usage": {},
        "timings": {},
        "request": {},
        "blocked": False,
        "blockedStage": None,
        "reply": "",
    }

    # 1 - guardrail the inbound prompt, before a token is spent upstream.
    safety_started = time.perf_counter()
    prompt_verdict = await safety.analyze_text(conn, message, correlation_id)
    result["safety"]["promptText"] = prompt_verdict

    image_verdict = None
    if image_data_url:
        image_verdict = await safety.analyze_image(conn, image_data_url, correlation_id)
        result["safety"]["promptImage"] = image_verdict

    # Prompt Shields answers a different question from the severity categories:
    # "is this an attack on the system", not "is this harmful content".
    shield_verdict = await safety.shield_prompt(conn, message, [], correlation_id)
    result["safety"]["promptShield"] = shield_verdict

    safety_ms = int((time.perf_counter() - safety_started) * 1000)

    for stage, verdict in (("prompt-text", prompt_verdict), ("prompt-image", image_verdict),
                           ("prompt-shield", shield_verdict)):
        if verdict and verdict.get("blocked"):
            result.update(
                blocked=True, blockedStage=stage,
                reply=safety.refusal_message(stage, verdict),
                request=settings.model_params.for_model(conn.chat_model).to_json(),
                timings={"safetyMs": safety_ms, "retrievalMs": 0, "modelMs": 0,
                         "totalMs": int((time.perf_counter() - started) * 1000)},
            )
            return result

    # 2 - retrieve from the in-memory index.
    context = None
    retrieval_ms = 0
    if use_rag and not index.is_empty() and message:
        retrieval_started = time.perf_counter()
        query_vectors, mode = await vectorise(conn, [message], correlation_id)
        hits = index.search(query_vectors[0], settings.top_k)
        retrieval_ms = int((time.perf_counter() - retrieval_started) * 1000)
        if hits:
            context = "\n\n---\n\n".join(
                f"[source: {chunk.doc_name}, chunk {chunk.ordinal + 1}]\n{chunk.text}"
                for chunk, _ in hits
            )
            result["retrieval"] = {
                "used": True,
                "mode": mode,
                "chunks": [
                    {"docName": c.doc_name, "ordinal": c.ordinal, "score": round(s, 4), "text": c.text}
                    for c, s in hits
                ],
            }

    # 3 - the model call. This is the code that does not change between modes.
    model_started = time.perf_counter()
    messages = aiclient.build_messages(
        settings.system_prompt, history, message or "Describe the attached image.",
        image_data_url, context,
    )
    try:
        completion, used_params = await aiclient.chat_completion(
            conn, messages, correlation_id, settings.model_params)
    except aiclient.UpstreamError as exc:
        raise HTTPException(502, f"{conn.label} call failed - {exc}") from exc
    model_ms = int((time.perf_counter() - model_started) * 1000)
    result["request"] = used_params.to_json()

    reply = (completion.get("choices") or [{}])[0].get("message", {}).get("content") or ""
    usage = completion.get("usage") or {}

    # 4 - guardrail the outbound completion too.
    if settings.check_completion and reply:
        completion_verdict = await safety.analyze_text(conn, reply, correlation_id)
        result["safety"]["completion"] = completion_verdict
        safety_ms += completion_verdict.get("latencyMs", 0)
        if completion_verdict.get("blocked"):
            result.update(blocked=True, blockedStage="completion",
                          reply=safety.refusal_message("completion", completion_verdict))
            reply = result["reply"]

    if not result["blocked"]:
        result["reply"] = reply or "(the model returned an empty response)"

    result["usage"] = {
        "promptTokens": usage.get("prompt_tokens"),
        "completionTokens": usage.get("completion_tokens"),
        "totalTokens": usage.get("total_tokens"),
    }
    result["timings"] = {
        "safetyMs": safety_ms,
        "retrievalMs": retrieval_ms,
        "modelMs": model_ms,
        "totalMs": int((time.perf_counter() - started) * 1000),
    }
    return result


# Mounted last so /api/* wins over same-named static files.
app.mount("/", StaticFiles(directory=STATIC), name="static")
