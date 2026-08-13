from __future__ import annotations

import json
import logging
import os
from collections.abc import Iterator
from contextlib import asynccontextmanager
from functools import lru_cache
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from core import health as health_service
from core.assistant import AssistantUnavailable, OllamaClient
from core.audit import JsonLineAuditSink
from core.model_runtime import ModelRuntime
from core.request_limits import ClientRateLimiter, GlobalConcurrencyLimiter
from core.service import AssistantService


ROOT = Path(__file__).resolve().parents[1]


def load_settings() -> dict[str, Any]:
    local = ROOT / "config" / "settings.local.json"
    source = local if local.exists() else ROOT / "config" / "settings.json"
    with source.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_version() -> str:
    return (ROOT / "VERSION").read_text(encoding="utf-8").strip()


class StrictRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")


class GenerateRequest(StrictRequest):
    model: str = Field(min_length=1, max_length=200)
    prompt: str = Field(min_length=1)
    stream: bool


class GenerateResponse(BaseModel):
    response: str
    done: bool = True


class ChatRequest(StrictRequest):
    message: str = Field(min_length=1)


class ChatResponse(BaseModel):
    reply: str
    done: bool = True


def validate_settings(source: dict[str, Any]) -> None:
    origins = source.get("allowed_origins", [])
    if not isinstance(origins, list) or any(
        not isinstance(origin, str) or not origin.startswith(("https://", "http://"))
        for origin in origins
    ):
        raise ValueError("allowed_origins must be an explicit origin list")
    if "*" in origins:
        raise ValueError("Wildcard Blue AI origins are forbidden")
    if not 1 <= int(source.get("max_prompt_chars", 12000)) <= 16000:
        raise ValueError("max_prompt_chars must be between 1 and 16000")
    if int(source.get("rate_limit_requests_per_minute", 20)) < 1:
        raise ValueError("rate_limit_requests_per_minute must be positive")
    if not 1 <= int(source.get("max_concurrent_inference", 1)) <= 8:
        raise ValueError("max_concurrent_inference must be between 1 and 8")
    if source.get("listen_host") != "127.0.0.1":
        raise ValueError("listen_host must remain 127.0.0.1")


@lru_cache
def get_service() -> AssistantService:
    client = OllamaClient(
        settings["ollama_url"],
        settings["model"],
        float(settings.get("request_timeout_seconds", 180)),
        settings.get("keep_alive", -1),
    )
    return AssistantService(client)


settings = load_settings()
version = load_version()
validate_settings(settings)
ai_audit = JsonLineAuditSink(ROOT / "logs" / "ai-audit.jsonl")
rate_limiter = ClientRateLimiter(
    int(settings.get("rate_limit_requests_per_minute", 20))
)
concurrency_limiter = GlobalConcurrencyLimiter(
    int(settings.get("max_concurrent_inference", 1))
)
model_runtime = ModelRuntime(
    settings["ollama_url"],
    settings["model"],
    settings.get("keep_alive", -1),
    float(settings.get("model_warmup_timeout_seconds", 120)),
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    print(f'Loading {settings["model"]} into memory...', flush=True)
    if model_runtime.warmup():
        print(f'{settings["model"]} ready', flush=True)
        print("Blue AI Assistant ready", flush=True)
    else:
        logging.getLogger("blue_ai.model_runtime").error(
            "Model warmup failed: model=%s error=%s",
            settings["model"],
            model_runtime.last_error or "unknown error",
        )
        print(
            f'Failed to load {settings["model"]}: '
            f'{model_runtime.last_error or "unknown error"}',
            flush=True,
        )
        print("Blue AI Assistant started in degraded state", flush=True)
    yield


app = FastAPI(title="Blue AI Assistant", version=version, lifespan=lifespan)
origins = settings.get("allowed_origins", [])
if origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["Content-Type"],
    )


@app.middleware("http")
async def enforce_configured_origin(request: Request, call_next):
    origin = request.headers.get("origin")
    if origin and origin not in origins:
        ai_audit.record("AI_ORIGIN_FAILURE", "ORIGIN_NOT_ALLOWED")
        return StreamingResponse(
            iter([b'{"detail":"Origin is not allowed."}']),
            status_code=403,
            media_type="application/json",
        )
    return await call_next(request)


