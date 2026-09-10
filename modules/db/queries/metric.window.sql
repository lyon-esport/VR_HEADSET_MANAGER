-- Samples of ONE metric for ONE headset over a time window, oldest first.
--
-- Backs the metric-history graph (battery, temp, ctrl_left, ctrl_right,
-- wattage). Distinct from battery.recent, which takes a fixed COUNT of newest
-- rows for the time-remaining slope; this one takes a time RANGE, because the
-- graph's window is what the operator picked.
--
-- The first row is the newest sample at or before @since, when one exists. A
-- sample is only written when the value CHANGES, so a headset that has sat at
-- 100% for six hours has no row inside a 1h window at all - without that seed
-- row the chart would draw nothing rather than the flat line that is the truth.
-- The seed arm needs its own subquery wrapper: SQLite rejects ORDER BY ... LIMIT
-- directly on an arm of a compound select.
--
-- @since is an ISO-8601 UTC timestamp in the same format the sampling triggers
-- write, so both comparisons are plain string compares on ix_metric_history_ts.
SELECT ts, value FROM (
    SELECT ts, value FROM (
        SELECT ts, value
        FROM metric_history
        WHERE headset_id = @headset_id AND metric = @metric AND ts < @since
        ORDER BY ts DESC
        LIMIT 1
    )
    UNION ALL
    SELECT ts, value
    FROM metric_history
    WHERE headset_id = @headset_id AND metric = @metric AND ts >= @since
)
ORDER BY ts ASC;
