"""Azure AI Content Safety guardrails, run before the model on every turn.

Three checks, all of them inbound-first:

  text:analyze       four harm categories, severity 0-6, plus any custom blocklists
  image:analyze      the same four categories for an attached image
  text:shieldPrompt  Prompt Shields - jailbreak and prompt-injection attempts

A word about what the four categories do and do not cover. They are Hate, SelfHarm,
Sexual and Violence. A request like "how to loot a bank" scores 0 on all four: it is
criminal facilitation, not one of those four harms, so no threshold will catch it.
That is what custom blocklists are for - CONTENT_SAFETY_BLOCKLISTS - and what the
model's own alignment is for. The UI shows all of it, so the difference is visible
rather than surprising.

Two ways to run these guardrails exist, and the demo shows the first so the verdicts
are visible in the UI:
  1. App-side (here): call the APIs, show per-category severities, and block before
     spending a token at the provider.
  2. Policy-side: the APIM `llm-content-safety` policy does the same job inline on
     every request, with no client code. See scripts/policies/.
"""
from __future__ import annotations

import base64
import time

import httpx

from config import Connection, settings

API_VERSION = "2024-09-01"
CATEGORIES = ["Hate", "SelfHarm", "Sexual", "Violence"]
TIMEOUT = httpx.Timeout(30.0, connect=10.0)


def _target(conn: Connection) -> tuple[str, str, str]:
    """Resolve (endpoint, key, header) for Content Safety in this mode."""
    if conn.safety_endpoint and conn.safety_key:
        return conn.safety_endpoint.rstrip("/"), conn.safety_key, conn.safety_header
    return "", "", ""


def _via(conn: Connection) -> str:
    endpoint, _, _ = _target(conn)
    if not endpoint:
        return "not configured"
    return "via gateway" if ".azure-api.net" in endpoint else "direct"


def _verdict(**overrides) -> dict:
    """Every verdict carries the same keys, so the JSON shape matches the .NET app exactly."""
    base = {"checked": False, "blocked": False, "categories": [], "via": "n/a",
            "latencyMs": 0, "threshold": settings.safety_threshold, "reason": None,
            "error": None, "blocklistHits": [], "stage": ""}
    return {**base, **overrides}


def not_checked(reason: str, stage: str = "") -> dict:
    return _verdict(reason=reason, stage=stage)


def configured(conn: Connection) -> bool:
    return bool(_target(conn)[0])


async def _post(conn: Connection, path: str, payload: dict,
                correlation_id: str) -> tuple[dict | None, int, str]:
    """Returns (json_body, elapsed_ms, error_message)."""
    endpoint, key, header = _target(conn)
    url = f"{endpoint}/contentsafety/{path}?api-version={API_VERSION}"
    headers = {header: key, "Content-Type": "application/json", "x-correlation-id": correlation_id}

    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            response = await client.post(url, headers=headers, json=payload)
    except httpx.HTTPError as exc:
        return None, int((time.perf_counter() - started) * 1000), f"Content Safety unreachable: {exc}"

    elapsed = int((time.perf_counter() - started) * 1000)
    if not response.is_success:
        return None, elapsed, f"{response.status_code}: {response.text[:400]}"
    return response.json(), elapsed, ""


async def _analyze(conn: Connection, path: str, payload: dict, correlation_id: str,
                   stage: str) -> dict:
    if not configured(conn):
        return not_checked("Content Safety is not configured for this mode.", stage)

    body, elapsed, error = await _post(conn, path, payload, correlation_id)
    if error:
        return _verdict(checked=True, via=_via(conn), latencyMs=elapsed, error=error, stage=stage)

    categories = [
        {"category": item.get("category", "?"), "severity": int(item.get("severity") or 0)}
        for item in (body or {}).get("categoriesAnalysis", [])
    ]
    # A custom blocklist hit is a block regardless of the category severities - this
    # is how you stop requests the four harm categories were never meant to cover.
    hits = [
        match.get("blocklistName", "?")
        for match in ((body or {}).get("blocklistsMatch") or [])
    ]
    blocked = bool(hits) or any(c["severity"] >= settings.safety_threshold for c in categories)

    return _verdict(checked=True, blocked=blocked, categories=categories, via=_via(conn),
                    latencyMs=elapsed, blocklistHits=hits, stage=stage)


