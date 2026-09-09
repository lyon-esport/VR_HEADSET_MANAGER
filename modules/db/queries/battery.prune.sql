-- Drop battery samples older than the retention window.
--
-- Called by Invoke-DbMaintenance on a long interval, never from the trigger
-- that writes the samples: sampling fires on every battery change, and pruning
-- there would put this DELETE on the monitor's hot write path.
--
-- @cutoff is an ISO-8601 UTC timestamp, the same format the trigger writes, so
-- the comparison is a plain string compare on an indexed column.
DELETE FROM battery_history WHERE ts < @cutoff;
