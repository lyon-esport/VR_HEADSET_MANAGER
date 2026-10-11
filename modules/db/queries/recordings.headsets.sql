-- Headsets that have recordings, with their count. Keyed on safe_name because
-- headset_id goes NULL when a headset leaves the registry.
SELECT safe_name,
       MAX(headset_id)   AS headset_id,
       MAX(headset_name) AS headset_name,
       COUNT(*)          AS cnt
  FROM recordings
 GROUP BY safe_name
 ORDER BY safe_name;