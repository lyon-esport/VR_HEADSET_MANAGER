-- ==================================================================
-- VR HEADSET MANAGER - WiFi ADB mode on the live status (migration 009)
--
-- ADR-0034 adds a second WiFi ADB mode next to classic "adb tcpip": ADB over
-- TLS ("Wireless debugging"), on a random port discovered over mDNS. The
-- transport badge (adb_transport, migration 007) still says USB or WiFi; this
-- column says WHICH WiFi mode the monitor is talking over:
--
--   Classic  the classic port (ADB.adbPort_default)
--   TLS      the published TLS endpoint of the headset
--   -        no WiFi ADB (unreachable, or reached over USB only)
--
-- Additive only: one column with a default, so the existing rows and the
-- startup seed (status.seed_missing) need nothing. The views are dropped and
-- recreated with the new column, the same dance as migrations 005 and 007
-- (SQLite refuses to alter a column set a view still references).
--
-- ASCII only.
-- ==================================================================

DROP VIEW IF EXISTS v_headset_full;
DROP VIEW IF EXISTS v_headset_status;

ALTER TABLE headset_status ADD COLUMN adb_wifi_mode TEXT NOT NULL DEFAULT '-';

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
       adb_wifi_mode                                AS AdbWifiMode,
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
       s.TimeRemainingMin, s.AdbTransport, s.AdbWifiMode, s.SCRCPY, s.RunningApp, s.RunningAppIcon
FROM v_headsets h
JOIN v_headset_status s ON s.ID = h.ID;
