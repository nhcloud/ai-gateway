"""Document Intelligence through the gateway.

Shows the long-running-operation shape end to end:
  POST :analyze  -> 202 + Operation-Location
  GET  that URL  -> poll until "succeeded"

The Operation-Location the service builds carries the *resource's* hostname. A
client that follows it verbatim leaves the gateway and gets a 401, because it
holds a gateway key rather than the resource key - which is why the APIM API
carries an outbound policy that rewrites the host back to the gateway. This
client reports which host it was handed so the rewrite is visible in the demo.
"""
from __future__ import annotations

import asyncio
import base64
import csv
import io
import json
import time
from urllib.parse import urlparse

import httpx

from config import Connection

API_VERSION = "2024-11-30"
MODEL_ID = "prebuilt-layout"
TIMEOUT = httpx.Timeout(120.0, connect=15.0)
POLL_SECONDS = 1.5
MAX_POLLS = 60

# Extensions handled locally - no reason to spend a Document Intelligence page on them.
PLAIN_TEXT = {".txt", ".md", ".markdown", ".log", ".json", ".csv", ".tsv", ".xml", ".yaml", ".yml"}
# Everything Document Intelligence prebuilt-layout accepts.
DOCUMENT_TYPES = {".pdf", ".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".tif", ".heif",
                  ".docx", ".xlsx", ".pptx", ".html", ".htm"}


class ExtractionError(RuntimeError):
    pass


def _ext(name: str) -> str:
    dot = name.rfind(".")
    return name[dot:].lower() if dot >= 0 else ""


def _target(conn: Connection) -> tuple[str, str, str]:
    if conn.docintel_endpoint and conn.docintel_key:
        return conn.docintel_endpoint.rstrip("/"), conn.docintel_key, conn.docintel_header
    return "", "", ""


def configured(conn: Connection) -> bool:
    return bool(_target(conn)[0])


def extract_plain_text(name: str, data: bytes) -> str:
    """Decode a text-ish upload, flattening CSV/JSON into something worth embedding."""
    text = data.decode("utf-8", errors="replace")
    ext = _ext(name)

    if ext == ".json":
        try:
            return json.dumps(json.loads(text), indent=2, ensure_ascii=False)
        except ValueError:
            return text

    if ext in (".csv", ".tsv"):
        delimiter = "\t" if ext == ".tsv" else ","
        try:
            rows = list(csv.reader(io.StringIO(text), delimiter=delimiter))
        except csv.Error:
            return text
        if not rows:
            return text
        header, *body = rows
        # One record per paragraph reads far better to an embedding model than a grid.
        return "\n\n".join(
            "; ".join(f"{h}: {v}" for h, v in zip(header, row) if v)
            for row in body if any(row)
        ) or text

    return text


async def analyze_document(conn: Connection, name: str, data: bytes,
                           correlation_id: str) -> tuple[str, int | None, str]:
    """Returns (markdown_content, page_count, note_about_the_polling_host)."""
    endpoint, key, header = _target(conn)
    if not endpoint:
        raise ExtractionError(
            f"'{name}' needs Document Intelligence, which is not configured for this mode. "
            "Upload a .txt/.md/.csv/.json file, or set DOC_INTEL_ENDPOINT / DOC_INTEL_KEY."
        )

    url = (f"{endpoint}/documentintelligence/documentModels/{MODEL_ID}:analyze"
           f"?api-version={API_VERSION}&outputContentFormat=markdown")
    headers = {header: key, "Content-Type": "application/json", "x-correlation-id": correlation_id}
    payload = {"base64Source": base64.b64encode(data).decode("ascii")}

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        submit = await client.post(url, headers=headers, json=payload)
        if submit.status_code not in (200, 202):
            raise ExtractionError(f"Document Intelligence returned {submit.status_code}: {submit.text[:400]}")

        operation_location = submit.headers.get("operation-location") or submit.headers.get("Operation-Location")
        if not operation_location:
            raise ExtractionError("Document Intelligence accepted the document but returned no Operation-Location.")

        gateway_host = urlparse(endpoint).netloc
        poll_host = urlparse(operation_location).netloc
        if poll_host == gateway_host:
            note = f"202 accepted; polled {poll_host} (stayed on the gateway)."
        else:
            note = (f"202 accepted; Operation-Location pointed at {poll_host}, not {gateway_host}. "
                    "Add the outbound Operation-Location rewrite policy to keep polling on the gateway.")
            # Fall back to the resource key so the demo still completes.
            headers = {"Ocp-Apim-Subscription-Key": key, "x-correlation-id": correlation_id}

        for _ in range(MAX_POLLS):
            await asyncio.sleep(POLL_SECONDS)
            poll = await client.get(operation_location, headers=headers)
            if poll.status_code == 401:
                raise ExtractionError(
                    f"Polling {poll_host} returned 401 - the client holds a gateway key, not the resource key. "
                    "This is exactly what the Operation-Location rewrite policy fixes."
                )
            if not poll.is_success:
                raise ExtractionError(f"Polling returned {poll.status_code}: {poll.text[:400]}")

            body = poll.json()
            status = (body.get("status") or "").lower()
            if status == "succeeded":
                result = body.get("analyzeResult", {})
                content = result.get("content", "") or ""
                pages = len(result.get("pages", []) or []) or None
                if not content.strip():
                    raise ExtractionError("Document Intelligence found no text content in this file.")
                return content, pages, note
            if status == "failed":
                error = body.get("error", {}).get("message", "unknown error")
                raise ExtractionError(f"Analysis failed: {error}")

    raise ExtractionError("Timed out waiting for Document Intelligence to finish.")


async def extract(conn: Connection, name: str, data: bytes,
                  correlation_id: str) -> tuple[str, int | None, str, str]:
    """Returns (text, pages, extracted_via, note)."""
    ext = _ext(name)
    started = time.perf_counter()

    if ext in PLAIN_TEXT:
        text = extract_plain_text(name, data)
        if not text.strip():
            raise ExtractionError(f"'{name}' is empty.")
        elapsed = int((time.perf_counter() - started) * 1000)
        return text, None, "local text parsing", f"Plain text - no Document Intelligence call ({elapsed} ms)."

    if ext in DOCUMENT_TYPES or not ext:
        content, pages, note = await analyze_document(conn, name, data, correlation_id)
        return content, pages, f"Document Intelligence ({MODEL_ID})", note

    raise ExtractionError(f"Unsupported file type '{ext or 'unknown'}' for '{name}'.")
