from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol


class AuditSink(Protocol):
    def record(self, event_type: str, reason_code: str) -> None: ...


class JsonLineAuditSink:
    """Record fixed AI event metadata without prompts or response text."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()

    def record(self, event_type: str, reason_code: str) -> None:
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event_type": event_type[:80],
            "reason_code": reason_code[:80],
        }
        encoded = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(encoded + "\n")


class MemoryAuditSink:
    def __init__(self) -> None:
        self.events: list[dict[str, str]] = []

    def record(self, event_type: str, reason_code: str) -> None:
        self.events.append({"event_type": event_type, "reason_code": reason_code})
