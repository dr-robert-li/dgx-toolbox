"""TraceStore — async SQLite trace storage with WAL mode."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

import aiosqlite


# ---------------------------------------------------------------------------
# Module-level helpers for HITL priority computation
# ---------------------------------------------------------------------------


def compute_priority(guardrail_decisions: dict) -> float:
    """Compute HITL review priority from guardrail decisions.

    Priority is 1.0 - min(threshold - score) for results with score > 0.
    Closest-to-threshold items get the highest priority.
    Returns 0.0 when there are no scoreable results.

    Args:
        guardrail_decisions: Dict with optional 'all_results' list.
            Each result should have 'score' and 'threshold' fields.

    Returns:
        Float in [0.0, 1.0], higher = more urgent review needed.
    """
    # guardrail_decisions may be a list (from trace JSON) or a dict with 'all_results'
    if isinstance(guardrail_decisions, list):
        all_results = guardrail_decisions
    else:
        all_results = guardrail_decisions.get("all_results", [])
    distances = []
    for result in all_results:
        score = result.get("score", 0)
        threshold = result.get("threshold", 1.0)
        if score > 0:
            distances.append(threshold - score)
    if not distances:
        return 0.0
    return 1.0 - min(distances)


def _extract_triggering_rail(guardrail_decisions) -> str | None:
    """Return the rail name from the all_results entry closest to threshold.

    Args:
        guardrail_decisions: List of rail results, or dict with 'all_results' key.

    Returns:
        Rail name string, or None if no results with score > 0.
    """
    if isinstance(guardrail_decisions, list):
        all_results = guardrail_decisions
    else:
        all_results = guardrail_decisions.get("all_results", [])
    best = None
    best_distance = float("inf")
    for result in all_results:
        score = result.get("score", 0)
        threshold = result.get("threshold", 1.0)
        if score > 0:
            distance = threshold - score
            if distance < best_distance:
                best_distance = distance
                best = result.get("rail_name") or result.get("rail")
    return best


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

    async def write_correction(self, correction: dict) -> None:
        """Insert a correction record into the corrections table.

        PII in edited_response is redacted before storage.
        Validates that action is one of 'approve', 'reject', 'edit' — SQLite
        CHECK constraint enforces this; raises on invalid action.

        Args:
            correction: Dict with fields: request_id, reviewer, action,
                        edited_response (optional), trace_ref (optional).
        """
        from harness.pii.redactor import redact as redact_text

        edited_response = correction.get("edited_response")
        if edited_response is not None:
            edited_response = redact_text(edited_response)

        created_at = correction.get("created_at") or datetime.now(timezone.utc).isoformat()

        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                INSERT INTO corrections
                (request_id, reviewer, action, edited_response, created_at, trace_ref)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    correction["request_id"],
                    correction["reviewer"],
                    correction["action"],
                    edited_response,
                    created_at,
                    correction.get("trace_ref"),
                ),
            )
            await db.commit()

    async def query_corrections(self, request_id: str | None = None) -> list[dict]:
        """Fetch correction records.

        Args:
            request_id: If provided, filter to corrections for this request_id.

        Returns:
            List of correction dicts ordered by created_at DESC.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            if request_id is not None:
                query = "SELECT * FROM corrections WHERE request_id = ? ORDER BY created_at DESC"
                params: tuple = (request_id,)
            else:
                query = "SELECT * FROM corrections ORDER BY created_at DESC"
                params = ()
            async with db.execute(query, params) as cursor:
                rows = await cursor.fetchall()
                return [dict(row) for row in rows]

    async def query_hitl_queue(
        self,
        since: str,
        rail_filter: str = "all",
        tenant_filter: str = "all",
        hide_reviewed: bool = False,
        limit: int = 200,
    ) -> list[dict]:
        """Fetch HITL review queue: flagged traces sorted by priority.

        Priority ordering: unreviewed items before reviewed, within each group
        sorted by priority DESC (closest to threshold first).

        Args:
            since: ISO8601 timestamp lower bound (inclusive).
            rail_filter: Rail name to filter on, or 'all' for no filter.
            tenant_filter: Tenant ID to filter on, or 'all' for no filter.
            hide_reviewed: If True, exclude traces with existing corrections.
            limit: Maximum traces to fetch from DB before Python post-processing.

        Returns:
            List of trace dicts augmented with: priority (float),
            triggering_rail (str|None), correction_action (str|None),
            correction_reviewer (str|None), cai_critique (dict|None).
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                """
                SELECT t.*, c.action AS correction_action, c.reviewer AS correction_reviewer
                FROM traces t
                LEFT JOIN corrections c ON c.request_id = t.request_id
                WHERE t.timestamp >= ?
                  AND t.guardrail_decisions IS NOT NULL
                  AND (? = 'all' OR t.tenant = ?)
                ORDER BY t.timestamp DESC
                LIMIT ?
                """,
                (since, tenant_filter, tenant_filter, limit),
            ) as cursor:
                rows = await cursor.fetchall()

        results = []
        for row in rows:
            record = dict(row)

            # Parse guardrail_decisions JSON
            gd_raw = record.get("guardrail_decisions")
            if gd_raw is not None:
                try:
                    gd = json.loads(gd_raw) if isinstance(gd_raw, str) else gd_raw
                except (json.JSONDecodeError, TypeError):
                    gd = {}
            else:
                gd = {}
            record["guardrail_decisions"] = gd

            # Compute priority and extract triggering rail
            priority = compute_priority(gd)
            triggering_rail = _extract_triggering_rail(gd)
            record["priority"] = priority
            record["triggering_rail"] = triggering_rail

            # Apply rail filter
            if rail_filter != "all" and triggering_rail != rail_filter:
                continue

            # Apply hide_reviewed filter
            if hide_reviewed and record.get("correction_action") is not None:
                continue

            # Parse cai_critique JSON if present
            cai_raw = record.get("cai_critique")
            if cai_raw is not None:
                try:
                    record["cai_critique"] = json.loads(cai_raw) if isinstance(cai_raw, str) else cai_raw
                except (json.JSONDecodeError, TypeError):
                    record["cai_critique"] = None
            else:
                record["cai_critique"] = None

            results.append(record)

        # Sort: reviewed items last, then by priority DESC
        results.sort(
            key=lambda r: (r.get("correction_action") is not None, -r.get("priority", 0.0))
        )

        return results

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
