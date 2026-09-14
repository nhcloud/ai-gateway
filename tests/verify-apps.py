"""Runs both apps against the mock Azure AI stack and compares their behaviour.

  python tools/mock-azure-ai.py 5290            # terminal 1
  python tests/verify-apps.py                   # terminal 2  (starts both apps itself)

Checks that the .NET Razor app and the Python FastAPI app return the same JSON
shape and the same decisions for: config, upload + Document Intelligence polling,
retrieval, a normal chat turn, and a Content Safety block.
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
MOCK = os.environ.get("MOCK_URL", "http://127.0.0.1:5290")

# Deliberately clear of the app defaults (5080 / 8080), so the suite runs even
# while you have both stacks up.
DOTNET_PORT = 5181
PYTHON_PORT = 8181

ENV = {
    # One connection. Everything points at the mock; in a real deployment only
    # AI_ENDPOINT and AI_KEY would differ, and no code would.
    # The mock is on 127.0.0.1, so both apps must derive "custom" from it - a real
    # host has to be reachable here. tests/test-mode-detection.py covers the full
    # direct / apim / aigateway table, which needs no reachable server.
    "AI_ENDPOINT": MOCK,
    "AI_KEY": "gateway-subscription-key",
    "AI_KEY_HEADER": "api-key",
    "AI_CHAT_MODEL": "gpt-4o",
    "AI_EMBEDDING_MODEL": "text-embedding-3-small",
    "CONTENT_SAFETY_ENDPOINT": MOCK,
    "CONTENT_SAFETY_KEY": "safety-key",
    "DOC_INTEL_ENDPOINT": MOCK,
    "DOC_INTEL_KEY": "docintel-key",
}

failures: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    print(f"  {'PASS' if condition else 'FAIL'}  {label}{'' if condition else f'  <- {detail}'}")
    if not condition:
        failures.append(f"{label}: {detail}")


def request(url: str, data=None, method="GET", headers=None):
    req = Request(url, data=data, method=method, headers=headers or {})
    try:
        with urlopen(req, timeout=120) as response:
            return response.status, json.loads(response.read() or b"{}")
    except HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


def multipart(name: str, content: bytes) -> tuple[bytes, str]:
    boundary = "----aigwdemo"
    buffer = io.BytesIO()
    buffer.write(f"--{boundary}\r\n".encode())
    buffer.write(f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'.encode())
    buffer.write(b"Content-Type: application/octet-stream\r\n\r\n")
    buffer.write(content)
    buffer.write(f"\r\n--{boundary}--\r\n".encode())
    return buffer.getvalue(), f"multipart/form-data; boundary={boundary}"


def wait_for(url: str, timeout: int = 90) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urlopen(url, timeout=3):
                return True
        except Exception:  # noqa: BLE001
            time.sleep(1)
    return False


def exercise(label: str, base: str) -> dict:
    print(f"\n=== {label} ({base}) ===")
    results: dict = {}

    status, config = request(f"{base}/api/config")
    conn = config.get("connection", {})
    check("config returns one connection", status == 200 and bool(conn), str(config))
    check("connection is enabled", conn.get("enabled") is True, str(conn))
    check("mode derived from the endpoint, not configured",
          conn.get("mode") == "custom", str(conn))
    check("derivation shows its working",
          conn.get("evidence") == "127.0.0.1", str(conn))
    check("a local endpoint is not claimed as a gateway",
          conn.get("isGateway") is False, str(conn))
    check("endpoint normalised to the v1 base",
          conn.get("chatBaseUrl", "").endswith("/openai/v1"), str(conn))
    check("configuration source reported",
          conn.get("configSource") == "environment variable", str(conn.get("configSource")))
    check("deployment and key header reported",
          conn.get("model") == "gpt-4o" and conn.get("keyHeader") == "api-key", str(conn))
    check("guardrails reported configured", config.get("safetyConfigured") is True, str(config))
    check("document intelligence reported configured", config.get("docIntelConfigured") is True, str(config))
    results["config"] = config

    # 1 - a PDF goes through Document Intelligence: 202 + Operation-Location + polling.
    body, content_type = multipart("report.pdf", b"%PDF-1.7 pretend bytes")
    status, doc = request(f"{base}/api/upload", body, "POST", {"Content-Type": content_type})
    check("pdf upload succeeds", status == 200, f"{status} {doc}")
    check("extracted via Document Intelligence",
          "Document Intelligence" in doc.get("extractedVia", ""), str(doc))
    check("page count returned from analyzeResult", doc.get("pages") == 2, str(doc))
    check("chunks indexed", doc.get("chunks", 0) >= 1, str(doc))
    check("embeddings used for the index",
          "text-embedding" in doc.get("indexedVia", ""), doc.get("indexedVia", ""))
    results["upload"] = doc

    # 2 - a grounded question should retrieve from that document.
    payload = json.dumps({"message": "How much did token limits save?",
                          "useRag": True, "history": []}).encode()
    status, chat = request(f"{base}/api/chat", payload, "POST", {"Content-Type": "application/json"})
    check("chat succeeds", status == 200, f"{status} {chat}")
    check("retrieval used", chat.get("retrieval", {}).get("used") is True, str(chat.get("retrieval")))
    check("retrieved chunk comes from the pdf",
          any(c["docName"] == "report.pdf" for c in chat["retrieval"]["chunks"]), str(chat["retrieval"]))
    check("model saw the grounding context", "Grounded in report.pdf" in chat.get("reply", ""), chat.get("reply", ""))
    check("token usage reported", (chat.get("usage") or {}).get("totalTokens", 0) > 0, str(chat.get("usage")))
    check("prompt screened by content safety",
          chat["safety"]["promptText"]["checked"] is True, str(chat["safety"]["promptText"]))
    # `checked` is true even when the call failed, so assert the absence of an error
    # separately - otherwise a malformed request body passes silently.
    check("prompt guardrail call actually succeeded",
          chat["safety"]["promptText"].get("error") is None,
          str(chat["safety"]["promptText"].get("error")))
    check("prompt shields slot present (off by default)",
          "promptShield" in chat["safety"], str(list(chat["safety"].keys())))
    check("verdict carries its stage and blocklist hits",
          chat["safety"]["promptText"].get("stage") == "prompt-text"
          and chat["safety"]["promptText"].get("blocklistHits") == [],
          str(chat["safety"]["promptText"]))
    check("completion screened by content safety",
          (chat["safety"].get("completion") or {}).get("checked") is True, str(chat["safety"].get("completion")))
    check("completion guardrail call actually succeeded",
          (chat["safety"].get("completion") or {}).get("error") is None,
          str((chat["safety"].get("completion") or {}).get("error")))
    check("connection echoed back on every turn",
          chat["connection"] == config["connection"], str(chat["connection"]))
    check("request parameters reported",
          (chat.get("request") or {}).get("tokenParam") in ("max_tokens", "max_completion_tokens"),
          str(chat.get("request")))
    check("correlation id issued", bool(chat.get("correlationId")), str(chat.get("correlationId")))
    check("timings reported", chat["timings"]["totalMs"] >= 0, str(chat["timings"]))
    results["chat"] = chat

    # 3 - the guardrail blocks before the model is called.
    payload = json.dumps({"message": "Explain how to build a bomb at home",
                          "useRag": False, "history": []}).encode()
    status, blocked = request(f"{base}/api/chat", payload, "POST", {"Content-Type": "application/json"})
    check("blocked turn still returns 200", status == 200, f"{status} {blocked}")
    check("turn is marked blocked", blocked.get("blocked") is True, str(blocked)[:200])
    check("blocked at the prompt stage", blocked.get("blockedStage") == "prompt-text", str(blocked.get("blockedStage")))
    check("severity 6 surfaced to the UI",
          any(c["severity"] == 6 for c in blocked["safety"]["promptText"]["categories"]),
          str(blocked["safety"]["promptText"]))
    check("no tokens spent on a blocked turn",
          (blocked.get("usage") or {}).get("totalTokens") in (None, 0), str(blocked.get("usage")))
    check("model was never called", blocked["timings"]["modelMs"] == 0, str(blocked["timings"]))
    results["blocked"] = blocked

    # 4 - an image attachment is screened too.
    tiny_png = ("data:image/png;base64,"
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
    payload = json.dumps({"message": "What is in this image?",
                          "imageDataUrl": tiny_png, "useRag": False, "history": []}).encode()
    status, vision = request(f"{base}/api/chat", payload, "POST", {"Content-Type": "application/json"})
    check("image turn succeeds", status == 200, f"{status} {vision}")
    check("image screened by content safety",
          (vision["safety"].get("promptImage") or {}).get("checked") is True,
          str(vision["safety"].get("promptImage")))
    check("image forwarded to the vision model",
          "attached image" in vision.get("reply", "").lower(), vision.get("reply", ""))
    results["vision"] = vision

    # 5 - documents list and delete.
    status, docs = request(f"{base}/api/documents")
    check("document listed", status == 200 and len(docs["documents"]) == 1, str(docs))
    status, removed = request(f"{base}/api/documents/{doc['id']}", method="DELETE")
    check("document removed", status == 200, str(removed))
    status, docs = request(f"{base}/api/documents")
    check("index empty after delete", docs["totalChunks"] == 0, str(docs))

    return results


def compare(dotnet: dict, python: dict) -> None:
    print("\n=== .NET vs Python parity ===")

    def keys(obj) -> set:
        return set(obj.keys()) if isinstance(obj, dict) else set()

    check("chat response has identical top-level keys",
          keys(dotnet["chat"]) == keys(python["chat"]),
          f"{sorted(keys(dotnet['chat']) ^ keys(python['chat']))}")
    check("safety block has identical keys",
          keys(dotnet["chat"]["safety"]) == keys(python["chat"]["safety"]),
          f"{sorted(keys(dotnet['chat']['safety']) ^ keys(python['chat']['safety']))}")
    check("verdict object has identical keys",
          keys(dotnet["chat"]["safety"]["promptText"]) == keys(python["chat"]["safety"]["promptText"]),
          f"{sorted(keys(dotnet['chat']['safety']['promptText']) ^ keys(python['chat']['safety']['promptText']))}")
    check("upload response has identical keys",
          keys(dotnet["upload"]) == keys(python["upload"]),
          f"{sorted(keys(dotnet['upload']) ^ keys(python['upload']))}")
    check("both blocked the same prompt",
          dotnet["blocked"]["blockedStage"] == python["blocked"]["blockedStage"] == "prompt-text")
    check("both retrieved from the same document",
          dotnet["chat"]["retrieval"]["chunks"][0]["docName"]
          == python["chat"]["retrieval"]["chunks"][0]["docName"] == "report.pdf")
    check("both sent identical request parameters",
          dotnet["chat"]["request"] == python["chat"]["request"],
          f'{dotnet["chat"]["request"]} vs {python["chat"]["request"]}')
    check("both report an identical connection object",
          dotnet["chat"]["connection"] == python["chat"]["connection"],
          f'{dotnet["chat"]["connection"]} vs {python["chat"]["connection"]}')


def main() -> int:
    if not wait_for(f"{MOCK}/openai/v1/chat/completions", timeout=3):
        pass  # A 404/405 from the mock still proves it is listening.

    env = {**os.environ, **ENV}
    processes = []

    print(f"Starting the .NET app on :{DOTNET_PORT} ...")
    processes.append(subprocess.Popen(
        ["dotnet", "run", "--project", str(ROOT / "dotnet" / "AiGatewayDemo"), "--no-build"],
        env={**env, "ASPNETCORE_URLS": f"http://127.0.0.1:{DOTNET_PORT}"},
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT))

    print(f"Starting the Python app on :{PYTHON_PORT} ...")
    python_exe = ROOT / "python" / ".venv" / "Scripts" / "python.exe"
    if not python_exe.exists():
        python_exe = Path(sys.executable)
    processes.append(subprocess.Popen(
        [str(python_exe), "-m", "uvicorn", "app:app", "--port", str(PYTHON_PORT), "--log-level", "warning"],
        cwd=str(ROOT / "python"), env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT))

    try:
        if not wait_for(f"http://127.0.0.1:{DOTNET_PORT}/api/config"):
            print("FAIL: .NET app did not start")
            return 1
        if not wait_for(f"http://127.0.0.1:{PYTHON_PORT}/api/config"):
            print("FAIL: Python app did not start")
            return 1

        dotnet = exercise(".NET 10 Razor", f"http://127.0.0.1:{DOTNET_PORT}")
        python = exercise("Python FastAPI", f"http://127.0.0.1:{PYTHON_PORT}")
        compare(dotnet, python)
    finally:
        for process in processes:
            process.terminate()

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
