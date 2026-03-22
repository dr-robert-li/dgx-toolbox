PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS traces (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id      TEXT NOT NULL UNIQUE,
    tenant          TEXT NOT NULL,
    timestamp       TEXT NOT NULL,
    model           TEXT NOT NULL,
    prompt          TEXT NOT NULL,
    response        TEXT NOT NULL,
    latency_ms      INTEGER NOT NULL,
    status_code     INTEGER NOT NULL,
    guardrail_decisions TEXT,
    cai_critique    TEXT,
    refusal_event   INTEGER NOT NULL DEFAULT 0,
    bypass_flag     INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_traces_request_id ON traces(request_id);
CREATE INDEX IF NOT EXISTS idx_traces_timestamp  ON traces(timestamp);
CREATE INDEX IF NOT EXISTS idx_traces_tenant     ON traces(tenant);
