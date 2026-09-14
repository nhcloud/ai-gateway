"""Checks the per-model request-parameter mapping, in both apps.

Some models want `max_tokens`, others reject it and want `max_completion_tokens`;
some accept only their default temperature. Getting it wrong is a hard 400:

    Unsupported parameter: 'max_tokens' is not supported with this model.
    Use 'max_completion_tokens' instead.

The mock reproduces both errors for o1/o3/o4/gpt-5* models, so this exercises the
whole chain offline: the explicit override, the name heuristic, and the
correct-and-retry path for a model nobody recognised.

  MOCK_STRICT_MODELS=terra-x python scripts/mock-azure-ai.py 5290   # terminal 1
  python scripts/test-model-params.py                               # terminal 2

The mock must be started with MOCK_STRICT_MODELS=terra-x: that name is not matched
by either app's heuristic, so it is the only case that really exercises the
correct-and-retry path rather than the up-front mapping.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from services.modelparams import (MAX_COMPLETION_TOKENS, MAX_TOKENS,  # noqa: E402
                                  ModelParamResolver, parse_model_params)

MOCK = os.environ.get("MOCK_URL", "http://127.0.0.1:5290")
# Clear of the app defaults (5080 / 8080) and of the other suites.
DOTNET_PORT = 5182
PYTHON_PORT = 8182

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'' if ok else f'  <- {detail}'}")
    if not ok:
        failures.append(f"{label}: {detail}")


# ── unit: the resolver itself ─────────────────────────────────────────
def test_resolver() -> None:
    print("\n=== Resolver (Python, in process) ===")

    plain = ModelParamResolver()
    p = plain.for_model("gpt-4o")
    check("gpt-4o defaults to max_tokens with a temperature",
          p.token_param == MAX_TOKENS and p.temperature == 0.2, str(p))

    p = plain.for_model("gpt-5.6-terra")
    check("gpt-5.6-terra maps to max_completion_tokens, temperature omitted",
          p.token_param == MAX_COMPLETION_TOKENS and p.temperature is None, str(p))

    p = plain.for_model("o3-mini")
    check("o3-mini maps the same way",
          p.token_param == MAX_COMPLETION_TOKENS and p.temperature is None, str(p))

    p = plain.for_model("my-own-deployment")
    check("an unrecognised name keeps the max_tokens default",
          p.token_param == MAX_TOKENS and p.temperature == 0.2, str(p))

    # Explicit override, compact spelling.
    compact = ModelParamResolver(parse_model_params("my-own-deployment=max_completion_tokens/omit"))
    p = compact.for_model("my-own-deployment")
    check("compact override wins over the default",
          p.token_param == MAX_COMPLETION_TOKENS and p.temperature is None
          and p.source == "AI_MODEL_PARAMS", str(p))

    # Explicit override, JSON spelling, including forcing temperature back on.
    js = ModelParamResolver(parse_model_params(
        '{"gpt-5.6-terra": {"tokenParam": "max_completion_tokens", "temperature": 1, "maxTokens": 2048}}'))
    p = js.for_model("gpt-5.6-terra")
    check("JSON override can re-enable temperature and set maxTokens",
          p.temperature == 1 and p.max_tokens == 2048, str(p))

    # An override may also force a strict-looking model back to max_tokens.
    back = ModelParamResolver(parse_model_params("gpt-5.6-terra=max_tokens/0.3"))
    p = back.for_model("gpt-5.6-terra")
    check("an override beats the name heuristic",
          p.token_param == MAX_TOKENS and p.temperature == 0.3, str(p))

    # Correction from a provider 400.
    learner = ModelParamResolver()
    before = learner.for_model("mystery-model")
    fixed = learner.correct("mystery-model", before,
                            "Unsupported parameter: 'max_tokens' is not supported with this "
                            "model. Use 'max_completion_tokens' instead.")
    check("a 400 naming max_completion_tokens is acted on",
          fixed is not None and fixed.token_param == MAX_COMPLETION_TOKENS, str(fixed))
    check("the correction is remembered for later calls",
          learner.for_model("mystery-model").token_param == MAX_COMPLETION_TOKENS,
          str(learner.for_model("mystery-model")))

    temp_fixed = learner.correct(
        "mystery-model", learner.for_model("mystery-model"),
        "Unsupported value: 'temperature' does not support 0.2 with this model. "
        "Only the default (1) value is supported.")
    check("a temperature 400 drops the parameter",
          temp_fixed is not None and temp_fixed.temperature is None, str(temp_fixed))

    check("an unrelated 400 is not 'corrected'",
          learner.correct("gpt-4o", plain.for_model("gpt-4o"),
                          "Invalid request: messages must not be empty") is None)


# ── integration: both apps against the mock ───────────────────────────
def wait_for(url: str, timeout: int = 60) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urlopen(url, timeout=2):
                return True
        except (URLError, OSError):
            time.sleep(0.5)
    return False


def ask(base: str) -> dict:
    payload = json.dumps({"message": "hi", "useRag": False, "history": []}).encode()
    request = Request(f"{base}/api/chat", data=payload, method="POST",
                      headers={"Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=60) as response:
            return json.loads(response.read())
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc)}


def run_app(kind: str, model: str, extra_env: dict[str, str] | None = None):
    env = {
        **os.environ,
        "AI_ENDPOINT": MOCK,
        "AI_KEY": "probe-key",
        "AI_CHAT_MODEL": model,
        "CONTENT_SAFETY_ENDPOINT": MOCK,
        "CONTENT_SAFETY_KEY": "safety-key",
        **(extra_env or {}),
    }

    if kind == "dotnet":
        env["ASPNETCORE_URLS"] = f"http://127.0.0.1:{DOTNET_PORT}"
        return subprocess.Popen(
            ["dotnet", "run", "--project", str(ROOT / "dotnet" / "AiGatewayDemo"), "--no-build"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT), f"http://127.0.0.1:{DOTNET_PORT}"

    python_exe = ROOT / "python" / ".venv" / "Scripts" / "python.exe"
    if not python_exe.exists():
        python_exe = Path(sys.executable)
    return subprocess.Popen(
        [str(python_exe), "-m", "uvicorn", "app:app", "--port", str(PYTHON_PORT), "--log-level", "error"],
        cwd=str(ROOT / "python"), env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT), f"http://127.0.0.1:{PYTHON_PORT}"


CASES = [
    # model, extra env, expected token param, expected temperature, note
    ("gpt-4o", {}, MAX_TOKENS, 0.2, "classic model keeps max_tokens"),
    ("gpt-5.6-terra", {}, MAX_COMPLETION_TOKENS, None, "heuristic avoids the 400 entirely"),
    # "terra-x" is deliberately NOT matched by the name heuristic; the mock is told
    # to be strict about it (MOCK_STRICT_MODELS below), so the only way this passes
    # is the correct-and-retry path.
    ("terra-x", {}, MAX_COMPLETION_TOKENS, None, "unknown name self-corrects after the 400"),
    ("gpt-4o", {"AI_MODEL_PARAMS": "gpt-4o=max_completion_tokens/omit"},
     MAX_COMPLETION_TOKENS, None, "explicit override is honoured"),
]


def test_app(kind: str, label: str) -> None:
    print(f"\n=== {label} against the mock ===")
    for model, extra, expected_param, expected_temp, note in CASES:
        mock_model = model
        process, base = run_app(kind, mock_model, extra)
        try:
            if not wait_for(f"{base}/api/config"):
                check(f"{note} ({mock_model})", False, "app did not start")
                continue

            result = ask(base)
            request = result.get("request") or {}
            ok = (result.get("usage", {}).get("totalTokens")
                  and request.get("tokenParam") == expected_param
                  and request.get("temperature") == expected_temp)
            check(f"{note} ({mock_model})", bool(ok),
                  f"{request} / {str(result.get('error') or result.get('reply'))[:80]}")
        finally:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()


def main() -> int:
    if not wait_for(f"{MOCK}/", timeout=3):
        pass  # a 404 from the mock still means it is up

    # The retry case needs the mock to reject a name the heuristic does not know.
    probe = Request(f"{MOCK}/openai/v1/chat/completions", method="POST",
                    data=json.dumps({"model": "terra-x", "messages": [], "max_tokens": 8}).encode(),
                    headers={"Content-Type": "application/json"})
    try:
        with urlopen(probe, timeout=5):
            print("NOTE: start the mock with MOCK_STRICT_MODELS=terra-x, or the "
                  "correct-and-retry case is not really tested.")
            return 1
    except Exception:  # noqa: BLE001 - a 400 here is exactly what we want
        pass

    test_resolver()
    if "--unit-only" not in sys.argv:
        test_app("python", "Python FastAPI")
        test_app("dotnet", ".NET 10 Razor")

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("Parameter mapping works in both apps.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