async def analyze_text(conn: Connection, text: str, correlation_id: str,
                       stage: str = "prompt-text") -> dict:
    if not (text or "").strip():
        return not_checked("No text to screen.", stage)

    payload: dict = {
        "text": text[:10000],
        "categories": CATEGORIES,
        "outputType": "FourSeverityLevels",
    }
    if settings.safety_blocklists:
        payload["blocklistNames"] = settings.safety_blocklists
        payload["haltOnBlocklistHit"] = True

    return await _analyze(conn, "text:analyze", payload, correlation_id, stage)


async def analyze_image(conn: Connection, data_url: str, correlation_id: str) -> dict:
    """`data_url` is a browser data: URL; Content Safety wants the bare base64 bytes."""
    raw = data_url.split(",", 1)[-1] if data_url.startswith("data:") else data_url
    try:
        base64.b64decode(raw, validate=True)
    except Exception:  # noqa: BLE001
        return _verdict(checked=True, error="Attachment is not valid base64 image data.",
                        stage="prompt-image")
    return await _analyze(conn, "image:analyze", {"image": {"content": raw}},
                          correlation_id, "prompt-image")


async def shield_prompt(conn: Connection, text: str, documents: list[str],
                        correlation_id: str) -> dict:
    """Prompt Shields: jailbreak and indirect prompt-injection detection.

    Separate from the severity categories - it answers "is this an attack on the
    system", not "is this harmful content". Off unless CONTENT_SAFETY_PROMPT_SHIELD.
    """
    if not settings.prompt_shield:
        return not_checked("Prompt Shields is off (CONTENT_SAFETY_PROMPT_SHIELD).", "prompt-shield")
    if not configured(conn):
        return not_checked("Content Safety is not configured for this mode.", "prompt-shield")
    if not (text or "").strip() and not documents:
        return not_checked("Nothing to screen.", "prompt-shield")

    payload = {"userPrompt": (text or "")[:10000],
               "documents": [d[:10000] for d in documents[:5]]}
    body, elapsed, error = await _post(conn, "text:shieldPrompt", payload, correlation_id)

    if error:
        return _verdict(checked=True, via=_via(conn), latencyMs=elapsed, error=error,
                        stage="prompt-shield")

    prompt_attack = bool(((body or {}).get("userPromptAnalysis") or {}).get("attackDetected"))
    document_attack = any(
        bool((item or {}).get("attackDetected"))
        for item in ((body or {}).get("documentsAnalysis") or [])
    )
    detected = prompt_attack or document_attack

    return _verdict(
        checked=True,
        blocked=detected,
        via=_via(conn),
        latencyMs=elapsed,
        stage="prompt-shield",
        reason=("Jailbreak attempt detected in the prompt." if prompt_attack else
                "Injection detected in the retrieved documents." if document_attack else
                "No attack detected."),
    )


def refusal_message(stage: str, verdict: dict) -> str:
    hits = verdict.get("blocklistHits") or []
    if hits:
        reason = f"a custom blocklist ({', '.join(hits)})"
    elif stage == "prompt-shield":
        reason = verdict.get("reason") or "Prompt Shields"
    else:
        reason = ", ".join(
            f"{c['category']} (severity {c['severity']})"
            for c in verdict.get("categories", [])
            if c["severity"] >= verdict.get("threshold", settings.safety_threshold)
        ) or "policy categories"

    where = {
        "prompt-text": "Your message",
        "prompt-image": "The attached image",
        "prompt-shield": "Your message",
        "completion": "The model's reply",
    }.get(stage, "The content")

    return (
        f"{where} was blocked by the Content Safety guardrail: {reason}. "
        "The request was stopped at the gateway, so nothing was spent at the model provider."
    )
