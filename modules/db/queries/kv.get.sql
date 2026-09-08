-- One snapshot value from the key/value store, as JSON text.
SELECT value_json FROM app_kv WHERE key = @key;
