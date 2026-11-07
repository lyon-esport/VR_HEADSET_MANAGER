-- ==================================================================
-- VR HEADSET MANAGER - battery power on the live status (migration 010)
--
-- charging_wattage is now the POWER SOURCE (what the charger can deliver, 0
-- unplugged). battery_power is the signed power flowing into (+) or out of (-)
-- the battery, in watts, as a decimal string. A dash means unknown.
--
-- Additive: one column with a default. Views are dropped and recreated (same
-- dance as migrations 005, 007 and 009). A sampling trigger records the new
-- metric 'batt_power' in metric_history; unlike the other metrics it must
-- accept NEGATIVE values, and it must not sample the '-' placeholder.
--
-- ASCII only.
-- ==================================================================

DROP VIEW IF EXISTS v_headset_full;
DROP VIEW IF EXISTS v_headset_status;

ALTER TABLE headset_status ADD COLUMN battery_power TEXT NOT NULL DEFAULT '-';

CREATE VIEW v_headset_status AS
SELECT CAST(headset_id AS TEXT)                     AS ID,
       CASE ping     WHEN 1 THEN 'True' ELSE 'False' END AS Ping,
       CASE adb_wifi WHEN 1 THEN 'True' ELSE 'False' END AS ADBWifi,
       battery                                      AS Battery,
       charging                                     AS Charging,
       charging_wattage                             AS ChargingWattage,
       battery_power                                AS BatteryPower,
       temp                                         AS Temp,
       cpu_temp                                     AS CpuTemp,
       gpu_temp                                     AS GpuTemp,
       skin_temp                                    AS SkinTemp,
       battery_controller_left                      AS BatteryControllerLeft,
       battery_controller_right                     AS BatteryControllerRight,
       power_state                                  AS PowerState,
       time_remaining_min                           AS TimeRemainingMin,
       adb_transport                                AS AdbTransport,
       adb_wifi_mode                                AS AdbWifiMode,
       scrcpy                                       AS SCRCPY,
       running_app                                  AS RunningApp,
       running_app_icon                             AS RunningAppIcon,
       updated_at                                   AS UpdatedAt
FROM headset_status;

CREATE VIEW v_headset_full AS
SELECT h.ID, h.Name, h.IPAddress, h.scrcpy_AutoRestart, h.Record, h.ScrcpyProfile,
       h.Brand, h.Model, h.SerialNumber, h.SortOrder,
       s.Ping, s.ADBWifi, s.Battery, s.Charging, s.ChargingWattage, s.BatteryPower, s.Temp,
       s.CpuTemp, s.GpuTemp, s.SkinTemp,
       s.BatteryControllerLeft, s.BatteryControllerRight, s.PowerState,
       s.TimeRemainingMin, s.AdbTransport, s.AdbWifiMode, s.SCRCPY, s.RunningApp, s.RunningAppIcon
FROM v_headsets h
JOIN v_headset_status s ON s.ID = h.ID;

CREATE TRIGGER trg_status_battpower_sample
AFTER UPDATE OF battery_power ON headset_status
WHEN (NEW.battery_power GLOB '[0-9]*' OR NEW.battery_power GLOB '-[0-9]*')
 AND NEW.battery_power <> OLD.battery_power
BEGIN
    UPDATE metric_history
       SET value = CAST(REPLACE(NEW.battery_power, ',', '.') AS REAL)
     WHERE headset_id = NEW.headset_id AND metric = 'batt_power'
       AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now');

    INSERT INTO metric_history(headset_id, metric, ts, value)
    SELECT NEW.headset_id, 'batt_power', strftime('%Y-%m-%dT%H:%M:%SZ','now'),
           CAST(REPLACE(NEW.battery_power, ',', '.') AS REAL)
     WHERE NOT EXISTS (SELECT 1 FROM metric_history
                        WHERE headset_id = NEW.headset_id AND metric = 'batt_power'
                          AND ts = strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;
