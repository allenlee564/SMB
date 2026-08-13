from __future__ import annotations

import json
import urllib.error
import urllib.request
from collections.abc import Iterator
from typing import Protocol


class AssistantUnavailable(RuntimeError):
    pass


class AssistantClient(Protocol):
    def ask(self, system_prompt: str, prompt: str) -> str: ...

    def stream(self, system_prompt: str, prompt: str) -> Iterator[str]: ...


class OllamaClient:
    """Minimal fixed-model transport for the local Ollama chat API."""

    def __init__(
        self,
        url: str,
        model: str,
        timeout: float = 180,
        keep_alive: int | str = -1,
    ) -> None:
        self.url = url
        self.model = model
        self.timeout = timeout
        self.keep_alive = keep_alive

    def _payload(self, system_prompt: str, prompt: str, *, stream: bool) -> bytes:
        return json.dumps(
            {
                "model": self.model,
                "stream": stream,
                "keep_alive": self.keep_alive,
                "options": {"temperature": 0, "num_ctx": 4096},
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": prompt},
                ],
            },
            ensure_ascii=False,
        ).encode("utf-8")

    def _request(self, system_prompt: str, prompt: str, *, stream: bool):
        request = urllib.request.Request(
            self.url,
            data=self._payload(system_prompt, prompt, stream=stream),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            return urllib.request.urlopen(request, timeout=self.timeout)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise AssistantUnavailable(
                "無法連線至本機 Ollama，請確認服務已啟動且模型已安裝。"
            ) from exc

    def ask(self, system_prompt: str, prompt: str) -> str:
        response = self._request(system_prompt, prompt, stream=False)
        try:
            with response:
                result = json.load(response)
            return str(result["message"]["content"]).strip()
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise AssistantUnavailable("Ollama 回傳格式不正確。") from exc

    def stream(self, system_prompt: str, prompt: str) -> Iterator[str]:
        # Open before returning the iterator so connection failures can still be
        # represented by HTTP 503 instead of a partially-started HTTP 200 stream.
        response = self._request(system_prompt, prompt, stream=True)

        def chunks() -> Iterator[str]:
            try:
                with response:
                    for raw_line in response:
                        if not raw_line.strip():
                            continue
                        try:
                            item = json.loads(raw_line.decode("utf-8"))
                            if item.get("error"):
                                raise AssistantUnavailable("Ollama generation failed.")
                            content = item.get("message", {}).get("content", "")
                        except (UnicodeDecodeError, AttributeError, TypeError, ValueError) as exc:
                            raise AssistantUnavailable("Ollama 回傳格式不正確。") from exc
                        if content:
                            yield str(content)
            finally:
                close = getattr(response, "close", None)
                if callable(close):
                    close()

        return chunks()
