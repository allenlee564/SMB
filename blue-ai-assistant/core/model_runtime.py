from __future__ import annotations

import json
import socket
import threading
import urllib.error
import urllib.request
from typing import Any, Callable


class ModelRuntime:
    """Track whether this service successfully loaded its configured model."""

    def __init__(self, ollama_url: str, model: str, keep_alive: int | str = -1,
                 warmup_timeout_seconds: float = 120,
                 opener: Callable[..., Any] = urllib.request.urlopen) -> None:
        base_url = ollama_url.rstrip("/")
        for suffix in ("/api/chat", "/api/generate"):
            if base_url.endswith(suffix):
                base_url = base_url[:-len(suffix)]
        self.warmup_url = f"{base_url}/api/generate"
        self.model = model
        self.keep_alive = keep_alive
        self.warmup_timeout_seconds = warmup_timeout_seconds
        self.opener = opener
        self._loaded = False
        self._error: str | None = None
        self._lock = threading.Lock()

    def warmup(self) -> bool:
        request = urllib.request.Request(
            self.warmup_url,
            data=json.dumps({"model": self.model, "keep_alive": self.keep_alive}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with self.opener(request, timeout=self.warmup_timeout_seconds) as response:
                response.read()
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError, ValueError) as exc:
            self.mark_unloaded(str(exc) or type(exc).__name__)
            return False
        self.mark_loaded()
        return True

    def is_loaded(self) -> bool:
        with self._lock:
            return self._loaded

    def mark_loaded(self) -> None:
        with self._lock:
            self._loaded = True
            self._error = None

    def mark_unloaded(self, error: str | None = None) -> None:
        with self._lock:
            self._loaded = False
            self._error = error

    @property
    def last_error(self) -> str | None:
        with self._lock:
            return self._error
