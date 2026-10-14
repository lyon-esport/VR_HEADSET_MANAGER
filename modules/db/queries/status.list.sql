-- Every live-status row, id-keyed with no identity columns (ADR-0016).
-- Column names and the 'True'/'False' booleans match what
-- known_headsets_infos.csv used to carry, so consumers need no change.
SELECT ID, Ping, ADBWifi, Battery, Charging, ChargingWattage, Temp,
       CpuTemp, GpuTemp, SkinTemp,
       BatteryControllerLeft, BatteryControllerRight, PowerState,
       TimeRemainingMin, AdbTransport, SCRCPY, RunningApp, RunningAppIcon
FROM v_headset_status;
