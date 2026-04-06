"""
In-memory session store for multi-turn conversations.

Each session keeps the original image bytes and the conversation history
so that /clarify can resume where /annotate left off.

Sessions expire after TTL_SECONDS of inactivity.
"""
from __future__ import annotations

import time
import uuid
from typing import Optional

TTL_SECONDS = 600  # 10 minutes


class SessionService:

    def __init__(self) -> None:
        self._store: dict[str, dict] = {}

    # ── CRUD ──────────────────────────────────────────────────────────────────

    def create(
        self,
        device_id: str,
        image_bytes: bytes,
        query: str,
        language: str = "en-IN",
        conversation_id: str | None = None,
    ) -> str:
        """Create a new session, return session_id."""
        session_id = str(uuid.uuid4())
        self._store[session_id] = {
            "device_id": device_id,
            "conversation_id": conversation_id,
            "image_bytes": image_bytes,
            "language": language,
            "history": [{"role": "user", "content": query}],
            "created_at": time.time(),
            "touched_at": time.time(),
        }
        return session_id

    def get(self, session_id: str) -> Optional[dict]:
        """Return session dict or None if missing/expired."""
        s = self._store.get(session_id)
        if s is None:
            return None
        if time.time() - s["touched_at"] > TTL_SECONDS:
            del self._store[session_id]
            return None
        s["touched_at"] = time.time()
        return s

    def append(self, session_id: str, role: str, content: str) -> None:
        s = self._store.get(session_id)
        if s:
            s["history"].append({"role": role, "content": content})
            s["touched_at"] = time.time()

    def delete(self, session_id: str) -> None:
        self._store.pop(session_id, None)

    def purge_expired(self) -> None:
        now = time.time()
        expired = [k for k, v in self._store.items()
                   if now - v["touched_at"] > TTL_SECONDS]
        for k in expired:
            del self._store[k]
