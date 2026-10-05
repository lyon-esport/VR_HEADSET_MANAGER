-- Every recorded firmware change of ONE headset, newest first. Backs the
-- history list on the DIAG page (when did this headset get updated).
SELECT ts, firmware_version, environment
FROM firmware_history
WHERE headset_id = @headset_id
ORDER BY ts DESC
LIMIT @limit;
