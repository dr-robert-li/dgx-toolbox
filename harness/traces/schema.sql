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

CREATE TABLE IF NOT EXISTS eval_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          TEXT NOT NULL UNIQUE,
    timestamp       TEXT NOT NULL,
    source          TEXT NOT NULL CHECK(source IN ('replay', 'lm-eval')),
    metrics         TEXT NOT NULL,
    config_snapshot TEXT NOT NULL,
    baseline_name   TEXT
);
CREATE INDEX IF NOT EXISTS idx_eval_runs_timestamp ON eval_runs(timestamp);
CREATE INDEX IF NOT EXISTS idx_eval_runs_source    ON eval_runs(source);
