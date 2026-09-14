"""Checks that both apps derive the same mode from the same endpoint.

How you are connected is not configured - it is worked out from AI_ENDPOINT, in two
places (python/config.py and dotnet/.../GatewayOptions.cs). Duplicated logic drifts,
so this compares them case by case against an expected table.

  python tests/test-mode-detection.py

Each .NET case needs its own process, because configuration is read at startup, so
this takes about a minute. It is not part of verify-apps.py for that reason.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from config import detect_mode  # noqa: E402

PORT = 5183  # clear of the app defaults and the other suites

# endpoint -> expected mode
CASES: list[tuple[str, str]] = [
    ("https://my-aoai.openai.azure.com", "direct"),
    ("https://my-aoai.openai.azure.com/openai/v1", "direct"),
    ("https://my-res.cognitiveservices.azure.com", "direct"),
    ("https://my-proj.services.ai.azure.com", "direct"),
    ("https://api.openai.com/v1", "direct"),
    ("https://my-apim.azure-api.net/aoai", "apim"),
    ("https://my-apim.azure-api.net/aoai/openai/v1", "apim"),
    ("https://my-apim.azure-api.net", "apim"),
    # A classic APIM API whose suffix happens to be "models" is still classic APIM:
    # the AI Gateway shape is /<workspace>/models, two segments.
    ("https://my-apim.azure-api.net/models", "apim"),
    ("https://my-gw.azure-api.net/default/models", "aigateway"),
    ("https://my-gw.azure-api.net/default/models/openai/v1", "aigateway"),
    ("https://my-gw.azure-api.net/team-a/models", "aigateway"),
    ("http://127.0.0.1:5290", "custom"),
    ("https://llama.internal.contoso.com/v1", "custom"),
    ("", "unconfigured"),
]

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'' if ok else f'  <- {detail}'}")
    if not ok:
        failures.append(f"{label}: {detail}")


def dotnet_mode(endpoint: str) -> str | None:
    """Starts the Razor app with this endpoint and asks it what mode it detected."""
    # A blank endpoint cannot be passed as an empty environment variable: Windows
    # treats "VAR=" as unsetting it, and an unset AI_ENDPOINT lets a stray
    # .env supply one instead - which silently turned this case into "apim".
    # A single space is still "set", so nothing shadows it, and the app trims it to
    # blank exactly as it would a blank setting.
    env = {
        **os.environ,
        "AI_ENDPOINT": endpoint or " ",
        "AI_KEY": "probe-key",
        "ASPNETCORE_URLS": f"http://127.0.0.1:{PORT}",
        "ASPNETCORE_ENVIRONMENT": "Production",  # quieter startup
    }
    process = subprocess.Popen(
        ["dotnet", "run", "--project", str(ROOT / "dotnet" / "AiGatewayDemo"), "--no-build"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                with urlopen(f"http://127.0.0.1:{PORT}/api/config", timeout=2) as response:
                    return json.loads(response.read())["connection"]["mode"]
            except (URLError, OSError, KeyError):
                time.sleep(0.5)
        return None
    finally:
        process.terminate()
        process.wait(timeout=20)


def main() -> int:
    print("=== Python detection ===")
    for endpoint, expected in CASES:
        mode = detect_mode(endpoint)[0]
        check(f"{endpoint or '(empty)':52} -> {expected}", mode == expected, f"got {mode}")

    if "--python-only" in sys.argv:
        print("\nSkipping the .NET comparison (--python-only).")
    else:
        print("\n=== .NET detection (one process per case) ===")
        for endpoint, expected in CASES:
            mode = dotnet_mode(endpoint)
            check(f"{endpoint or '(empty)':52} -> {expected}", mode == expected, f"got {mode}")

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("Both implementations agree on every case.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
