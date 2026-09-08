-- Insert or replace one snapshot value, refreshing its timestamp.
INSERT INTO app_kv (key, value_json, updated_at)
VALUES (@key, @value_json, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
ON CONFLICT(key) DO UPDATE SET
    value_json = excluded.value_json,
    updated_at = excluded.updated_at;
