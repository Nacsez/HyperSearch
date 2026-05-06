CREATE TABLE IF NOT EXISTS provider_configs (
    name TEXT PRIMARY KEY,
    provider_type TEXT NOT NULL,
    base_url TEXT,
    model TEXT,
    api_key TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    is_default INTEGER NOT NULL DEFAULT 0,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS search_history (
    history_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    query TEXT NOT NULL,
    request_json TEXT NOT NULL,
    response_json TEXT NOT NULL,
    debug_json TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS presets (
    preset_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);

