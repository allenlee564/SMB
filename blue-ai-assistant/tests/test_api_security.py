from __future__ import annotations

import json
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from api import server
from core.assistant import AssistantUnavailable
from core.request_limits import ClientRateLimiter, GlobalConcurrencyLimiter


class RecordingService:
    def __init__(self) -> None:
        self.prompts: list[str] = []
        self.fail = False

    def generate(self, prompt: str) -> str:
        self.prompts.append(prompt)
        if self.fail:
            raise AssistantUnavailable("internal transport detail")
        return "advisory answer"

    def stream(self, prompt: str):
        self.prompts.append(prompt)
        if self.fail:
            raise AssistantUnavailable("internal transport detail")
        return iter(["第一段", "第二段"])


class GenerateCompatibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.service = RecordingService()
        self.original_rate = server.rate_limiter
        self.original_concurrency = server.concurrency_limiter
        self.original_origins = server.origins
        server.rate_limiter = ClientRateLimiter(20)
        server.concurrency_limiter = GlobalConcurrencyLimiter(1)
        server.origins = []
        server.model_runtime.mark_loaded()
        self.service_patch = patch.object(server, "get_service", return_value=self.service)
        self.service_patch.start()
        self.client = TestClient(server.app)

    def tearDown(self) -> None:
        self.service_patch.stop()
        server.rate_limiter = self.original_rate
        server.concurrency_limiter = self.original_concurrency
        server.origins = self.original_origins

    def post(self, body: dict, **kwargs):
        return self.client.post("/api/generate", json=body, **kwargs)

    def test_non_stream_request_returns_minimal_json(self) -> None:
        prompt = "System: 你是一個資安助手。\nUser: chmod 600 是什麼？"
        response = self.post(
            {"model": "qwen2.5:3b", "prompt": prompt, "stream": False}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(), {"response": "advisory answer", "done": True}
        )
        self.assertEqual(self.service.prompts, [prompt])

    def test_stream_request_is_red_template_compatible_ndjson(self) -> None:
        response = self.post(
            {
                "model": "qwen2.5:3b",
                "prompt": "System: helper\nUser: explain chmod",
                "stream": True,
            }
        )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.headers["content-type"].startswith("application/x-ndjson"))
        rows = [json.loads(line) for line in response.text.splitlines()]
        self.assertEqual(rows[:-1], [{"response": "第一段"}, {"response": "第二段"}])
        self.assertEqual(rows[-1], {"done": True})

    def test_model_field_cannot_select_runtime_model(self) -> None:
        response = self.post(
            {"model": "attacker-selected:latest", "prompt": "hello", "stream": False}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.service.prompts, ["hello"])

    def test_missing_prompt_and_extra_checker_state_are_rejected(self) -> None:
        missing = self.post({"model": "qwen2.5:3b", "stream": False})
        self.assertEqual(missing.status_code, 422)
        for field, value in {
            "checker_status": "PASS",
            "checker_result": {},
            "checker_evidence": "detail",
            "repair_status": "FIXED",
            "completed": True,
            "score": 100,
            "current_score": 100,
            "passed_challenges": ["Q01"],
            "failed_challenges": [],
            "remaining_challenges": [],
            "hidden_unlocked": True,
        }.items():
            with self.subTest(field=field):
                response = self.post(
                    {
                        "model": "qwen2.5:3b",
                        "prompt": "hello",
                        "stream": False,
                        field: value,
                    }
                )
                self.assertEqual(response.status_code, 422)

    def test_oversized_prompt_is_413(self) -> None:
        with patch.dict(server.settings, {"max_prompt_chars": 8}):
            response = self.post(
                {"model": "qwen2.5:3b", "prompt": "123456789", "stream": False}
            )
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.service.prompts, [])

    def test_model_not_ready_is_503(self) -> None:
        server.model_runtime.mark_unloaded("offline")
        response = self.post(
            {"model": "qwen2.5:3b", "prompt": "hello", "stream": False}
        )
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("offline", response.text)

    def test_ollama_unavailable_is_503_for_both_modes(self) -> None:
        self.service.fail = True
        for stream in (False, True):
            with self.subTest(stream=stream):
                response = self.post(
                    {"model": "qwen2.5:3b", "prompt": "hello", "stream": stream}
                )
                self.assertEqual(response.status_code, 503)
                self.assertNotIn("internal transport detail", response.text)

    def test_rate_and_global_concurrency_limits_are_standalone(self) -> None:
        server.rate_limiter = ClientRateLimiter(1)
        body = {"model": "qwen2.5:3b", "prompt": "hello", "stream": False}
        self.assertEqual(self.post(body).status_code, 200)
        self.assertEqual(self.post(body).status_code, 429)

        server.rate_limiter = ClientRateLimiter(20)
        self.assertTrue(server.concurrency_limiter.acquire())
        try:
            self.assertEqual(self.post(body).status_code, 429)
        finally:
            server.concurrency_limiter.release()

    def test_unconfigured_cross_origin_is_rejected(self) -> None:
        response = self.post(
            {"model": "qwen2.5:3b", "prompt": "hello", "stream": False},
            headers={"Origin": "http://127.0.0.1:3000"},
        )
        self.assertEqual(response.status_code, 403)

    def test_native_chat_uses_the_same_service(self) -> None:
        response = self.client.post("/api/assistant/chat", json={"message": "hello"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"reply": "advisory answer", "done": True})
        self.assertEqual(self.service.prompts, ["hello"])

    def test_health_contains_only_ai_readiness_fields(self) -> None:
        with patch.object(server.health_service, "build_health_report") as build:
            build.return_value = {
                "status": "ok",
                "service": "blue-ai-assistant",
                "version": "0.3.0",
                "ollama": {"reachable": True},
                "model": {
                    "name": "qwen2.5:3b",
                    "installed": True,
                    "loaded": True,
                },
                "localhost_only": True,
            }
            response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertNotIn("security", payload)
        self.assertNotIn("portal", repr(payload).lower())
        self.assertNotIn("score", repr(payload).lower())


if __name__ == "__main__":
    unittest.main()
