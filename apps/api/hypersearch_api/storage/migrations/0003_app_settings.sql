CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'default',
    updated_at TEXT NOT NULL
);

