-- ==================================================================
-- VR HEADSET MANAGER - DIAG page: temperatures, transport, firmware (007)
--
-- Three things the headset DIAG page and the metric graph need:
--
--   1. headset_status grows cpu_temp / gpu_temp / skin_temp. They are the
--      hottest sensor of each type in "dumpsys thermalservice", read by the
--      poll runspace at most every 30 s. Each one gets a sampling trigger into
--      metric_history exactly like migration 006's - adding a metric costs one
--      column, one trigger and one registry entry (ADR-0018).
--
--   2. headset_status grows adb_transport ('USB' / 'WiFi' / '-'): which
--      transport the poll loop actually used. Shown as a badge in the UI. Not
--      sampled - it is a state, not a reading.
--
--   3. firmware_history: one row per firmware CHANGE per headset. The insert
--      query skips a row equal to the newest one, so the monitor can call it
--      on a timer. The DIAG page compares the fleet from this table only (no
--      internet lookup).
--
-- Both views that expose headset_status are rebuilt: a view lists its columns
-- explicitly, so a new column is invisible until the view is recreated.
--
-- Kept from 006: the GLOB guard (never sample '-'), REPLACE(',', '.') for FR
-- decimal commas, update-then-insert inside the trigger (never INSERT OR
-- REPLACE - see 003), and no prune in the trigger (see 005).
--
-- ASCII only.
-- ==================================================================

-- ---- 1. new live-status columns ----------------------------------
-- NOT NULL with a default is allowed by ALTER TABLE ADD COLUMN, and existing
-- rows read the default immediately.

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
       battery_controller_left                      AS BatteryControllerLeft,
       battery_controller_right                     AS BatteryControllerRight,
       power_state                                  AS PowerState,
       time_remaining_min                           AS TimeRemainingMin,
       scrcpy                                       AS SCRCPY,
       running_app                                  AS RunningApp,
       running_app_icon                             AS RunningAppIcon,
       cpu_temp                                     AS CpuTemp,
       gpu_temp                                     AS GpuTemp,
       skin_temp                                    AS SkinTemp,
       adb_transport                                AS AdbTransport,
       updated_at                                   AS UpdatedAt
FROM headset_status;

CREATE VIEW v_headset_full AS
SELECT h.ID, h.Name, h.IPAddress, h.scrcpy_AutoRestart, h.Record, h.ScrcpyProfile,
       h.Brand, h.Model, h.SerialNumber, h.SortOrder,
       s.Ping, s.ADBWifi, s.Battery, s.Charging, s.ChargingWattage, s.Temp,
       s.BatteryControllerLeft, s.BatteryControllerRight, s.PowerState,
       s.TimeRemainingMin, s.SCRCPY, s.RunningApp, s.RunningAppIcon,
       s.CpuTemp, s.GpuTemp, s.SkinTemp, s.AdbTransport
FROM v_headsets h
JOIN v_headset_status s ON s.ID = h.ID;

-- ---- 2. one sampling trigger per temperature ---------------------

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

CREATE TABLE IF NOT EXISTS firmware_history (
    headset_id       INTEGER NOT NULL REFERENCES headsets(id) ON DELETE CASCADE,
    ts               TEXT    NOT NULL,
    firmware_version TEXT    NOT NULL,
    environment      TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (headset_id, ts)
) WITHOUT ROWID;
