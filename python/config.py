"""Configuration for the AI Gateway demo.

Direct Azure OpenAI, a classic APIM instance and the AI Gateway tier (which is APIM
underneath) all need exactly the same three things: an endpoint, a deployment name,
and a key in a header. The application code is identical for all three - so the
configuration is a single connection:

    AI_ENDPOINT
    AI_KEY

There is deliberately no AI_MODE setting. How you are connected is *derived from the
endpoint*, so the page can never disagree with reality - a label you set by hand can
be stale or simply wrong, and a wrong badge in front of an audience is worse than none.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

from dotenv import load_dotenv

from services.modelparams import (MAX_TOKENS, ModelParamResolver, parse_model_params,
                                  parse_temperature, parse_token_param)

# Captured before the .env is loaded, so we can tell a real environment variable
# apart from one the .env supplied - configuration has layers, and the winner is
# not always the one you edited.
_ENV_BEFORE_DOTENV = set(os.environ)


def _load_env_file() -> str:
    """Finds the .env: this stack's own first, then the shared one at the repo root.

    The root file is what scripts/03-set-local-env.ps1 writes, so both stacks read
    the same configuration by default. A python/.env overrides it for this stack
    only - which is how you point the two apps at different endpoints and compare
    them side by side.
    """
    here = Path(__file__).resolve().parent
    for candidate in (here / ".env", here.parent / ".env"):
        if candidate.is_file():
            load_dotenv(candidate, override=False)
            return str(candidate)
    return ""


ENV_FILE = _load_env_file()


def describe_source(name: str) -> str:
    """Names where a setting came from, for the UI to report."""
    if name in _ENV_BEFORE_DOTENV:
        return "environment variable"
    if os.getenv(name):
        return f"{Path(ENV_FILE).parent.name}/.env" if ENV_FILE else "environment variable"
    return "not set"

DEFAULT_RESOURCE_HEADER = "Ocp-Apim-Subscription-Key"

# Hosts that mean "you are talking straight to the provider".
PROVIDER_SUFFIXES = (
    ".openai.azure.com",
    ".cognitiveservices.azure.com",
    ".api.cognitive.microsoft.com",
    ".services.ai.azure.com",
)
GATEWAY_SUFFIX = ".azure-api.net"


def _env(name: str, default: str = "") -> str:
    """A key that is present but empty counts as unset."""
    value = (os.getenv(name) or "").strip()
    return value if value else default


def _bool(name: str, default: bool) -> bool:
    raw = _env(name)
    return default if not raw else raw.lower() in ("1", "true", "yes", "on")


def _openai_base(root: str) -> str:
    """Normalise an endpoint to the Azure OpenAI v1 base path."""
    root = root.rstrip("/")
    if not root:
        return ""
    return root if root.endswith("/openai/v1") else f"{root}/openai/v1"


def detect_mode(endpoint: str) -> tuple[str, str, str, str]:
    """Work out how we are connected, from the endpoint alone.

    Returns (mode, label, note, evidence) where `evidence` names the part of the URL
    the decision was made on, so the UI can show its working.
    """
    if not endpoint:
        return ("unconfigured", "Not configured",
                "Set AI_ENDPOINT to the provider, an APIM instance, or the AI Gateway tier.",
                "no endpoint set")

    parsed = urlparse(endpoint if "//" in endpoint else f"https://{endpoint}")
    host = (parsed.hostname or "").lower()
    segments = [s for s in (parsed.path or "").split("/") if s]

    if host.endswith(GATEWAY_SUFFIX):
        # The AI Gateway tier's runtime endpoint is /<workspace>/models/openai/v1,
        # e.g. https://<gateway>.azure-api.net/default/models. A classic APIM
        # instance has an ordinary API suffix instead, e.g. /aoai.
        if len(segments) >= 2 and segments[1].lower() == "models":
            return ("aigateway", "AI Gateway",
                    "APIM's AI Gateway tier. Routing is by the model value in the request "
                    "body, not by path. Public preview.",
                    f"{host}/{segments[0]}/models")
        return ("apim", "Classic APIM",
                "The gateway holds the provider credential; the app carries a revocable "
                "subscription key, and policies apply before the backend is called.",
                host)

    if host.endswith(PROVIDER_SUFFIXES) or host == "api.openai.com":
        return ("direct", "Direct",
                "Straight to the provider. The app holds the provider key; no shared "
                "throttling, quotas or cost view.",
                host)

    return ("custom", "Custom endpoint",
            "Not an Azure host - a self-hosted or OpenAI-compatible endpoint, or the "
            "demo's local mock. The app treats it exactly like the others.",
            host or endpoint)


def _header_for(endpoint: str, explicit: str, gateway_header: str) -> str:
    """A gateway takes the subscription-key header; a resource takes its own."""
    if explicit:
        return explicit
    return gateway_header if detect_mode(endpoint)[0] in ("apim", "aigateway") else DEFAULT_RESOURCE_HEADER


@dataclass
class Connection:
    """The one way this instance reaches the AI services."""

    mode: str
    label: str
    note: str
    evidence: str
    endpoint: str
    key: str
    key_header: str
    config_source: str
    chat_model: str
    embedding_model: str
    safety_endpoint: str
    safety_key: str
    safety_header: str
    docintel_endpoint: str
    docintel_key: str
    docintel_header: str

    @property
    def chat_base(self) -> str:
        return _openai_base(self.endpoint)

    @property
    def enabled(self) -> bool:
        return bool(self.endpoint and self.key)

    @property
    def reason(self) -> str:
        if self.enabled:
            return ""
        if not self.endpoint:
            return "AI_ENDPOINT is not set."
        return "AI_KEY is not set."

    @property
    def is_gateway(self) -> bool:
        return self.mode in ("apim", "aigateway")

    def to_json(self) -> dict:
        return {
            "mode": self.mode,
            "label": self.label,
            "note": self.note,
            "evidence": self.evidence,
            "chatBaseUrl": self.chat_base or "(not configured)",
            "keyHeader": self.key_header,
            "model": self.chat_model,
            "embeddingModel": self.embedding_model,
            "isGateway": self.is_gateway,
            "enabled": self.enabled,
            "reason": self.reason,
            "configSource": self.config_source,
            "safetyVia": detect_mode(self.safety_endpoint)[0],
            "docIntelVia": detect_mode(self.docintel_endpoint)[0],
        }


@dataclass
class Settings:
    connection: Connection = field(default=None)  # type: ignore[assignment]
    model_params: ModelParamResolver = field(default=None)  # type: ignore[assignment]
    safety_threshold: int = 4
    check_completion: bool = True
    # Custom blocklists catch what the four harm categories were never meant to:
    # criminal facilitation, competitor names, anything you define on the resource.
    safety_blocklists: list[str] = field(default_factory=list)
    prompt_shield: bool = False
    top_k: int = 4
    chunk_chars: int = 1200
    chunk_overlap: int = 150
    max_upload_mb: int = 20
    system_prompt: str = ""


def load_settings() -> Settings:
    endpoint = _env("AI_ENDPOINT")
    mode, label, note, evidence = detect_mode(endpoint)

    # Azure OpenAI and the APIM Foundry import both accept api-key, so one name works
    # whichever the endpoint turns out to be. The import names it api-key rather than
    # the APIM default Ocp-Apim-Subscription-Key - the most common cause of a 401.
    key_header = _env("AI_KEY_HEADER", "api-key")

    safety_endpoint = _env("CONTENT_SAFETY_ENDPOINT")
    docintel_endpoint = _env("DOC_INTEL_ENDPOINT")

    connection = Connection(
        mode=mode,
        label=label,
        note=note,
        evidence=evidence,
        endpoint=endpoint,
        key=_env("AI_KEY"),
        key_header=key_header,
        config_source=describe_source("AI_ENDPOINT"),
        chat_model=_env("AI_CHAT_MODEL", "gpt-4o"),
        embedding_model=_env("AI_EMBEDDING_MODEL", "text-embedding-3-small"),
        # Point these at the resources, or at the gateway's paths for them - the
        # header follows from which one it is, and can be overridden.
        safety_endpoint=safety_endpoint,
        safety_key=_env("CONTENT_SAFETY_KEY"),
        safety_header=_header_for(safety_endpoint, _env("CONTENT_SAFETY_KEY_HEADER"), key_header),
        docintel_endpoint=docintel_endpoint,
        docintel_key=_env("DOC_INTEL_KEY"),
        docintel_header=_header_for(docintel_endpoint, _env("DOC_INTEL_KEY_HEADER"), key_header),
    )

    # Models disagree about max_tokens vs max_completion_tokens, and about whether
    # temperature may be set at all. See services/modelparams.py.
    model_params = ModelParamResolver(
        overrides=parse_model_params(_env("AI_MODEL_PARAMS")),
        default_token_param=parse_token_param(_env("AI_TOKEN_PARAM"), MAX_TOKENS),
        default_max_tokens=int(_env("AI_MAX_TOKENS", "800")),
        default_temperature=parse_temperature(_env("AI_TEMPERATURE", "0.2")),
    )

    return Settings(
        connection=connection,
        model_params=model_params,
        safety_threshold=int(_env("CONTENT_SAFETY_THRESHOLD", "4")),
        check_completion=_bool("CONTENT_SAFETY_CHECK_COMPLETION", True),
        safety_blocklists=[b.strip() for b in _env("CONTENT_SAFETY_BLOCKLISTS").split(",") if b.strip()],
        prompt_shield=_bool("CONTENT_SAFETY_PROMPT_SHIELD", False),
        top_k=int(_env("RAG_TOP_K", "4")),
        chunk_chars=int(_env("RAG_CHUNK_CHARS", "1200")),
        chunk_overlap=int(_env("RAG_CHUNK_OVERLAP", "150")),
        max_upload_mb=int(_env("MAX_UPLOAD_MB", "20")),
        system_prompt=_env(
            "SYSTEM_PROMPT",
            "You are a concise assistant demonstrating Azure API Management in front of the Azure AI stack. "
            "When document context is supplied, answer only from it and name the source file; "
            "if the context does not contain the answer, say so plainly.",
        ),
    )


settings = load_settings()
