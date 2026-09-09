-- ==================================================================
-- VR HEADSET MANAGER - battery history sampling fix (migration 003)
--
-- 001 wrote the sampling trigger as:
--
--     INSERT OR REPLACE INTO battery_history(headset_id, ts, pct) VALUES (...)
--
-- which does NOT do what it reads like. SQLite ignores a conflict-resolution
-- clause on a statement inside a trigger body: the policy of the statement that
-- FIRED the trigger is used instead. The firing statement is status.upsert,
-- whose policy is the default ABORT, so the OR REPLACE degraded to a plain
-- INSERT.
--
-- battery_history is keyed (headset_id, ts) at one-second resolution, so two
-- battery readings for the same headset inside the same second raised
-- "UNIQUE constraint failed" - and because the monitor writes every headset's
-- status in ONE batch transaction, that aborted the whole tick: every
-- headset's live status lost, not just the one that collided.
--
-- Replaced with an explicit update-then-insert-if-absent, which needs no
-- conflict clause and therefore cannot be overridden. Same intent as before:
-- within a given second the latest reading wins.
--
-- ASCII only.
-- ==================================================================

DROP TRIGGER IF EXISTS trg_status_battery_sample;

CREATE TRIGGER trg_status_battery_sample
AFTER UPDATE OF battery ON headset_status
WHEN NEW.battery GLOB '[0-9]*' AND NEW.battery <> OLD.battery
BEGIN
    -- Same second, same headset: overwrite the sample already taken.
    UPDATE battery_history
       SET pct = CAST(NEW.battery AS INTEGER)
     WHERE headset_id = NEW.headset_id
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    -- Otherwise add it.
    INSERT INTO battery_history(headset_id, ts, pct)
    SELECT NEW.headset_id,
           strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(NEW.battery AS INTEGER)
     WHERE NOT EXISTS (
           SELECT 1 FROM battery_history
            WHERE headset_id = NEW.headset_id
              AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));

    -- Keep only the newest 100 samples for this headset.
    DELETE FROM battery_history
     WHERE headset_id = NEW.headset_id
       AND ts NOT IN (SELECT ts FROM battery_history
                       WHERE headset_id = NEW.headset_id
                       ORDER BY ts DESC LIMIT 100);
END;
