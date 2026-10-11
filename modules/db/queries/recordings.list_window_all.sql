-- Same as recordings.list_window, for every headset (grouped by headset).
SELECT * FROM recordings
 WHERE started_at < @to_ts
   AND COALESCE(ended_at, CASE WHEN status = 'recording' THEN '9999-12-31T23:59:59' ELSE started_at END) >= @from_ts
 ORDER BY safe_name, started_at;