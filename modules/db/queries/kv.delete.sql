-- Remove one snapshot value.
DELETE FROM app_kv WHERE key = @key;
