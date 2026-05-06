ALTER TABLE provider_configs ADD COLUMN display_name TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_search_history_kind_created_at
ON search_history(kind, created_at);

CREATE INDEX IF NOT EXISTS idx_search_history_query_created_at
ON search_history(query, created_at);

