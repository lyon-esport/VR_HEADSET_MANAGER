-- The newest N recommendation cycles, newest first. Callers reverse the
-- result to get chronological order. Column aliases match the legacy CSV
-- header, because callers read those property names.
SELECT ts           AS Timestamp,
       cpu_pct      AS CpuPct,
       gpu_pct      AS GpuPct,
       scrcpy_count AS ScrcpyCount,
       client_count AS ClientCount,
       direction    AS Direction,
       reason       AS Reason,
       json         AS Json
FROM vqa_history
ORDER BY id DESC
LIMIT @n;
