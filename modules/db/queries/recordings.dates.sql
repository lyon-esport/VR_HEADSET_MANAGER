-- Days (local, yyyy-MM-dd) that hold at least one recording, newest first.
-- Empty @safe_name means every headset.
SELECT DISTINCT substr(started_at, 1, 10) AS day
  FROM recordings
 WHERE (@safe_name = '' OR safe_name = @safe_name)
 ORDER BY day DESC;