@app.get("/health")
def health() -> dict[str, Any]:
    return health_service.build_health_report(
        settings["ollama_url"],
        settings["model"],
        settings["listen_host"] == "127.0.0.1",
        float(settings.get("health_timeout_seconds", 2)),
        loaded=model_runtime.is_loaded(),
        version=version,
    )


def _client_key(request: Request) -> str:
    return request.client.host if request.client else "local-process"


def _reserve_inference(request: Request, prompt: str) -> None:
    if len(prompt) > int(settings.get("max_prompt_chars", 12000)):
        raise HTTPException(status_code=413, detail="Prompt is too large.")
    if not model_runtime.is_loaded():
        raise HTTPException(
            status_code=503,
            detail="AI model is not ready. Check /health and restart to retry warmup.",
        )
    if not rate_limiter.allow(_client_key(request)):
        ai_audit.record("AI_RATE_LIMIT", "RATE_LIMITED")
        raise HTTPException(status_code=429, detail="AI request rate limit exceeded.")
    if not concurrency_limiter.acquire():
        ai_audit.record("AI_CONCURRENCY_LIMIT", "SERVICE_BUSY")
        raise HTTPException(status_code=429, detail="AI generation is already busy.")


def _generate_once(prompt: str) -> str:
    try:
        result = get_service().generate(prompt)
        ai_audit.record("AI_GENERATE", "ACCEPTED")
        return result
    except AssistantUnavailable as exc:
        ai_audit.record("AI_GENERATE", "OLLAMA_UNAVAILABLE")
        raise HTTPException(status_code=503, detail="AI generation is unavailable.") from exc
    except HTTPException:
        raise
    except Exception as exc:
        logging.getLogger("blue_ai.generate").exception("Unexpected AI generation failure")
        ai_audit.record("AI_GENERATE", "INTERNAL_ERROR")
        raise HTTPException(status_code=500, detail="AI generation failed.") from exc
    finally:
        concurrency_limiter.release()


def _ndjson_line(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def _stream_chunks(chunks: Iterator[str]) -> Iterator[bytes]:
    try:
        for chunk in chunks:
            if chunk:
                yield _ndjson_line({"response": chunk})
        yield _ndjson_line({"done": True})
        ai_audit.record("AI_GENERATE_STREAM", "ACCEPTED")
    except AssistantUnavailable:
        ai_audit.record("AI_GENERATE_STREAM", "OLLAMA_UNAVAILABLE")
        yield _ndjson_line({"error": "AI generation failed.", "done": True})
    except Exception:
        logging.getLogger("blue_ai.generate").exception(
            "Unexpected AI streaming failure"
        )
        ai_audit.record("AI_GENERATE_STREAM", "INTERNAL_ERROR")
        yield _ndjson_line({"error": "AI generation failed.", "done": True})
    finally:
        concurrency_limiter.release()


@app.post("/api/generate")
def generate(request: GenerateRequest, raw_request: Request):
    _reserve_inference(raw_request, request.prompt)
    if not request.stream:
        return GenerateResponse(response=_generate_once(request.prompt))
    try:
        # The request model field is compatibility-only. OllamaClient always uses
        # the configured backend model from settings.json.
        chunks = get_service().stream(request.prompt)
    except AssistantUnavailable as exc:
        concurrency_limiter.release()
        ai_audit.record("AI_GENERATE_STREAM", "OLLAMA_UNAVAILABLE")
        raise HTTPException(status_code=503, detail="AI generation is unavailable.") from exc
    except Exception as exc:
        concurrency_limiter.release()
        logging.getLogger("blue_ai.generate").exception(
            "Unable to start AI streaming"
        )
        ai_audit.record("AI_GENERATE_STREAM", "INTERNAL_ERROR")
        raise HTTPException(status_code=500, detail="AI generation failed.") from exc
    return StreamingResponse(
        _stream_chunks(chunks), media_type="application/x-ndjson"
    )


@app.post("/api/assistant/chat", response_model=ChatResponse)
def chat(request: ChatRequest, raw_request: Request) -> ChatResponse:
    _reserve_inference(raw_request, request.message)
    return ChatResponse(reply=_generate_once(request.message))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api.server:app",
        host=os.getenv("BLUE_AI_HOST", settings["listen_host"]),
        port=int(os.getenv("BLUE_AI_PORT", settings["listen_port"])),
        reload=False,
    )
