-- Firmware changes of ONE headset, newest first (DIAG page, Firmware card).
SELECT ts, firmware_version, environment
FROM firmware_history
WHERE headset_id = @headset_id
ORDER BY ts DESC
LIMIT 50;
