from __future__ import annotations

import threading
import time
from collections import defaultdict, deque


class ClientRateLimiter:
    def __init__(self, requests_per_minute: int) -> None:
        if requests_per_minute < 1:
            raise ValueError("requests_per_minute must be positive")
        self.limit = requests_per_minute
        self._events: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, client_key: str, now: float | None = None) -> bool:
        timestamp = time.monotonic() if now is None else now
        with self._lock:
            events = self._events[client_key]
            while events and events[0] <= timestamp - 60:
                events.popleft()
            if len(events) >= self.limit:
                return False
            events.append(timestamp)
            return True


class GlobalConcurrencyLimiter:
    def __init__(self, max_active: int = 1) -> None:
        if max_active < 1:
            raise ValueError("max_active must be positive")
        self.limit = max_active
        self._active = 0
        self._lock = threading.Lock()

    def acquire(self) -> bool:
        with self._lock:
            if self._active >= self.limit:
                return False
            self._active += 1
            return True

    def release(self) -> None:
        with self._lock:
            if self._active <= 0:
                raise RuntimeError("concurrency limiter released without acquisition")
            self._active -= 1
