from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timezone
from typing import Any

from neo4j import AsyncDriver, AsyncGraphDatabase
from neo4j.exceptions import ServiceUnavailable

log = logging.getLogger("sahayak.neo4j")

_CONSTRAINTS = [
    "CREATE CONSTRAINT device_id_unique IF NOT EXISTS FOR (d:Device) REQUIRE d.id IS UNIQUE",
    "CREATE CONSTRAINT query_id_unique IF NOT EXISTS FOR (q:Query) REQUIRE q.id IS UNIQUE",
    "CREATE CONSTRAINT image_url_unique IF NOT EXISTS FOR (i:Image) REQUIRE i.url IS UNIQUE",
    "CREATE CONSTRAINT session_id_unique IF NOT EXISTS FOR (s:Session) REQUIRE s.id IS UNIQUE",
    "CREATE CONSTRAINT keyword_name_unique IF NOT EXISTS FOR (k:Keyword) REQUIRE k.name IS UNIQUE",
]

_INDEXES = [
    "CREATE INDEX device_query_lookup IF NOT EXISTS FOR (q:Query) ON (q.device_id, q.created_at)",
]


class Neo4jService:
    """Production-ready async Neo4j graph layer for Sahayak.

    All writes are idempotent (MERGE-based).  Every query-scoped operation is
    tenant-isolated by ``device_id``.  :Object nodes are intentionally global
    (they represent real-world things like "rice" or "tractor").
    """

    def __init__(self, driver: AsyncDriver | None = None) -> None:
        """Initialise the service.

        Args:
            driver: Pre-configured :class:`AsyncDriver` for testing.
                    When *None* a driver is created from ``NEO4J_*`` env vars.
        """
        if driver is not None:
            self._driver = driver
        else:
            uri = os.getenv("NEO4J_URI", "bolt://localhost:7687")
            user = os.getenv("NEO4J_USER", "neo4j")
            password = os.getenv("NEO4J_PASSWORD", "")
            self._driver = AsyncGraphDatabase.driver(
                uri,
                auth=(user, password),
                max_connection_pool_size=50,
                connection_acquisition_timeout=5,
                max_transaction_retry_time=5,
            )

    async def close(self) -> None:
        """Shut down the driver and release all pooled connections."""
        await self._driver.close()
        log.info("Driver closed")

    async def verify_connectivity(self) -> None:
        """Verify that the Neo4j server is reachable.

        Raises:
            ServiceUnavailable: If the server cannot be reached.
        """
        await self._driver.verify_connectivity()
        log.info("Connectivity verified")

    async def ensure_indexes(self) -> None:
        """Create uniqueness constraints and composite indexes idempotently."""
        async with self._driver.session() as session:
            try:
                await session.run("DROP CONSTRAINT query_unique IF EXISTS")
            except Exception as e:
                log.debug(f"Could not drop old query_unique constraint: {e}")
                
            for stmt in _CONSTRAINTS + _INDEXES:
                result = await session.run(stmt)
                await result.consume()
        log.info("Schema constraints and indexes ensured")

    # ── Internal helpers ──────────────────────────────────────────────────────

    async def _exec_write(self, work_fn: Any) -> Any:
        """Run a managed write transaction with one *ServiceUnavailable* retry."""
        try:
            async with self._driver.session() as session:
                return await session.execute_write(work_fn)
        except ServiceUnavailable:
            log.warning("Service unavailable — retrying write in 2 s")
            await asyncio.sleep(2)
            async with self._driver.session() as session:
                return await session.execute_write(work_fn)

    async def _exec_read(self, work_fn: Any) -> Any:
        """Run a managed read transaction with one *ServiceUnavailable* retry."""
        try:
            async with self._driver.session() as session:
                return await session.execute_read(work_fn)
        except ServiceUnavailable:
            log.warning("Service unavailable — retrying read in 2 s")
            await asyncio.sleep(2)
            async with self._driver.session() as session:
                return await session.execute_read(work_fn)

    # ── Individual write operations ───────────────────────────────────────────

    async def upsert_device(self, device_id: str, timestamp: str) -> None:
        """Create or touch a :Device node, tracking first/last seen times."""

        async def _work(tx: Any) -> None:
            await tx.run(
                """
                MERGE (d:Device {id: $device_id})
                  ON CREATE SET d.first_seen = $ts
                  ON MATCH  SET d.last_seen  = $ts
                """,
                device_id=device_id,
                ts=timestamp,
            )

        await self._exec_write(_work)
        log.info("upsert_device: device=%s", device_id)

    async def upsert_query(self, query_id: str, device_id: str, query_text: str, response_text: str, timestamp: str) -> None:
        """Create a :Query node using its strict UUID and link it to its :Device via :ASKED."""

        async def _work(tx: Any) -> None:
            await tx.run(
                """
                MERGE (d:Device {id: $device_id})
                MERGE (q:Query {id: $query_id})
                  ON CREATE SET q.text = $query_text,
                                q.answer = $response_text,
                                q.device_id = $device_id,
                                q.created_at = $ts
                MERGE (d)-[r:ASKED]->(q)
                  ON CREATE SET r.timestamp = $ts
                """,
                query_id=query_id,
                device_id=device_id,
                query_text=query_text,
                response_text=response_text,
                ts=timestamp,
            )

        await self._exec_write(_work)
        log.info("upsert_query: device=%s, query_id=%s", device_id, query_id)

    async def upsert_image(self, image_url: str, query_id: str, device_id: str) -> None:
        """Create an :Image node and link it to its :Query via :HAS_IMAGE."""

        async def _work(tx: Any) -> None:
            await tx.run(
                """
                MATCH (q:Query {id: $query_id})
                MERGE (i:Image {url: $image_url})
                  ON CREATE SET i.created_at = datetime()
                MERGE (q)-[:HAS_IMAGE]->(i)
                """,
                query_id=query_id,
                image_url=image_url,
            )

        await self._exec_write(_work)
        log.info("upsert_image: url=%s", image_url)

    async def upsert_session(
        self,
        device_id: str,
        session_id: str,
        query_id: str,
        turn: int,
        timestamp: str,
    ) -> None:
        """Create a :Session node bound to its :Device and link the :Query using query_id."""

        async def _work(tx: Any) -> None:
            await tx.run(
                """
                MERGE (d:Device {id: $device_id})
                MERGE (s:Session {id: $session_id})
                  ON CREATE SET s.device_id  = $device_id,
                               s.created_at = $ts,
                               s.updated_at = $ts
                  ON MATCH  SET s.updated_at = $ts
                MERGE (d)-[:HAS_SESSION]->(s)
                MATCH (q:Query {id: $query_id})
                MERGE (s)-[r:CONTAINS]->(q)
                  ON CREATE SET r.turn = $turn, r.timestamp = $ts
                """,
                device_id=device_id,
                session_id=session_id,
                query_id=query_id,
                turn=turn,
                ts=timestamp,
            )

        await self._exec_write(_work)
        log.info("upsert_session: session=%s turn=%d linked to query", session_id, turn)

    async def link_followup(self, device_id: str, prev_query_text: str, current_query_id: str) -> None:
        """Chain two :Query nodes with a :FOLLOWED_BY relationship."""

        async def _work(tx: Any) -> None:
            await tx.run(
                """
                MATCH (prev:Query {text: $prev_text, device_id: $device_id})
                MATCH (curr:Query {id: $curr_id})
                MERGE (prev)-[:FOLLOWED_BY]->(curr)
                """,
                device_id=device_id,
                prev_text=prev_query_text,
                curr_id=current_query_id,
            )

        await self._exec_write(_work)
        log.info("link_followup: -> %s", current_query_id)

    async def upsert_keywords(self, query_id: str, keywords: list[str]) -> None:
        """Create global :Keyword nodes and link each directly to the query."""

        async def _work(tx: Any) -> None:
            await tx.run(
                """
                UNWIND $keywords AS kw_name
                MATCH (q:Query {id: $query_id})
                MERGE (k:Keyword {name: toLower(kw_name)})
                MERGE (q)-[:HAS_KEYWORD]->(k)
                """,
                query_id=query_id,
                keywords=keywords,
            )

        await self._exec_write(_work)
        log.info("upsert_keywords: %d keyword(s)", len(keywords))

    # ── Coordinator ───────────────────────────────────────────────────────────

    async def record_interaction(
        self,
        *,
        device_id: str,
        query_id: str,
        query_text: str,
        response_text: str,
        image_url: str,
        keywords: list[str],
        session_id: str | None = None,
        prev_query_text: str | None = None,
        turn: int = 0,
        timestamp: str | None = None,
    ) -> dict[str, Any]:
        """Run the full graph write for one user interaction (extracted keywords attached to query).

        Each sub-operation is attempted independently so a single failure
        does not block the rest.
        """
        ts = timestamp or _utcnow()
        failures: list[str] = []

        ops: list[tuple[str, Any]] = [
            ("device", self.upsert_device(device_id, ts)),
            ("query", self.upsert_query(query_id, device_id, query_text, response_text, ts)),
            ("image", self.upsert_image(image_url, query_id, device_id)),
        ]
        if session_id:
            ops.append(("session", self.upsert_session(
                device_id, session_id, query_id, turn, ts,
            )))
        if prev_query_text:
            ops.append(("followup", self.link_followup(
                device_id, prev_query_text, query_id,
            )))
        if keywords:
            ops.append(("keywords", self.upsert_keywords(query_id, keywords)))

        for name, coro in ops:
            try:
                await coro
            except Exception as exc:
                failures.append(name)
                log.error(
                    "record_interaction sub-op '%s' failed for device=%s: %s",
                    name, device_id, exc, exc_info=True,
                )

        if not failures:
            log.info("record_interaction: device=%s — all ops succeeded", device_id)
            return {"status": "ok", "failures": []}

        if len(failures) == len(ops):
            msg = f"All {len(ops)} sub-operations failed"
            log.error("record_interaction: device=%s — %s", device_id, msg)
            return {"status": "failed", "error": msg, "failures": failures}

        log.warning("record_interaction: device=%s — partial: %s", device_id, failures)
        return {"status": "partial", "failures": failures}

    # ── Read methods ──────────────────────────────────────────────────────────

    async def get_device_history(self, device_id: str, limit: int = 20) -> list[dict[str, Any]]:
        """Return the last *limit* queries for a device, newest first.

        Each dict: ``query_text``, ``image_url``, ``objects``,
        ``session_id``, ``timestamp``.
        """

        async def _work(tx: Any) -> list[dict[str, Any]]:
            result = await tx.run(
                """
                MATCH (d:Device {id: $device_id})-[:ASKED]->(q:Query)
                OPTIONAL MATCH (q)-[:HAS_IMAGE]->(i:Image)
                OPTIONAL MATCH (q)-[:HAS_KEYWORD]->(k:Keyword)
                OPTIONAL MATCH (s:Session)-[:CONTAINS]->(q)
                WITH q, i, s, collect(DISTINCT k.name) AS keywords
                RETURN q.text       AS query_text,
                       q.answer     AS response_text,
                       i.url        AS image_url,
                       keywords,
                       s.id         AS session_id,
                       q.created_at AS timestamp
                ORDER BY q.created_at DESC
                LIMIT $limit
                """,
                device_id=device_id,
                limit=limit,
            )
            return [record.data() async for record in result]

        return await self._exec_read(_work)

    async def get_session_thread(self, session_id: str, device_id: str) -> list[dict[str, Any]]:
        """Return all queries in a session ordered by turn number.

        Each dict: ``query_text``, ``turn``, ``image_url``,
        ``objects``, ``timestamp``.
        """

        async def _work(tx: Any) -> list[dict[str, Any]]:
            result = await tx.run(
                """
                MATCH (d:Device {id: $device_id})-[:HAS_SESSION]->(s:Session {id: $session_id})
                MATCH (s)-[c:CONTAINS]->(q:Query {device_id: $device_id})
                OPTIONAL MATCH (q)-[:HAS_IMAGE]->(i:Image)
                OPTIONAL MATCH (q)-[:HAS_KEYWORD]->(k:Keyword)
                WITH q, c, i, collect(DISTINCT k.name) AS keywords
                RETURN q.text      AS query_text,
                       q.answer    AS response_text,
                       c.turn      AS turn,
                       i.url       AS image_url,
                       keywords,
                       c.timestamp AS timestamp
                ORDER BY c.turn
                """,
                session_id=session_id,
                device_id=device_id,
            )
            return [record.data() async for record in result]

        return await self._exec_read(_work)

    # ── Graph RAG ─────────────────────────────────────────────────────────────

    async def _get_device_top_keywords(
        self, device_id: str, limit: int = 6
    ) -> list[dict[str, Any]]:
        """Return the most-used keywords for a device, ranked by frequency."""

        async def _work(tx: Any) -> list[dict[str, Any]]:
            result = await tx.run(
                """
                MATCH (d:Device {id: $device_id})-[:ASKED]->(q:Query)
                      -[:HAS_KEYWORD]->(k:Keyword)
                RETURN k.name AS keyword, count(*) AS frequency
                ORDER BY frequency DESC
                LIMIT $limit
                """,
                device_id=device_id,
                limit=limit,
            )
            return [r.data() async for r in result]

        return await self._exec_read(_work)

    async def _get_past_answers_for_objects(
        self, device_id: str, objects: list[str], limit: int = 3
    ) -> list[dict[str, Any]]:
        """Return past Q&A pairs for this device that share a keyword with current objects."""
        normalized = [o.lower() for o in objects]

        async def _work(tx: Any) -> list[dict[str, Any]]:
            result = await tx.run(
                """
                MATCH (d:Device {id: $device_id})-[:ASKED]->(q:Query)
                      -[:HAS_KEYWORD]->(k:Keyword)
                WHERE toLower(k.name) IN $objects
                  AND q.answer IS NOT NULL
                RETURN DISTINCT q.text   AS query_text,
                                q.answer AS answer,
                                k.name   AS keyword
                ORDER BY q.created_at DESC
                LIMIT $limit
                """,
                device_id=device_id,
                objects=normalized,
                limit=limit,
            )
            return [r.data() async for r in result]

        return await self._exec_read(_work)

    async def get_rag_context(
        self,
        device_id: str,
        session_id: str | None,
        current_objects: list[str],
    ) -> str:
        """Build a Graph RAG context string by traversing three graph paths.

        Path 1 — Session thread:
            What has been said earlier in the current conversation.
            Helps Gemini avoid re-explaining things already established.

        Path 2 — Device top keywords:
            Objects this user most frequently asks about.
            Gives Gemini awareness of the user's typical environment.

        Path 3 — Past answers for similar objects:
            What the AI told this user the last time it saw the same objects.
            Helps produce consistent, familiar guidance.

        Returns a formatted string ready to prepend to the Gemini explain prompt,
        or "" if no useful context exists (e.g. brand-new device, first query).
        """
        parts: list[str] = []

        # ── Path 1: session thread ────────────────────────────────────────────
        if session_id:
            try:
                thread = await self.get_session_thread(session_id, device_id)
                if thread:
                    lines = []
                    for row in thread:
                        q = (row.get("query_text") or "").strip()
                        a = (row.get("response_text") or "").strip()
                        t = row.get("turn", "?")
                        if q:
                            lines.append(f'  Turn {t}: asked "{q}"')
                        if a:
                            lines.append(f'           answered "{a}"')
                    if lines:
                        parts.append("Conversation so far:\n" + "\n".join(lines))
            except Exception as exc:
                log.debug("[RAG] session thread fetch failed: %s", exc)

        # ── Path 2: device's most common keywords ─────────────────────────────
        try:
            kw_rows = await self._get_device_top_keywords(device_id, limit=6)
            if kw_rows:
                items = [
                    f"{r['keyword']} ({r['frequency']}×)" for r in kw_rows
                ]
                parts.append(
                    "Objects this user commonly asks about: " + ", ".join(items)
                )
        except Exception as exc:
            log.debug("[RAG] top keywords fetch failed: %s", exc)

        # ── Path 3: past answers for same object types ────────────────────────
        if current_objects:
            try:
                past = await self._get_past_answers_for_objects(
                    device_id, current_objects, limit=3
                )
                if past:
                    lines = []
                    for row in past:
                        q = (row.get("query_text") or "").strip()
                        a = (row.get("answer") or "").strip()
                        if q and a:
                            lines.append(f'  • "{q}" → "{a}"')
                    if lines:
                        parts.append(
                            "Previous answers about similar objects:\n"
                            + "\n".join(lines)
                        )
            except Exception as exc:
                log.debug("[RAG] past answers fetch failed: %s", exc)

        if not parts:
            return ""

        return (
            "=== GRAPH CONTEXT (retrieved from this user's history) ===\n"
            + "\n\n".join(parts)
            + "\n=== END CONTEXT ==="
        )

    async def get_related_queries(self, keyword_name: str, limit: int = 10) -> list[dict[str, Any]]:
        """Find queries and images cross-device related to a given semantic keyword."""

        async def _work(tx: Any) -> list[dict[str, Any]]:
            result = await tx.run(
                """
                MATCH (k:Keyword {name: $keyword_name})<-[:HAS_KEYWORD]-(q:Query)
                OPTIONAL MATCH (q)-[:HAS_IMAGE]->(i:Image)
                RETURN q.text      AS query_text,
                       q.answer    AS response_text,
                       i.url       AS image_url,
                       q.device_id AS device_id
                LIMIT $limit
                """,
                keyword_name=keyword_name,
                limit=limit,
            )
            return [record.data() async for record in result]

        return await self._exec_read(_work)


def _utcnow() -> str:
    """ISO 8601 UTC timestamp."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
