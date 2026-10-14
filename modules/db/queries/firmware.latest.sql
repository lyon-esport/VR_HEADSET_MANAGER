-- The newest recorded firmware of ONE headset, or no row when none was ever
-- recorded. The monitor compares against this before calling firmware.insert.
SELECT ts, firmware_version, environment
FROM firmware_history
WHERE headset_id = @headset_id
ORDER BY ts DESC
LIMIT 1;
