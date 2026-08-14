from __future__ import annotations

import json
from typing import Any, Callable
from urllib.request import urlopen


DEFAULT_TIMEOUT_SECONDS = 2.0


def check_ollama(
    tags_url: str,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    opener: Callable[..., Any] = urlopen,
) -> list[dict[str, Any]] | None:
    """Return Ollama's model list, or None when Ollama cannot be reached."""
    try:
        with opener(tags_url, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, TimeoutError, ValueError, json.JSONDecodeError):
        return None

    models = payload.get("models") if isinstance(payload, dict) else None
    return models if isinstance(models, list) else []


def check_model(models: list[dict[str, Any]], model_name: str) -> bool:
    """Check the exact configured Ollama model name against /api/tags data."""
    return any(
        isinstance(model, dict)
        and (model.get("name") == model_name or model.get("model") == model_name)
        for model in models
    )


def build_health_report(
    ollama_url: str,
    model_name: str,
    localhost_only: bool,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    opener: Callable[..., Any] = urlopen,
    loaded: bool = False,
    version: str | None = None,
) -> dict[str, Any]:
    tags_url = f"{ollama_url.rstrip('/').removesuffix('/api/chat')}/api/tags"
    models = check_ollama(tags_url, timeout, opener)
    reachable = models is not None
    installed = check_model(models, model_name) if models is not None else None

    report = {
        "status": "ok" if reachable and installed and loaded else "degraded",
        "service": "blue-ai-assistant",
        "ollama": {"reachable": reachable},
        "model": {"name": model_name, "installed": installed, "loaded": loaded},
        "localhost_only": localhost_only,
    }
    if version is not None:
        report["version"] = version
    return report
