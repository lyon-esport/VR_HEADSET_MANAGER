-- ==================================================================
-- VR HEADSET MANAGER - one home for battery history (migration 005)
--
-- The same data was being kept twice, in two shapes, with two retention
-- policies, and only one of them was ever read:
--
--   headset_status.battery_history  a packed "ts=pct|ts=pct" TEXT cell holding
--                                   the last 3 samples. Read by the poll
--                                   runspace for its time-remaining estimate,
--                                   and wiped at every startup along with the
--                                   rest of the status row.
--   battery_history (table)         one row per sample, pruned to 100 per
--                                   headset by a trigger. Read by NOTHING - no
--                                   query file, no PowerShell.
--
-- The table is the one worth keeping: a battery-level graph is planned, and a
-- normalised row per sample is what that needs. It also survives a restart,
-- which the packed cell never did despite a comment claiming otherwise.
--
-- This migration therefore:
--   1. drops the packed cell and rebuilds the two views that exposed it,
--   2. rewrites the sampling trigger to INSERT only.
--
-- Retention moves from "100 rows per headset" to a time window
-- (database.battery_history_hours, default 24) enforced by a periodic sweep,
-- NOT by the trigger. Sampling happens on every battery change, so pruning
-- inside the trigger made each sample pay for a DELETE and a correlated
-- subquery on the monitor's hot write path. Invoke-DbMaintenance does it
-- instead, at most once every database.maintenance_interval_min minutes, from
-- the monitor's slow loop.
--
-- ASCII only.
-- ==================================================================

-- ---- 1. the packed cell goes -------------------------------------
-- The views must be dropped first: SQLite refuses to drop a column that a
-- view still references.

DROP VIEW IF EXISTS v_headset_full;
DROP VIEW IF EXISTS v_headset_status;

ALTER TABLE headset_status DROP COLUMN battery_history;

CREATE VIEW v_headset_status AS
SELECT CAST(headset_id AS TEXT)                     AS ID,
       CASE ping     WHEN 1 THEN 'True' ELSE 'False' END AS Ping,
       CASE adb_wifi WHEN 1 THEN 'True' ELSE 'False' END AS ADBWifi,
       battery                                      AS Battery,
       charging                                     AS Charging,
       charging_wattage                             AS ChargingWattage,
       temp                                         AS Temp,
       battery_controller_left                      AS BatteryControllerLeft,
       battery_controller_right                     AS BatteryControllerRight,
       power_state                                  AS PowerState,
       time_remaining_min                           AS TimeRemainingMin,
       scrcpy                                       AS SCRCPY,
       running_app                                  AS RunningApp,
       running_app_icon                             AS RunningAppIcon,
       updated_at                                   AS UpdatedAt
FROM headset_status;

CREATE VIEW v_headset_full AS
SELECT h.ID, h.Name, h.IPAddress, h.scrcpy_AutoRestart, h.Record, h.ScrcpyProfile,
       h.Brand, h.Model, h.SerialNumber, h.SortOrder,
       s.Ping, s.ADBWifi, s.Battery, s.Charging, s.ChargingWattage, s.Temp,
       s.BatteryControllerLeft, s.BatteryControllerRight, s.PowerState,
       s.TimeRemainingMin, s.SCRCPY, s.RunningApp, s.RunningAppIcon
FROM v_headsets h
JOIN v_headset_status s ON s.ID = h.ID;

-- ---- 2. sample only, never prune ---------------------------------
-- Still an explicit update-then-insert rather than INSERT OR REPLACE: SQLite
-- ignores a conflict clause inside a trigger body and uses the firing
-- statement's policy instead, which is what migration 003 fixed. Two readings
-- inside the same second collapse to the later one.

DROP TRIGGER IF EXISTS trg_status_battery_sample;

CREATE TRIGGER trg_status_battery_sample
AFTER UPDATE OF battery ON headset_status
WHEN NEW.battery GLOB '[0-9]*' AND NEW.battery <> OLD.battery
BEGIN
    UPDATE battery_history
       SET pct = CAST(NEW.battery AS INTEGER)
     WHERE headset_id = NEW.headset_id
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO battery_history(headset_id, ts, pct)
    SELECT NEW.headset_id,
           strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(NEW.battery AS INTEGER)
     WHERE NOT EXISTS (
           SELECT 1 FROM battery_history
            WHERE headset_id = NEW.headset_id
              AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

-- An index on ts: the retention sweep deletes by age across all headsets, and
-- the planned graph will read one headset's samples in time order.
CREATE INDEX IF NOT EXISTS ix_battery_history_ts ON battery_history(ts);
