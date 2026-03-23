"""TraceStore — async SQLite trace storage with WAL mode."""
from __future__ import annotations

import json
from datetime import datetime, timezone
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

    async def write_eval_run(self, run: dict) -> None:
        """Insert an eval run record into the eval_runs table.

        Args:
            run: Dict with fields: run_id, timestamp, source, metrics (dict),
                 config_snapshot (dict), baseline_name (str or None).
        """
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                INSERT INTO eval_runs
                (run_id, timestamp, source, metrics, config_snapshot, baseline_name)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    run["run_id"],
                    run["timestamp"],
                    run["source"],
                    json.dumps(run["metrics"]),
                    json.dumps(run["config_snapshot"]),
                    run.get("baseline_name"),
                ),
            )
            await db.commit()

    async def query_eval_runs(
        self, source: str | None = None, limit: int = 20
    ) -> list[dict]:
        """Fetch eval run records ordered by timestamp DESC with optional source filter.

        Args:
            source: Optional source filter ("replay" or "lm-eval").
            limit: Maximum number of records to return (default 20).

        Returns:
            List of eval run dicts with metrics and config_snapshot parsed from JSON.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            if source is not None:
                query = (
                    "SELECT * FROM eval_runs WHERE source = ? "
                    "ORDER BY timestamp DESC LIMIT ?"
                )
                params: tuple = (source, limit)
            else:
                query = "SELECT * FROM eval_runs ORDER BY timestamp DESC LIMIT ?"
                params = (limit,)
            async with db.execute(query, params) as cursor:
                rows = await cursor.fetchall()
                result = []
                for row in rows:
                    record = dict(row)
                    record["metrics"] = json.loads(record["metrics"])
                    record["config_snapshot"] = json.loads(record["config_snapshot"])
                    result.append(record)
                return result

    async def create_job(self, job: dict) -> None:
        """Insert a new red team job with status='pending'.

        Args:
            job: Dict with fields: job_id, type ('garak' or 'deepteam').
        """
        created_at = datetime.now(timezone.utc).isoformat()
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                INSERT INTO redteam_jobs (job_id, type, status, created_at)
                VALUES (?, ?, 'pending', ?)
                """,
                (job["job_id"], job["type"], created_at),
            )
            await db.commit()

    async def update_job_status(
        self, job_id: str, status: str, result: dict | None = None
    ) -> None:
        """Update a red team job's status (and optionally result).

        Sets completed_at for terminal statuses ('complete', 'failed').

        Args:
            job_id: Unique job identifier.
            status: New status ('running', 'complete', 'failed').
            result: Optional result dict (JSON-serialized).
        """
        completed_at = (
            datetime.now(timezone.utc).isoformat()
            if status in ("complete", "failed")
            else None
        )
        result_json = json.dumps(result) if result is not None else None
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                UPDATE redteam_jobs
                SET status = ?, completed_at = ?, result = ?
                WHERE job_id = ?
                """,
                (status, completed_at, result_json, job_id),
            )
            await db.commit()

    async def get_job(self, job_id: str) -> dict | None:
        """Fetch a single red team job by job_id.

        Returns:
            dict of the row with result parsed from JSON, or None if not found.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM redteam_jobs WHERE job_id = ?", (job_id,)
            ) as cursor:
                row = await cursor.fetchone()
                if row is None:
                    return None
                record = dict(row)
                if record.get("result") is not None:
                    record["result"] = json.loads(record["result"])
                return record

    async def list_jobs(self, limit: int = 20) -> list[dict]:
        """Fetch red team jobs ordered by created_at DESC.

        Args:
            limit: Maximum number of records to return (default 20).

        Returns:
            List of job dicts with result parsed from JSON.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM redteam_jobs ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ) as cursor:
                rows = await cursor.fetchall()
                result = []
                for row in rows:
                    record = dict(row)
                    if record.get("result") is not None:
                        record["result"] = json.loads(record["result"])
                    result.append(record)
                return result

    async def query_near_misses(self, since: str, limit: int = 100) -> list[dict]:
        """Fetch traces that scored above zero but were not blocked.

        Queries traces since the given timestamp that were not refusals and
        had guardrail decisions recorded, then filters in Python to keep only
        those where at least one rail result has score > 0.

        Args:
            since: ISO8601 string — lower bound (inclusive).
            limit: Maximum number of records to return (default 100).

        Returns:
            List of trace dicts matching near-miss criteria.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                """
                SELECT * FROM traces
                WHERE timestamp >= ?
                  AND guardrail_decisions IS NOT NULL
                  AND refusal_event = 0
                ORDER BY timestamp DESC
                LIMIT ?
                """,
                (since, limit),
            ) as cursor:
                rows = await cursor.fetchall()

        near_misses = []
        for row in rows:
            record = dict(row)
            gd = json.loads(record["guardrail_decisions"])
            all_results = gd.get("all_results", [])
            if any(r.get("score", 0) > 0 for r in all_results):
                near_misses.append(record)
        return near_misses

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
