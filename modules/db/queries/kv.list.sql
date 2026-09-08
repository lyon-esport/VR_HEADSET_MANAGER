-- Every snapshot key with its last write time (diagnostics / tests).
SELECT key AS Key, value_json AS ValueJson, updated_at AS UpdatedAt
FROM app_kv
ORDER BY key;
