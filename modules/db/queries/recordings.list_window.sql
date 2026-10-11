-- Recordings of ONE headset overlapping the window [from_ts, to_ts).
-- An unfinished recording (no ended_at) is treated as a point at its start.
SELECT * FROM recordings
 WHERE safe_name = @safe_name
   AND started_at < @to_ts
   AND COALESCE(ended_at, CASE WHEN status = 'recording' THEN '9999-12-31T23:59:59' ELSE started_at END) >= @from_ts
 ORDER BY started_at;