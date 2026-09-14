"""Per-model request-parameter mapping.

Not every model takes the same knobs. The older chat models want `max_tokens`;
the newer reasoning families reject it and want `max_completion_tokens` instead,
and several of them accept only their default temperature:

    400: Unsupported parameter: 'max_tokens' is not supported with this model.
         Use 'max_completion_tokens' instead.

So the payload is assembled from a resolved parameter set rather than hard-coded.
Four layers, most specific first:

    1. AI_MODEL_PARAMS  - an explicit per-model map, always wins
    2. AI_TOKEN_PARAM / AI_TEMPERATURE / AI_MAX_TOKENS - global overrides
    3. a small heuristic on the model name, so the common cases just work
    4. what the provider itself said - a 400 naming the right parameter is acted
       on, remembered for the process, and the call retried once

Layer 4 means an unknown model corrects itself after one wasted round trip, and
layers 1-3 mean you can avoid even that.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, replace
from threading import Lock

MAX_TOKENS = "max_tokens"
MAX_COMPLETION_TOKENS = "max_completion_tokens"

# Families that reject max_tokens and accept only their default temperature.
# A heuristic on the deployment name, nothing more - an explicit override wins,
# and a 400 from the provider corrects it either way.
REASONING_PREFIXES = ("o1", "o3", "o4", "gpt-5")

# "Use 'max_completion_tokens' instead", in whatever wording the provider chooses.
_WANTS_COMPLETION_TOKENS = re.compile(r"max_completion_tokens", re.I)
_REJECTS_MAX_TOKENS = re.compile(r"\bmax_tokens\b.*(not supported|unsupported)"
                                 r"|(not supported|unsupported).*\bmax_tokens\b", re.I)
_REJECTS_TEMPERATURE = re.compile(r"temperature", re.I)
_DEFAULT_ONLY = re.compile(r"only the default|does not support|unsupported value", re.I)

OMIT_WORDS = {"omit", "none", "default", "unset", "null", ""}


@dataclass(frozen=True)
class ModelParams:
    """The parameters to send for one model."""

    token_param: str = MAX_TOKENS
    max_tokens: int = 800
    # None means "do not send temperature at all" - which is how you satisfy a
    # model that accepts only its own default.
    temperature: float | None = 0.2
    source: str = "default"

    def apply_to(self, payload: dict) -> dict:
        payload[self.token_param] = self.max_tokens
        if self.temperature is not None:
            payload["temperature"] = self.temperature
        return payload

    def to_json(self) -> dict:
        return {
            "tokenParam": self.token_param,
            "maxTokens": self.max_tokens,
            "temperature": self.temperature,
            "source": self.source,
        }


def parse_temperature(raw: str | float | int | None) -> float | None:
    """`omit`/`none`/`default`/blank -> None (send nothing); otherwise a number."""
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        return float(raw)
    text = str(raw).strip().lower()
    if text in OMIT_WORDS:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def parse_token_param(raw: str | None, fallback: str = MAX_TOKENS) -> str:
    """Accepts the parameter name, or a shorthand like `completion`."""
    text = (raw or "").strip().lower()
    if not text:
        return fallback
    if text in (MAX_COMPLETION_TOKENS, "completion", "max-completion-tokens"):
        return MAX_COMPLETION_TOKENS
    if text in (MAX_TOKENS, "tokens", "max-tokens"):
        return MAX_TOKENS
    return fallback


def parse_model_params(raw: str) -> dict[str, dict]:
    """Parses AI_MODEL_PARAMS. Two accepted spellings, both single-line:

        JSON     {"gpt-5.6-terra": {"tokenParam": "max_completion_tokens", "temperature": "omit"}}
        compact  gpt-5.6-terra=max_completion_tokens/omit, gpt-4o=max_tokens/0.2

    In the compact form the part after `/` is the temperature and may be omitted.
    """
    raw = (raw or "").strip()
    if not raw:
        return {}

    if raw.startswith("{"):
        try:
            parsed = json.loads(raw)
            return {str(k).lower(): v for k, v in parsed.items() if isinstance(v, dict)}
        except (ValueError, AttributeError):
            return {}

    entries: dict[str, dict] = {}
    for chunk in raw.split(","):
        if "=" not in chunk:
            continue
        model, _, spec = chunk.partition("=")
        token_part, _, temperature_part = spec.partition("/")
        entry: dict = {"tokenParam": token_part.strip()}
        if temperature_part.strip():
            entry["temperature"] = temperature_part.strip()
        entries[model.strip().lower()] = entry
    return entries


class ModelParamResolver:
    """Resolves - and, when the provider tells us otherwise, learns - the right
    parameters for each model. Safe to share across requests."""

    def __init__(self, overrides: dict[str, dict] | None = None,
                 default_token_param: str = MAX_TOKENS,
                 default_max_tokens: int = 800,
                 default_temperature: float | None = 0.2) -> None:
        self._overrides = overrides or {}
        self._defaults = ModelParams(
            token_param=default_token_param,
            max_tokens=default_max_tokens,
            temperature=default_temperature,
            source="default",
        )
        self._learned: dict[str, ModelParams] = {}
        self._lock = Lock()

    def for_model(self, model: str) -> ModelParams:
        key = (model or "").lower()

        with self._lock:
            if key in self._learned:
                return self._learned[key]

        override = self._overrides.get(key)
        if override:
            return ModelParams(
                token_param=parse_token_param(override.get("tokenParam"),
                                              self._defaults.token_param),
                max_tokens=int(override.get("maxTokens", self._defaults.max_tokens)),
                temperature=(parse_temperature(override.get("temperature"))
                             if "temperature" in override else self._defaults.temperature),
                source="AI_MODEL_PARAMS",
            )

        if key.startswith(REASONING_PREFIXES):
            # These families reject max_tokens and accept only their own temperature.
            return replace(self._defaults,
                           token_param=MAX_COMPLETION_TOKENS,
                           temperature=None,
                           source=f"model name starts with '{self._matched_prefix(key)}'")

        return self._defaults

    @staticmethod
    def _matched_prefix(key: str) -> str:
        return next((p for p in REASONING_PREFIXES if key.startswith(p)), "")

    def learn(self, model: str, params: ModelParams) -> None:
        """Remembers a correction for the rest of the process."""
        with self._lock:
            self._learned[(model or "").lower()] = params

    def correct(self, model: str, current: ModelParams, error: str) -> ModelParams | None:
        """Reads a provider 400 and returns adjusted parameters, or None if the
        error is not about a parameter we know how to move."""
        corrected = current
        changed = []

        if (_WANTS_COMPLETION_TOKENS.search(error) or _REJECTS_MAX_TOKENS.search(error)) \
                and current.token_param != MAX_COMPLETION_TOKENS:
            corrected = replace(corrected, token_param=MAX_COMPLETION_TOKENS)
            changed.append(f"{MAX_TOKENS} -> {MAX_COMPLETION_TOKENS}")

        if _REJECTS_TEMPERATURE.search(error) and _DEFAULT_ONLY.search(error) \
                and current.temperature is not None:
            corrected = replace(corrected, temperature=None)
            changed.append("temperature omitted")

        if not changed:
            return None

        corrected = replace(corrected, source=f"corrected after a 400 ({'; '.join(changed)})")
        self.learn(model, corrected)
        return corrected
