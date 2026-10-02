-- Record one firmware reading for one headset, ONLY when it differs from the
-- newest stored row (migration 007). The poll runspace calls this on a
-- 10-minute timer, so the WHERE NOT EXISTS is what makes the table a list of
-- changes rather than a list of polls.
--
-- OR IGNORE on the primary key: two readings in the same second (a restart
-- racing the timer) collapse to the first instead of aborting.
INSERT OR IGNORE INTO firmware_history (headset_id, ts, firmware_version, environment)
SELECT @headset_id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), @firmware_version, @environment
WHERE NOT EXISTS (
    SELECT 1 FROM (
        SELECT firmware_version, environment
        FROM firmware_history
        WHERE headset_id = @headset_id
        ORDER BY ts DESC
        LIMIT 1
    ) last
    WHERE last.firmware_version = @firmware_version
      AND last.environment      = @environment
);
