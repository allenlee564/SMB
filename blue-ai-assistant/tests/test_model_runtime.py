from __future__ import annotations

import io
import json
import unittest
import urllib.error

from core.assistant import OllamaClient
from core.model_runtime import ModelRuntime


class FakeResponse:
    def __init__(self, payload: dict | None = None, lines: list[dict] | None = None) -> None:
        if lines is not None:
            content = b"".join(json.dumps(item).encode("utf-8") + b"\n" for item in lines)
        else:
            content = json.dumps(payload or {}).encode("utf-8")
        self.body = io.BytesIO(content)

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body.read()

    def __iter__(self):
        return iter(self.body)

    def close(self) -> None:
        self.body.close()


class ModelRuntimeTests(unittest.TestCase):
    def test_warmup_success_uses_generate_and_infinite_keep_alive(self) -> None:
        captured: dict = {}

        def opener(request, timeout: float) -> FakeResponse:
            captured["url"] = request.full_url
            captured["payload"] = json.loads(request.data)
            captured["timeout"] = timeout
            return FakeResponse()

        runtime = ModelRuntime(
            "http://127.0.0.1:11434/api/chat", "qwen2.5:3b", -1, 120, opener
        )
        self.assertTrue(runtime.warmup())
        self.assertTrue(runtime.is_loaded())
        self.assertEqual(captured["url"], "http://127.0.0.1:11434/api/generate")
        self.assertEqual(captured["payload"], {"model": "qwen2.5:3b", "keep_alive": -1})
        self.assertEqual(captured["timeout"], 120)

    def test_unreachable_does_not_crash_and_remains_unloaded(self) -> None:
        def opener(request, timeout: float):
            raise urllib.error.URLError("offline")

        runtime = ModelRuntime("http://localhost:11434/api/chat", "qwen2.5:3b", opener=opener)
        self.assertFalse(runtime.warmup())
        self.assertFalse(runtime.is_loaded())
        self.assertIn("offline", runtime.last_error or "")

    def test_timeout_remains_unloaded(self) -> None:
        def opener(request, timeout: float):
            raise TimeoutError("warmup timeout")

        runtime = ModelRuntime("http://localhost:11434/api/chat", "qwen2.5:3b", opener=opener)
        self.assertFalse(runtime.warmup())
        self.assertFalse(runtime.is_loaded())

    def test_model_missing_remains_unloaded(self) -> None:
        def opener(request, timeout: float):
            raise urllib.error.HTTPError(request.full_url, 404, "model not found", {}, None)

        runtime = ModelRuntime("http://localhost:11434/api/chat", "missing:latest", opener=opener)
        self.assertFalse(runtime.warmup())
        self.assertFalse(runtime.is_loaded())

    def test_chat_uses_configured_infinite_keep_alive(self) -> None:
        captured: dict = {}

        def opener(request, timeout: float) -> FakeResponse:
            captured.update(json.loads(request.data))
            return FakeResponse({"message": {"content": "ok"}})

        # Patch the module-level transport used by OllamaClient without making a real request.
        import core.assistant as assistant_module
        original = assistant_module.urllib.request.urlopen
        assistant_module.urllib.request.urlopen = opener
        try:
            client = OllamaClient("http://localhost:11434/api/chat", "qwen2.5:3b", keep_alive=-1)
            self.assertEqual(client.ask("system", "hello"), "ok")
        finally:
            assistant_module.urllib.request.urlopen = original
        self.assertEqual(captured["keep_alive"], -1)
        self.assertEqual(captured["model"], "qwen2.5:3b")
        self.assertEqual(captured["messages"][1]["content"], "hello")

    def test_stream_uses_fixed_model_and_parses_ollama_chunks(self) -> None:
        captured: dict = {}

        def opener(request, timeout: float) -> FakeResponse:
            captured.update(json.loads(request.data))
            return FakeResponse(
                lines=[
                    {"message": {"content": "one"}, "done": False},
                    {"message": {"content": "two"}, "done": False},
                    {"message": {"content": ""}, "done": True},
                ]
            )

        import core.assistant as assistant_module
        original = assistant_module.urllib.request.urlopen
        assistant_module.urllib.request.urlopen = opener
        try:
            client = OllamaClient(
                "http://localhost:11434/api/chat", "qwen2.5:3b", keep_alive=-1
            )
            self.assertEqual(list(client.stream("base", "scenario")), ["one", "two"])
        finally:
            assistant_module.urllib.request.urlopen = original
        self.assertTrue(captured["stream"])
        self.assertEqual(captured["model"], "qwen2.5:3b")
        self.assertEqual(captured["keep_alive"], -1)


if __name__ == "__main__":
    unittest.main()
