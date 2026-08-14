from __future__ import annotations

from collections.abc import Iterator

from core.assistant import AssistantClient
from core.prompt_builder import build_advisory_prompt


class AssistantService:
    """Standalone advisory inference service with no exercise-state knowledge."""

    def __init__(self, client: AssistantClient) -> None:
        self.client = client

    def generate(self, prompt: str) -> str:
        system_prompt, user_prompt = build_advisory_prompt(prompt)
        return self.client.ask(system_prompt, user_prompt)

    def stream(self, prompt: str) -> Iterator[str]:
        system_prompt, user_prompt = build_advisory_prompt(prompt)
        return self.client.stream(system_prompt, user_prompt)
