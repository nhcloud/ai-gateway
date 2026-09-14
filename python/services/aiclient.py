"""Chat completions and embeddings.

This module is deliberately mode-agnostic: it builds one request and sends it to
whichever base URL the selected Connection carries. Direct Azure OpenAI, a classic
APIM instance and the AI Gateway tier all expose the same /openai/v1 surface, so
the only things that change are the host, the path prefix and the key.
"""
from __future__ import annotations

import httpx

from config import Connection
from services.modelparams import ModelParamResolver, ModelParams

TIMEOUT = httpx.Timeout(120.0, connect=15.0)


class UpstreamError(RuntimeError):
    """An error returned by the gateway or the provider, with the status attached."""

    def __init__(self, status: int, message: str, stage: str = "model") -> None:
        super().__init__(message)
        self.status = status
        self.stage = stage


def _headers(conn: Connection, correlation_id: str) -> dict[str, str]:
    return {
        conn.key_header: conn.key,
        "Content-Type": "application/json",
        # Ties the gateway log line to this app's trace. Never put secrets or
        # prompt content in a correlation id.
        "x-correlation-id": correlation_id,
    }


def _raise_for_status(response: httpx.Response, stage: str) -> None:
    if response.is_success:
        return
    detail = response.text
    try:
        body = response.json()
        detail = (
            body.get("error", {}).get("message")
            or body.get("message")
            or body.get("detail")
            or detail
        )
    except Exception:  # noqa: BLE001 - non-JSON error bodies are common at a gateway
        pass
    raise UpstreamError(response.status_code, f"{response.status_code}: {detail}"[:1200], stage)


def build_messages(system_prompt: str, history: list[dict], message: str,
                   image_data_url: str | None, context: str | None) -> list[dict]:
    """Assemble the chat payload, including a vision part when an image is attached."""
    system = system_prompt
    if context:
        system += (
            "\n\nUse the following document context to answer. "
            "Cite the source file name for each fact you use.\n\n" + context
        )

    messages: list[dict] = [{"role": "system", "content": system}]
    for turn in history:
        role = turn.get("role")
        content = turn.get("content")
        if role in ("user", "assistant") and content:
            messages.append({"role": role, "content": content})

    if image_data_url:
        parts: list[dict] = []
        if message:
            parts.append({"type": "text", "text": message})
        parts.append({"type": "image_url", "image_url": {"url": image_data_url}})
        messages.append({"role": "user", "content": parts})
    else:
        messages.append({"role": "user", "content": message})

    return messages


async def chat_completion(conn: Connection, messages: list[dict], correlation_id: str,
                          resolver: ModelParamResolver) -> tuple[dict, ModelParams]:
    """Returns (completion, the parameters that actually worked).

    Models disagree about max_tokens vs max_completion_tokens, and about whether
    temperature may be set at all. The resolver decides up front; if the provider
    rejects the choice with a 400 that names the right parameter, it is corrected,
    remembered, and retried - so an unrecognised model costs a round trip or two,
    not a failed demo.

    Up to two corrections, because there are two correctable parameters and a model
    that rejects max_tokens usually rejects the temperature as well: the first 400
    names the token parameter, and only once that is fixed does the second surface.
    """
    url = f"{conn.chat_base}/chat/completions"
    params = resolver.for_model(conn.chat_model)

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        for attempt in range(3):
            payload = params.apply_to({"model": conn.chat_model, "messages": messages})
            response = await client.post(url, headers=_headers(conn, correlation_id), json=payload)

            if response.is_success:
                return response.json(), params

            if response.status_code == 400 and attempt < 2:
                corrected = resolver.correct(conn.chat_model, params, response.text)
                if corrected:
                    params = corrected
                    continue

            _raise_for_status(response, "model")

    # Unreachable: the loop either returns or raises.
    raise UpstreamError(500, "chat completion did not produce a response", "model")


async def embed(conn: Connection, inputs: list[str], correlation_id: str) -> list[list[float]]:
    """Embed a batch of strings. Raises UpstreamError so callers can fall back."""
    payload = {"model": conn.embedding_model, "input": inputs}
    url = f"{conn.chat_base}/embeddings"
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        response = await client.post(url, headers=_headers(conn, correlation_id), json=payload)
    _raise_for_status(response, "embeddings")
    data = response.json().get("data", [])
    return [item["embedding"] for item in sorted(data, key=lambda d: d.get("index", 0))]
