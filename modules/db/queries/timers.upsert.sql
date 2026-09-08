-- One per-headset timer configuration. Only the config lives in the database;
-- the live countdown stays a static file served to remote OBS sources.
INSERT INTO headset_timers (headset_id, minutes, seconds, mode)
VALUES (@headset_id, @minutes, @seconds, @mode)
ON CONFLICT(headset_id) DO UPDATE SET
    minutes = excluded.minutes,
    seconds = excluded.seconds,
    mode    = excluded.mode;
