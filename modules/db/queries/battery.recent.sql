-- The newest battery samples for one headset, oldest first.
--
-- Replaces the packed "ts=pct|ts=pct" cell the poll runspace used to preload
-- from headset_status. That cell was truncated at every startup, so the
-- estimate never actually survived a restart despite the comment saying it
-- did; these rows do survive, so now it does.
--
-- Ordered oldest-first because Get-BatteryTimeEstimate reads the series as a
-- slope and treats the last entry as the current level. The inner query takes
-- the NEWEST @limit rows, the outer one puts them back in chronological order.
SELECT ts, pct
FROM (
    SELECT ts, pct
    FROM battery_history
    WHERE headset_id = @headset_id
    ORDER BY ts DESC
    LIMIT @limit
)
ORDER BY ts ASC;
