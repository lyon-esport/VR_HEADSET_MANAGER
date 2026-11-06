-- Insert one snapshot value only when the key is absent (race-safe first creation).
INSERT INTO app_kv (key, value_json, updated_at)
VALUES (@key, @value_json, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
ON CONFLICT(key) DO NOTHING;
