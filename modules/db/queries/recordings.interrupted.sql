-- Recordings whose writer was killed or never closed them (status 'interrupted'): candidates for
-- the background remux of Update-RecordingRepair, oldest first.
SELECT id, file_path, started_at
  FROM recordings
 WHERE status = 'interrupted'
 ORDER BY id
 LIMIT @limit;
