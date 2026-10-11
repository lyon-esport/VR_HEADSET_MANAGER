-- Finished recordings whose media info (codec / size / duration) was never probed:
-- the startup sync imports a large folder without probing every file (ADR-0029),
-- and later sync passes fill a bounded number of them per pass.
SELECT id, file_path, started_at, ended_at, status
  FROM recordings
 WHERE status <> 'recording' AND codec = ''
 ORDER BY started_at DESC
 LIMIT @limit;
