"""TraceStore — async SQLite trace storage with WAL mode."""
from __future__ import annotations

import json
from pathlib import Path

import aiosqlite


class TraceStore:
    """Async SQLite-backed trace storage.

    Usage:
        store = TraceStore(db_path="/path/to/traces.db")
        await store.init_db()           # once at startup
        await store.write(record)       # per request (background task)
        row = await store.query_by_id("req-xxx")
        rows = await store.query_by_timerange("2025-01-01T00:00:00", "2025-12-31T23:59:59")
    """

    def __init__(self, db_path: str) -> None:
        self._db_path = db_path

    async def init_db(self) -> None:
        """Create the traces table and indexes if they don't exist.

        Reads DDL from schema.sql sibling file and executes it.
        Called once during app lifespan.
        """
        schema_path = Path(__file__).parent / "schema.sql"
        schema = schema_path.read_text()
        async with aiosqlite.connect(self._db_path) as db:
            await db.executescript(schema)
            await db.commit()

    async def write(self, record: dict) -> None:
        """Insert a trace record into SQLite.

        Args:
            record: Dict with fields matching the traces table schema.
                    guardrail_decisions and cai_critique may be None or a dict/list
                    (will be JSON-serialized).
        """
        guardrail_json = (
            json.dumps(record.get("guardrail_decisions"))
            if record.get("guardrail_decisions") is not None
            else None
        )
        cai_json = (
            json.dumps(record.get("cai_critique"))
            if record.get("cai_critique") is not None
            else None
        )
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                INSERT INTO traces
                (request_id, tenant, timestamp, model, prompt, response,
                 latency_ms, status_code, guardrail_decisions, cai_critique,
                 refusal_event, bypass_flag)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record["request_id"],
                    record["tenant"],
                    record["timestamp"],
                    record["model"],
                    record["prompt"],
                    record["response"],
                    record["latency_ms"],
                    record["status_code"],
                    guardrail_json,
                    cai_json,
                    int(bool(record.get("refusal_event", False))),
                    int(bool(record.get("bypass_flag", False))),
                ),
            )
            await db.commit()

    async def query_by_id(self, request_id: str) -> dict | None:
        """Fetch a single trace record by request_id.

        Returns:
            dict of the row, or None if not found.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM traces WHERE request_id = ?", (request_id,)
            ) as cursor:
                row = await cursor.fetchone()
                return dict(row) if row else None

    async def query_by_timerange(
        self, since: str, until: str | None = None
    ) -> list[dict]:
        """Fetch trace records within a timestamp range.

        Args:
            since: ISO8601 string — lower bound (inclusive).
            until: ISO8601 string — upper bound (inclusive), or None for open-ended.

        Returns:
            List of trace record dicts ordered by timestamp ASC.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            if until is None:
                query = "SELECT * FROM traces WHERE timestamp >= ? ORDER BY timestamp ASC"
                params: tuple = (since,)
            else:
                query = (
                    "SELECT * FROM traces WHERE timestamp >= ? AND timestamp <= ? "
                    "ORDER BY timestamp ASC"
                )
                params = (since, until)
            async with db.execute(query, params) as cursor:
                rows = await cursor.fetchall()
                return [dict(row) for row in rows]
