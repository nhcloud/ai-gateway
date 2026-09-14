"""A stand-in for Azure OpenAI, Content Safety and Document Intelligence.

Useful for two things:
  * rehearsing the demo on a plane, with no Azure resources and no spend;
  * proving the .NET and Python apps behave identically (tests/verify-apps.py).

It implements just enough of each REST surface for the demo:
  POST /openai/v1/chat/completions   - o1/o3/o4/gpt-5* reject max_tokens and a
                                       non-default temperature, like the real ones
  POST /openai/v1/embeddings
  POST /contentsafety/text:analyze        - "bomb" or "attack" scores severity 6;
                                            blocklistNames matches loot/heist/launder
  POST /contentsafety/image:analyze       - severity 6 if the image is > 1 MB
  POST /contentsafety/text:shieldPrompt   - jailbreak phrasings set attackDetected
  POST /documentintelligence/documentModels/prebuilt-layout:analyze  -> 202
  GET  /documentintelligence/operations/{id}                          -> succeeded

Run:  python tools/mock-azure-ai.py [port]
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5290
UNSAFE = re.compile(r"\b(bomb|attack|kill|weapon)\w*\b", re.I)

# Model families that reject max_tokens and accept only their default temperature,
# exactly as the real services do - so the apps' parameter mapping and their
# retry-on-400 can be exercised offline.
STRICT_PARAM_PREFIXES = ("o1", "o3", "o4", "gpt-5")

# Extra model names to treat as strict, comma-separated. Lets a test use a name the
# apps' own heuristic does NOT recognise, which is the only way to exercise their
# correct-and-retry path end to end.
STRICT_EXTRA = tuple(
    m.strip().lower() for m in (os.environ.get("MOCK_STRICT_MODELS") or "").split(",") if m.strip()
)


# Terms a "custom blocklist" matches, so the blocklist path can be demonstrated
# offline. On a real resource these live on the Content Safety resource itself.
BLOCKLIST_TERMS = tuple(
    t.strip().lower()
    for t in (os.environ.get("MOCK_BLOCKLIST_TERMS") or "loot,heist,launder").split(",")
    if t.strip()
)

# Prompt Shields fires on the usual jailbreak shapes.
JAILBREAK = re.compile(r"ignore (all )?(previous|prior) instructions|disregard your rules"
                       r"|you are now dan|developer mode|jailbreak", re.I)


def is_strict(model: str) -> bool:
    name = (model or "").lower()
    return name.startswith(STRICT_PARAM_PREFIXES) or name in STRICT_EXTRA

_operations: dict[str, float] = {}


def embedding_for(text: str, dims: int = 64) -> list[float]:
    """Deterministic pseudo-embedding: stable per text, so retrieval is reproducible."""
    digest = hashlib.sha256(text.lower().encode()).digest()
    raw = [(digest[i % len(digest)] - 128) / 128.0 for i in range(dims)]
    # Blend in term presence so semantically similar strings actually score closer.
    for token in re.findall(r"[a-z0-9]+", text.lower()):
        slot = int(hashlib.md5(token.encode()).hexdigest(), 16) % dims
        raw[slot] += 1.0
    norm = sum(v * v for v in raw) ** 0.5 or 1.0
    return [v / norm for v in raw]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # quieter console
        print(f"  mock  {self.command} {self.path.split('?')[0]} -> {args[1] if len(args) > 1 else ''}")

    def handle(self) -> None:
        # Browsers, curl and readiness probes drop connections routinely. Without
        # this, each one prints a socket traceback and buries the demo output.
        try:
            super().handle()
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            pass

    def _send(self, status: int, payload: dict | None, headers: dict[str, str] | None = None) -> None:
        body = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _read_body(self) -> bytes:
        """Handles both Content-Length and chunked bodies.

        .NET's JsonContent cannot compute its length up front, so HttpClient sends
        Transfer-Encoding: chunked - which real Azure endpoints accept and a naive
        Content-Length-only reader would see as an empty body.
        """
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            chunks = bytearray()
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()  # trailing CRLF
                    break
                chunks += self.rfile.read(size)
                self.rfile.readline()  # CRLF after each chunk
            return bytes(chunks)

        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _read_json(self) -> dict:
        try:
            return json.loads(self._read_body() or b"{}")
        except (json.JSONDecodeError, ValueError):
            return {}

    # ── routing ───────────────────────────────────────────────────────
    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?")[0]
        body = self._read_json()

        # Every surface here is also reachable behind an APIM suffix such as
        # /aoai/openai/v1/... , so match on the tail rather than the whole path.
        if path.endswith("/chat/completions"):
            return self._chat(body)
        if path.endswith("/embeddings"):
            return self._embeddings(body)
        if path.endswith("/contentsafety/text:analyze"):
            return self._text_safety(body)
        if path.endswith("/contentsafety/image:analyze"):
            return self._image_safety(body)
        if path.endswith("/contentsafety/text:shieldPrompt"):
            return self._shield_prompt(body)
        if ":analyze" in path and "documentintelligence" in path:
            return self._analyze_document()

        self._send(404, {"error": {"message": f"mock has no route for {path}"}})

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?")[0]
        if "/documentintelligence/operations/" in path:
            return self._poll_operation(path.rsplit("/", 1)[-1])
        self._send(404, {"error": {"message": f"mock has no route for {path}"}})

    # ── handlers ──────────────────────────────────────────────────────
    def _chat(self, body: dict) -> None:
        model = str(body.get("model") or "")

        # Reproduce the two parameter errors these families really return.
        if is_strict(model):
            if "max_tokens" in body:
                return self._send(400, {"error": {
                    "code": "unsupported_parameter",
                    "param": "max_tokens",
                    "message": "Unsupported parameter: 'max_tokens' is not supported with "
                               "this model. Use 'max_completion_tokens' instead.",
                }})
            if body.get("temperature") not in (None, 1, 1.0):
                return self._send(400, {"error": {
                    "code": "unsupported_value",
                    "param": "temperature",
                    "message": f"Unsupported value: 'temperature' does not support "
                               f"{body.get('temperature')} with this model. "
                               "Only the default (1) value is supported.",
                }})

        messages = body.get("messages", [])
        system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
        last = messages[-1] if messages else {}
        content = last.get("content")

        has_image = isinstance(content, list) and any(
            part.get("type") == "image_url" for part in content
        )
        user_text = content if isinstance(content, str) else next(
            (p.get("text", "") for p in (content or []) if p.get("type") == "text"), "")

        # Match the marker the apps inject, not the words in the base system
        # prompt - which also mention "document context".
        grounded = "Use the following document context" in system
        sources = re.findall(r"\[source: ([^,\]]+)", system)

        reply = (
            f"[mock:{body.get('model')}] "
            + (f"Grounded in {', '.join(sorted(set(sources)))}. " if grounded else "")
            + ("I can see the attached image. " if has_image else "")
            + f"You asked: {user_text[:120]}"
        )

        prompt_tokens = sum(len(str(m.get("content", ""))) for m in messages) // 4
        token_param = "max_completion_tokens" if "max_completion_tokens" in body else (
            "max_tokens" if "max_tokens" in body else "none")
        self._send(200, {
            "x_mock_token_param": token_param,
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "model": body.get("model", "mock-model"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": reply}}],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": len(reply) // 4,
                "total_tokens": prompt_tokens + len(reply) // 4,
            },
        })

    def _embeddings(self, body: dict) -> None:
        inputs = body.get("input")
        if isinstance(inputs, str):
            inputs = [inputs]
        self._send(200, {
            "object": "list",
            "model": body.get("model", "mock-embedding"),
            "data": [{"object": "embedding", "index": i, "embedding": embedding_for(text)}
                     for i, text in enumerate(inputs or [])],
            "usage": {"prompt_tokens": sum(len(t) for t in inputs or []) // 4},
        })

    def _shield_prompt(self, body: dict) -> None:
        prompt = body.get("userPrompt", "") or ""
        documents = body.get("documents", []) or []
        self._send(200, {
            "userPromptAnalysis": {"attackDetected": bool(JAILBREAK.search(prompt))},
            "documentsAnalysis": [
                {"attackDetected": bool(JAILBREAK.search(d or ""))} for d in documents
            ],
        })

    def _text_safety(self, body: dict) -> None:
        # The real service validates field types and rejects the whole request. A
        # client that always includes optional fields will send null when they are
        # unset, and this is the 400 it gets back:
        #   Invalid value type for field [haltOnBlocklistHit], it should be bool.
        for field, expected, name in (("haltOnBlocklistHit", bool, "bool"),
                                      ("blocklistNames", list, "array")):
            if field in body and not isinstance(body[field], expected):
                return self._send(400, {"error": {
                    "code": "InvalidRequestBody",
                    "message": f"Invalid value type for field [{field}], it should be {name}.",
                }})

        text = body.get("text", "")
        severity = 6 if UNSAFE.search(text) else 0

        # A custom blocklist hit blocks regardless of the four severities - which is
        # how you stop things like "how to loot a bank", that score 0 on all of them.
        lowered = text.lower()
        matches = [
            {"blocklistName": name, "blocklistItemText": term}
            for name in (body.get("blocklistNames") or [])
            for term in BLOCKLIST_TERMS if term in lowered
        ]

        self._send(200, {"blocklistsMatch": matches, "categoriesAnalysis": [
            {"category": "Hate", "severity": 0},
            {"category": "SelfHarm", "severity": 0},
            {"category": "Sexual", "severity": 0},
            {"category": "Violence", "severity": severity},
        ]})

    def _image_safety(self, body: dict) -> None:
        content = body.get("image", {}).get("content", "")
        severity = 6 if len(content) > 1_000_000 else 0
        self._send(200, {"categoriesAnalysis": [
            {"category": "Hate", "severity": 0},
            {"category": "SelfHarm", "severity": 0},
            {"category": "Sexual", "severity": 0},
            {"category": "Violence", "severity": severity},
        ]})

    def _analyze_document(self) -> None:
        operation_id = f"op{int(time.time() * 1000) % 1_000_000}"
        _operations[operation_id] = time.time()
        host = self.headers.get("Host", f"127.0.0.1:{PORT}")
        # Deliberately built from this service's own hostname - exactly the header
        # the APIM outbound policy has to rewrite back to the gateway.
        self._send(202, None, {
            "Operation-Location": f"http://{host}/documentintelligence/operations/{operation_id}"
                                  f"?api-version=2024-11-30",
        })

    def _poll_operation(self, operation_id: str) -> None:
        started = _operations.get(operation_id)
        if started is None:
            return self._send(404, {"error": {"message": "unknown operation"}})

        # Pretend analysis takes a moment, so the polling loop is actually exercised.
        if time.time() - started < 1.0:
            return self._send(200, {"status": "running"})

        self._send(200, {
            "status": "succeeded",
            "analyzeResult": {
                "apiVersion": "2024-11-30",
                "modelId": "prebuilt-layout",
                "content": (
                    "# Quarterly AI Platform Report\n\n"
                    "The gateway processed 1.2 million requests this quarter across four models.\n\n"
                    "Token limits rejected 3% of requests before they reached a provider, "
                    "saving an estimated 14,000 USD.\n\n"
                    "The semantic cache served 22% of completions with no backend call.\n\n"
                    "Document Intelligence extracted 8,400 pages through the same gateway."
                ),
                "pages": [{"pageNumber": 1}, {"pageNumber": 2}],
            },
        })


if __name__ == "__main__":
    print(f"Mock Azure AI stack listening on http://127.0.0.1:{PORT}")
    print("  chat/embeddings : /openai/v1/*")
    print("  content safety  : /contentsafety/*   ('bomb', 'attack', 'kill', 'weapon' -> severity 6)")
    print("  doc intelligence: /documentintelligence/*")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
