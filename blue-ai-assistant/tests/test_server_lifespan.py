from __future__ import annotations

import asyncio
import unittest
from unittest.mock import patch

from api import server


class LifespanTests(unittest.TestCase):
    def test_startup_calls_warmup_once(self) -> None:
        calls = 0

        def warmup() -> bool:
            nonlocal calls
            calls += 1
            server.model_runtime.mark_loaded()
            return True

        async def exercise() -> None:
            with patch.object(server.model_runtime, "warmup", side_effect=warmup):
                async with server.lifespan(server.app):
                    self.assertTrue(server.model_runtime.is_loaded())

        asyncio.run(exercise())
        self.assertEqual(calls, 1)

    def test_startup_failure_keeps_service_available_but_degraded(self) -> None:
        async def exercise() -> None:
            server.model_runtime.mark_unloaded("offline")
            with patch.object(server.model_runtime, "warmup", return_value=False):
                async with server.lifespan(server.app):
                    self.assertFalse(server.model_runtime.is_loaded())

        asyncio.run(exercise())


if __name__ == "__main__":
    unittest.main()
