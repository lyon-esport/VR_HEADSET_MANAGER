-- Finished recordings a wipe could remove, optionally for one headset.
-- @mode 'older': started before @before.  @mode 'date': started on day @date.
-- Kept rows are returned too so the caller can count the protected ones; the
-- caller filters keep = 1 out of the deletion. Never returns a live recording.
SELECT * FROM recordings
 WHERE status <> 'recording'
   AND (@safe_name = '' OR safe_name = @safe_name)
   AND ((@mode = 'older' AND started_at < @before)
     OR (@mode = 'date'  AND substr(started_at, 1, 10) = @date))
 ORDER BY started_at;