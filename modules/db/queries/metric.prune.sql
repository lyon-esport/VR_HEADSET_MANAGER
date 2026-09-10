-- Drop metric samples older than the retention window, across every headset and
-- every metric.
--
-- Called by Invoke-DbMaintenance on a long interval, never from the triggers
-- that write the samples: sampling fires on every reading change, and pruning
-- there would put this DELETE on the monitor's hot write path.
--
-- @cutoff is an ISO-8601 UTC timestamp, the same format the triggers write, so
-- the comparison is a plain string compare on an indexed column.
DELETE FROM metric_history WHERE ts < @cutoff;
