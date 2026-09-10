-- The newest battery samples for one headset, oldest first.
--
-- Replaces the packed "ts=pct|ts=pct" cell the poll runspace used to preload
-- from headset_status. That cell was truncated at every startup, so the
-- estimate never actually survived a restart despite the comment saying it
-- did; these rows do survive, so now it does.
--
-- Reads metric_history since migration 006, which folded battery_history into
-- it. The value column is REAL now, and it is aliased back to pct so
-- Get-BatteryTimeEstimate's caller keeps the shape it has always consumed -
-- battery is whole percent, so nothing is lost in the round trip.
--
-- Ordered oldest-first because Get-BatteryTimeEstimate reads the series as a
-- slope and treats the last entry as the current level. The inner query takes
-- the NEWEST @limit rows, the outer one puts them back in chronological order.
SELECT ts, pct
FROM (
    SELECT ts, value AS pct
    FROM metric_history
    WHERE headset_id = @headset_id AND metric = 'battery'
    ORDER BY ts DESC
    LIMIT @limit
)
ORDER BY ts ASC;
