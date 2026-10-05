-- ==================================================================
-- VR HEADSET MANAGER - DIAG page support (migration 007)
--
-- Three things the headset DIAG page and the USB-first transport need from
-- the database, none of which is derivable from what 006 left behind:
--
--   1. cpu_temp / gpu_temp / skin_temp on headset_status, so the three
--      thermalservice readings land in the SAME metric-history graph as the
--      battery temperature. Same shape as migration 006: one column, one
--      sampling trigger each, one registry entry per metric
--      (Get-HeadsetMetricDefinition + METRICS in battery_chart.js). Adding a
--      metric costs those three things and nothing else - which is exactly the
--      point of 006.
--
--   2. adb_transport on headset_status (USB, WiFi or a dash): which transport
--      the monitor is currently talking to the headset over. The UI shows it
--      as a badge so an operator can see at a glance that a cabled headset is
--      really using the cable.
--
--   3. firmware_history: one row each time a headset firmware version
--      CHANGES. The fleet comparison (this headset is behind the newest
--      firmware of its model) needs more than the current value, and an
--      operator asking when a headset was updated has no other source.
--      Written by the monitor, never by a trigger - the version is read over
--      ADB at a slow cadence, not carried on the status row.
--
-- The three sampling triggers copy 006 deliberately, including the two things
-- that already cost this project a debugging session each:
--
--   * update-then-insert, never INSERT OR REPLACE (a conflict clause inside a
--     trigger body is ignored; the policy of the firing statement wins).
--   * REPLACE(x, ',', '.'): the values are formatted with .ToString("0.0"),
--     which gives 36,4 under a FR locale, and CAST of that text AS REAL is 36.
--
-- The views are dropped first because SQLite refuses to alter a column set a
-- view still references (same dance as migration 005).
--
-- ASCII only.
-- ==================================================================

-- ---- 1. new live-status columns ----------------------------------

DROP VIEW IF EXISTS v_headset_full;
DROP VIEW IF EXISTS v_headset_status;

ALTER TABLE headset_status ADD COLUMN cpu_temp      TEXT NOT NULL DEFAULT '-';
ALTER TABLE headset_status ADD COLUMN gpu_temp      TEXT NOT NULL DEFAULT '-';
ALTER TABLE headset_status ADD COLUMN skin_temp     TEXT NOT NULL DEFAULT '-';
ALTER TABLE headset_status ADD COLUMN adb_transport TEXT NOT NULL DEFAULT '-';

CREATE VIEW v_headset_status AS
SELECT CAST(headset_id AS TEXT)                     AS ID,
       CASE ping     WHEN 1 THEN 'True' ELSE 'False' END AS Ping,
       CASE adb_wifi WHEN 1 THEN 'True' ELSE 'False' END AS ADBWifi,
       battery                                      AS Battery,
       charging                                     AS Charging,
       charging_wattage                             AS ChargingWattage,
       temp                                         AS Temp,
       cpu_temp                                     AS CpuTemp,
       gpu_temp                                     AS GpuTemp,
       skin_temp                                    AS SkinTemp,
       battery_controller_left                      AS BatteryControllerLeft,
       battery_controller_right                     AS BatteryControllerRight,
       power_state                                  AS PowerState,
       time_remaining_min                           AS TimeRemainingMin,
       adb_transport                                AS AdbTransport,
       scrcpy                                       AS SCRCPY,
       running_app                                  AS RunningApp,
       running_app_icon                             AS RunningAppIcon,
       updated_at                                   AS UpdatedAt
FROM headset_status;

CREATE VIEW v_headset_full AS
SELECT h.ID, h.Name, h.IPAddress, h.scrcpy_AutoRestart, h.Record, h.ScrcpyProfile,
       h.Brand, h.Model, h.SerialNumber, h.SortOrder,
       s.Ping, s.ADBWifi, s.Battery, s.Charging, s.ChargingWattage, s.Temp,
       s.CpuTemp, s.GpuTemp, s.SkinTemp,
       s.BatteryControllerLeft, s.BatteryControllerRight, s.PowerState,
       s.TimeRemainingMin, s.AdbTransport, s.SCRCPY, s.RunningApp, s.RunningAppIcon
FROM v_headsets h
JOIN v_headset_status s ON s.ID = h.ID;

-- ---- 2. one sampling trigger per new metric ----------------------
-- The GLOB guard keeps the dash out: an unreachable headset has these columns
-- reset to a dash, and that must not be recorded as a reading.

CREATE TRIGGER trg_status_cpu_temp_sample
AFTER UPDATE OF cpu_temp ON headset_status
WHEN NEW.cpu_temp GLOB '[0-9]*' AND NEW.cpu_temp <> OLD.cpu_temp
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.cpu_temp, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'cpu_temp'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'cpu_temp', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.cpu_temp, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'cpu_temp'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

CREATE TRIGGER trg_status_gpu_temp_sample
AFTER UPDATE OF gpu_temp ON headset_status
WHEN NEW.gpu_temp GLOB '[0-9]*' AND NEW.gpu_temp <> OLD.gpu_temp
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.gpu_temp, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'gpu_temp'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'gpu_temp', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.gpu_temp, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'gpu_temp'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

CREATE TRIGGER trg_status_skin_temp_sample
AFTER UPDATE OF skin_temp ON headset_status
WHEN NEW.skin_temp GLOB '[0-9]*' AND NEW.skin_temp <> OLD.skin_temp
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.skin_temp, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'skin_temp'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'skin_temp', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.skin_temp, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'skin_temp'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;

-- ---- 3. firmware history -----------------------------------------
-- One row per CHANGE of the firmware version (the monitor compares before it
-- inserts). ON DELETE CASCADE: removing a headset removes its history, like
-- every other per-headset table, so a removal needs no file or table work.

CREATE TABLE IF NOT EXISTS firmware_history (
    headset_id       INTEGER NOT NULL REFERENCES headsets(id) ON DELETE CASCADE,
    ts               TEXT    NOT NULL,
    firmware_version TEXT    NOT NULL,
    environment      TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (headset_id, ts)
) WITHOUT ROWID;
