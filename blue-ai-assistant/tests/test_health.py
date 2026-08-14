from __future__ import annotations

import io
import json
import unittest

from core.health import build_health_report


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self.body = io.BytesIO(json.dumps(payload).encode("utf-8"))

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body.read()


class HealthTests(unittest.TestCase):
    def test_reachable_with_model_is_ok(self) -> None:
        def opener(url: str, timeout: float) -> FakeResponse:
            self.assertEqual(url, "http://127.0.0.1:11434/api/tags")
            self.assertEqual(timeout, 2)
            return FakeResponse({"models": [{"name": "qwen2.5:3b"}]})

        report = build_health_report(
            "http://127.0.0.1:11434/api/chat", "qwen2.5:3b", True, 2, opener,
            loaded=True,
        )
        self.assertEqual(report["status"], "ok")
        self.assertTrue(report["ollama"]["reachable"])
        self.assertTrue(report["model"]["installed"])
        self.assertTrue(report["model"]["loaded"])

    def test_release_version_is_reported_when_supplied(self) -> None:
        def opener(url: str, timeout: float) -> FakeResponse:
            return FakeResponse({"models": [{"name": "qwen2.5:3b"}]})

        report = build_health_report(
            "http://127.0.0.1:11434/api/chat", "qwen2.5:3b", True, 2, opener,
            loaded=True, version="0.3.0",
        )
        self.assertEqual(report["version"], "0.3.0")

    def test_installed_but_not_loaded_is_degraded(self) -> None:
        def opener(url: str, timeout: float) -> FakeResponse:
            return FakeResponse({"models": [{"name": "qwen2.5:3b"}]})

        report = build_health_report(
            "http://127.0.0.1:11434/api/chat", "qwen2.5:3b", True, 2, opener
        )
        self.assertEqual(report["status"], "degraded")
        self.assertTrue(report["model"]["installed"])
        self.assertFalse(report["model"]["loaded"])

    def test_unreachable_has_unknown_model_state(self) -> None:
        def opener(url: str, timeout: float) -> FakeResponse:
            raise TimeoutError

        report = build_health_report(
            "http://127.0.0.1:11434/api/chat", "qwen2.5:3b", True, 2, opener
        )
        self.assertEqual(report["status"], "degraded")
        self.assertFalse(report["ollama"]["reachable"])
        self.assertIsNone(report["model"]["installed"])

    def test_reachable_without_model_is_degraded(self) -> None:
        def opener(url: str, timeout: float) -> FakeResponse:
            return FakeResponse({"models": [{"name": "another-model:latest"}]})

        report = build_health_report(
            "http://127.0.0.1:11434/api/chat", "qwen2.5:3b", True, 2, opener
        )
        self.assertEqual(report["status"], "degraded")
        self.assertTrue(report["ollama"]["reachable"])
        self.assertFalse(report["model"]["installed"])


if __name__ == "__main__":
    unittest.main()
