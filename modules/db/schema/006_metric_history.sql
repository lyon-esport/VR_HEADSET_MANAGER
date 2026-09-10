-- ==================================================================
-- VR HEADSET MANAGER - one history table for every metric (migration 006)
--
-- Migration 005 gave battery history a single home: one row per sample in
-- battery_history, written by a trigger on headset_status, pruned by a periodic
-- sweep. That shape was right. What was wrong was that it named ONE metric.
--
-- The operator asked for the same graph on temperature. headset_status already
-- carries five numeric readings that change over time and are already written on
-- every fast-path tick - battery, temp, both controller levels and charging
-- wattage - and cloning the battery stack per metric would mean a table, a
-- trigger, two query files, an endpoint branch and a page each time.
--
-- So the sample row grows one column, metric, and battery_history becomes
-- metric_history. Adding a sixth metric afterwards costs one trigger and one
-- registry entry. See ADR-0018.
--
-- Deliberately kept from the earlier migrations, because both encode a bug that
-- already cost this project a debugging session:
--
--   * update-then-insert, never INSERT OR REPLACE (migration 003). SQLite
--     IGNORES a conflict clause inside a trigger body and applies the firing
--     statement's policy instead - the default ABORT from status.upsert. Two
--     readings landing in the same second then aborted the whole batch, losing
--     every headset's status for that tick, not just the one that collided.
--
--   * no prune inside the trigger (migration 005). Sampling fires on the
--     monitor's hot write path; retention is Invoke-DbMaintenance's job, on the
--     slow loop, at most once every database.maintenance_interval_min.
--
-- New here: REPLACE(x, ',', '.'). Temperature and wattage are DECIMAL strings
-- formatted with .ToString("0.0"), which yields "36,4" under a FR locale.
-- CAST('36,4' AS REAL) silently returns 36 - a whole digit of precision gone,
-- with nothing to show for it in any log. Battery and the controller levels are
-- "85 %" strings, where CAST stops at the space; REPLACE is harmless there.
--
-- The value column is REAL, not INTEGER. A value is read back through its
-- column's DECLARED type, so an INTEGER column would hand 36.4 back as 36 even
-- though SQLite stored it correctly.
--
-- ASCII only.
-- ==================================================================

-- ---- 1. the generic table ----------------------------------------

CREATE TABLE IF NOT EXISTS metric_history (
    headset_id INTEGER NOT NULL REFERENCES headsets(id) ON DELETE CASCADE,
    metric     TEXT    NOT NULL,
    ts         TEXT    NOT NULL,
    value      REAL    NOT NULL,
    PRIMARY KEY (headset_id, metric, ts)
) WITHOUT ROWID;

-- The retention sweep deletes by age across all headsets and all metrics; the
-- graph reads one headset's one metric in time order, which the primary key
-- already covers.
CREATE INDEX IF NOT EXISTS ix_metric_history_ts ON metric_history(ts);

-- ---- 2. carry the battery samples over ---------------------------
-- OR IGNORE, not OR REPLACE: re-running this against a database that already
-- holds the rows must be a no-op rather than a rewrite.

INSERT OR IGNORE INTO metric_history(headset_id, metric, ts, value)
SELECT headset_id, 'battery', ts, CAST(pct AS REAL) FROM battery_history;

DROP TRIGGER IF EXISTS trg_status_battery_sample;
DROP TABLE IF EXISTS battery_history;

-- ---- 3. one sampling trigger per tracked column -------------------
-- The GLOB guard is what keeps '-' out: an unreachable headset has every one of
-- these columns reset to '-', and that must not be recorded as a reading.

CREATE TRIGGER trg_status_battery_sample
AFTER UPDATE OF battery ON headset_status
WHEN NEW.battery GLOB '[0-9]*' AND NEW.battery <> OLD.battery
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.battery, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'battery'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'battery', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.battery, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'battery'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

CREATE TRIGGER trg_status_temp_sample
AFTER UPDATE OF temp ON headset_status
WHEN NEW.temp GLOB '[0-9]*' AND NEW.temp <> OLD.temp
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.temp, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'temp'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'temp', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.temp, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'temp'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

CREATE TRIGGER trg_status_ctrl_left_sample
AFTER UPDATE OF battery_controller_left ON headset_status
WHEN NEW.battery_controller_left GLOB '[0-9]*'
 AND NEW.battery_controller_left <> OLD.battery_controller_left
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.battery_controller_left, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'ctrl_left'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'ctrl_left', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.battery_controller_left, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'ctrl_left'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

CREATE TRIGGER trg_status_ctrl_right_sample
AFTER UPDATE OF battery_controller_right ON headset_status
WHEN NEW.battery_controller_right GLOB '[0-9]*'
 AND NEW.battery_controller_right <> OLD.battery_controller_right
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.battery_controller_right, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'ctrl_right'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'ctrl_right', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.battery_controller_right, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'ctrl_right'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

CREATE TRIGGER trg_status_wattage_sample
AFTER UPDATE OF charging_wattage ON headset_status
WHEN NEW.charging_wattage GLOB '[0-9]*'
 AND NEW.charging_wattage <> OLD.charging_wattage
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.charging_wattage, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'wattage'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'wattage', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.charging_wattage, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'wattage'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;
