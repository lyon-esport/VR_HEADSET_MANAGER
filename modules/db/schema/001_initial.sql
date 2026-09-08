-- ==================================================================
-- VR HEADSET MANAGER - initial schema (migration 001)
--
-- Replaces the flat CSV/JSON files under data\ (see ADR-0017, which
-- supersedes ADR-0010). Applied by Update-DatabaseSchema inside one
-- transaction; PRAGMA user_version is set to 001 afterwards.
--
-- Conventions
--  * snake_case columns in the tables; the VIEWS re-alias them to the
--    legacy CSV header names, so existing PowerShell consumers keep the
--    property names they already use.
--  * booleans are INTEGER 0/1 in tables and 'True'/'False' TEXT in views,
--    because every caller reads them through ConvertTo-BoolField.
--  * ids are cast to TEXT in views, because callers do loose compares
--    ($_.ID -eq $ID) and use [string]$h.ID as hashtable keys.
--  * timestamps are ISO-8601 UTC text.
--  * ASCII only.
-- ==================================================================


-- ------------------------------------------------------------------
-- Meta
-- ------------------------------------------------------------------

-- One row per applied migration. PRAGMA user_version carries the same
-- number; this table keeps the history and when it was applied.
CREATE TABLE IF NOT EXISTS schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Per-table change counter, bumped by the triggers at the bottom of this
-- file. Replaces the file-mtime caches the web server used to keep: one
-- scalar read tells a caller whether its cached copy is still current.
CREATE TABLE IF NOT EXISTS db_versions (
    name    TEXT PRIMARY KEY,
    version INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO db_versions(name) VALUES
    ('headsets'), ('kiosks'), ('headset_status'), ('kiosk_status'),
    ('app_catalog'), ('app_kv'), ('headset_timers'), ('installed_apps'),
    ('favorite_apps'), ('discovered_headsets'), ('kiosk_agent_reports');


-- ------------------------------------------------------------------
-- Headset registry  (was data\known_headsets.csv)
--
-- The permanent identity of a headset. id is assigned once and NEVER
-- resequenced by position; sort_order carries the display order that used
-- to be implicit in CSV row order. serial_number is the healing key used
-- by Set-HeadsetIdentity; ip_address is volatile and unique, including the
-- 127.0.0.N placeholders Get-NextUnknownIp hands out when a row loses its
-- address to another headset.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS headsets (
    id                  INTEGER PRIMARY KEY,
    name                TEXT    NOT NULL,
    ip_address          TEXT    NOT NULL UNIQUE,
    scrcpy_auto_restart INTEGER NOT NULL DEFAULT 1 CHECK (scrcpy_auto_restart IN (0,1)),
    record              INTEGER NOT NULL DEFAULT 0 CHECK (record IN (0,1)),
    scrcpy_profile      TEXT    NOT NULL DEFAULT '',
    brand               TEXT    NOT NULL DEFAULT '',
    model               TEXT    NOT NULL DEFAULT '',
    serial_number       TEXT    NOT NULL DEFAULT '',
    sort_order          INTEGER NOT NULL DEFAULT 0,
    created_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
-- Partial unique index: a serial must be unique when known, but several rows
-- may legitimately have no serial yet (manual IP-only adds).
CREATE UNIQUE INDEX IF NOT EXISTS ux_headsets_serial ON headsets(serial_number) WHERE serial_number <> '';
CREATE INDEX IF NOT EXISTS ix_headsets_sort ON headsets(sort_order, id);


-- ------------------------------------------------------------------
-- Live headset status  (was data\known_headsets_infos.csv)
--
-- ADR-0016: keyed on headset id, carrying NO identity columns. Truncated
-- and reseeded by the main process at every startup, so stale state cannot
-- survive a restart. battery_history stays the packed "ts=pct|ts=pct"
-- string the poll runspaces preload and append to.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS headset_status (
    headset_id               INTEGER PRIMARY KEY REFERENCES headsets(id) ON DELETE CASCADE,
    ping                     INTEGER NOT NULL DEFAULT 0 CHECK (ping IN (0,1)),
    adb_wifi                 INTEGER NOT NULL DEFAULT 0 CHECK (adb_wifi IN (0,1)),
    battery                  TEXT NOT NULL DEFAULT '-',
    charging                 TEXT NOT NULL DEFAULT '-',
    charging_wattage         TEXT NOT NULL DEFAULT '-',
    temp                     TEXT NOT NULL DEFAULT '-',
    battery_controller_left  TEXT NOT NULL DEFAULT '-',
    battery_controller_right TEXT NOT NULL DEFAULT '-',
    power_state              TEXT NOT NULL DEFAULT '-',
    time_remaining_min       TEXT NOT NULL DEFAULT '-',
    battery_history          TEXT NOT NULL DEFAULT '',
    scrcpy                   TEXT NOT NULL DEFAULT '-',
    running_app              TEXT NOT NULL DEFAULT '-',
    running_app_icon         TEXT NOT NULL DEFAULT '',
    updated_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Durable battery samples. The packed string above is capped at a handful of
-- entries for the overlay; this table keeps a real history per headset,
-- pruned to the last 100 samples by trigger.
CREATE TABLE IF NOT EXISTS battery_history (
    headset_id INTEGER NOT NULL REFERENCES headsets(id) ON DELETE CASCADE,
    ts         TEXT    NOT NULL,
    pct        INTEGER NOT NULL,
    PRIMARY KEY (headset_id, ts)
) WITHOUT ROWID;


-- ------------------------------------------------------------------
-- Kiosk registry  (was data\known_kiosks.csv)
--
-- Unlike the CSV era, ids are PERMANENT here: Save-Kiosks used to
-- resequence 1..N on every save, which made an id meaningless as a handle.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kiosks (
    id             INTEGER PRIMARY KEY,
    name           TEXT    NOT NULL,
    ip_address     TEXT    NOT NULL UNIQUE,
    port           INTEGER NOT NULL DEFAULT 9222,
    pushed_url     TEXT    NOT NULL DEFAULT '',
    last_pushed_at TEXT    NOT NULL DEFAULT '',
    sort_order     INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Live kiosk reachability, written only by the monitor loop
-- (was data\kiosks_status.json). Truncated at startup.
CREATE TABLE IF NOT EXISTS kiosk_status (
    ip_address  TEXT NOT NULL PRIMARY KEY,
    port        INTEGER,
    reachable   INTEGER NOT NULL DEFAULT 0 CHECK (reachable IN (0,1)),
    latency_ms  INTEGER,
    cdp_open    INTEGER NOT NULL DEFAULT 0 CHECK (cdp_open IN (0,1)),
    current_url TEXT NOT NULL DEFAULT '',
    extra_json  TEXT NOT NULL DEFAULT '{}',
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Latest self-report from each advanced kiosk agent
-- (was data\kiosks_agent.json). Written only by the agent-report endpoint.
-- Every text field arrives from an unauthenticated LAN device and is length
-- capped by Get-TruncatedText before it reaches here.
CREATE TABLE IF NOT EXISTS kiosk_agent_reports (
    ip_address           TEXT NOT NULL PRIMARY KEY,
    machine_id           TEXT,
    hostname             TEXT,
    os                   TEXT,
    os_family            TEXT,
    interface_type       TEXT,
    interface_name       TEXT,
    link_speed_mbps      INTEGER,
    browser              TEXT,
    browser_running      INTEGER,
    cdp_port             INTEGER,
    current_url          TEXT,
    uptime_sec           INTEGER,
    auto_restart_browser INTEGER,
    agent_version        TEXT,
    last_ack             TEXT,
    last_report_at       TEXT NOT NULL
);

-- Deliver-once operator command queue (was data\kiosk_commands\*.json, one
-- file per command). The claim is a single DELETE ... RETURNING, so two
-- concurrent claimers cannot both receive the same command.
CREATE TABLE IF NOT EXISTS kiosk_commands (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ip_address  TEXT    NOT NULL,
    cmd         TEXT    NOT NULL CHECK (cmd IN ('reboot','shutdown','browser-restart','agent-stop')),
    nonce       INTEGER NOT NULL UNIQUE,
    delay_sec   INTEGER NOT NULL DEFAULT 5,
    queued_at   TEXT    NOT NULL,
    queued_unix INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_kiosk_commands_ip ON kiosk_commands(ip_address, id);

-- IPs the operator explicitly removed; a still-running agent may not
-- silently re-add itself (was data\kiosk_autoadd_ignore.json).
CREATE TABLE IF NOT EXISTS kiosk_autoadd_ignore (
    ip_address TEXT NOT NULL PRIMARY KEY,
    added_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);


-- ------------------------------------------------------------------
-- Discovery  (was discovered_headsets.json / headset_discovery_ignore.json)
--
-- Devices the LAN sweep found whose serial is not in the registry, awaiting
-- an operator decision. The ignore list is keyed on SERIAL, never IP, so a
-- forgotten device stays forgotten across a DHCP change.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS discovered_headsets (
    serial_number TEXT NOT NULL PRIMARY KEY,
    ip_address    TEXT NOT NULL,
    model         TEXT NOT NULL DEFAULT '',
    brand         TEXT NOT NULL DEFAULT '',
    first_seen    TEXT NOT NULL,
    last_seen     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS headset_discovery_ignore (
    serial_number TEXT NOT NULL PRIMARY KEY,
    added_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);


-- ------------------------------------------------------------------
-- Apps
-- ------------------------------------------------------------------

-- Global package -> display name / icon lookup (was data\known_apps.csv).
-- Seeded from templates\data\known_apps.csv, which stays a shipped file.
CREATE TABLE IF NOT EXISTS app_catalog (
    package_name    TEXT NOT NULL PRIMARY KEY,
    display_name    TEXT NOT NULL DEFAULT '',
    icon_url        TEXT NOT NULL DEFAULT '',
    local_icon_path TEXT NOT NULL DEFAULT '',
    third_party     INTEGER NOT NULL DEFAULT 1 CHECK (third_party IN (0,1)),
    latest_version  TEXT NOT NULL DEFAULT '',
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Per-headset installed app cache (was data\<Name>_installed_apps.csv).
-- Keyed on headset id, not on the mutable display name: renaming a headset
-- no longer renames a file, and a poll runspace holding a superseded
-- headset object can no longer write another headset's cache.
CREATE TABLE IF NOT EXISTS headset_installed_apps (
    headset_id      INTEGER NOT NULL REFERENCES headsets(id) ON DELETE CASCADE,
    package_name    TEXT    NOT NULL,
    version         TEXT    NOT NULL DEFAULT '',
    pending_version TEXT    NOT NULL DEFAULT '',
    store_version   TEXT    NOT NULL DEFAULT '',
    size_bytes      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (headset_id, package_name)
) WITHOUT ROWID;

-- Per-headset favourites (was data\<Name>_favorite_apps.csv). sort_order
-- carries the operator's chosen order, previously implicit in row order.
CREATE TABLE IF NOT EXISTS headset_favorite_apps (
    headset_id   INTEGER NOT NULL REFERENCES headsets(id) ON DELETE CASCADE,
    package_name TEXT    NOT NULL,
    display_name TEXT    NOT NULL DEFAULT '',
    sort_order   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (headset_id, package_name)
) WITHOUT ROWID;


-- ------------------------------------------------------------------
-- Timers  (was data\timer.csv)
--
-- Only the CONFIG lives here. The live countdown stays in
-- website\timer\<Name>[timer].txt, which is served as a static file to
-- remote OBS browser sources and is written by a job that loads no modules.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS headset_timers (
    headset_id INTEGER PRIMARY KEY REFERENCES headsets(id) ON DELETE CASCADE,
    minutes    INTEGER NOT NULL DEFAULT 0,
    seconds    INTEGER NOT NULL DEFAULT 0,
    mode       TEXT    NOT NULL DEFAULT 'dec' CHECK (mode IN ('dec','inc'))
);


-- ------------------------------------------------------------------
-- Video quality automation history  (was data\vqa_history.csv)
--
-- One row per recommendation cycle. json holds the full recommendation
-- object the console and web UI replay. Pruned to the last 5000 rows.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vqa_history (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           TEXT NOT NULL,
    cpu_pct      INTEGER,
    gpu_pct      INTEGER,
    scrcpy_count INTEGER,
    client_count INTEGER,
    direction    TEXT,
    reason       TEXT,
    json         TEXT
);


-- ------------------------------------------------------------------
-- Key/value snapshots  (was six separate JSON files)
--
-- Keys in use: fw_state, computer_monitoring, vqa_recommendation,
-- vqa_originals, vqa_applied, vqa_cooldown, legacy_import_log.
-- Values are JSON text, so the shapes stay exactly what the existing
-- readers expect.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS app_kv (
    key        TEXT NOT NULL PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);


-- ==================================================================
-- Views: the compatibility contract
--
-- Legacy CSV header names, booleans as 'True'/'False', ids as TEXT.
-- Anything a PowerShell caller reads goes through one of these.
-- ==================================================================

DROP VIEW IF EXISTS v_headsets;
CREATE VIEW v_headsets AS
SELECT CAST(id AS TEXT)                                          AS ID,
       name                                                      AS Name,
       ip_address                                                AS IPAddress,
       CASE scrcpy_auto_restart WHEN 1 THEN 'True' ELSE 'False' END AS scrcpy_AutoRestart,
       CASE record              WHEN 1 THEN 'True' ELSE 'False' END AS Record,
       scrcpy_profile                                            AS ScrcpyProfile,
       brand                                                     AS Brand,
       model                                                     AS Model,
       serial_number                                             AS SerialNumber,
       sort_order                                                AS SortOrder
FROM headsets;

DROP VIEW IF EXISTS v_headset_status;
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
       battery_history                              AS BatteryHistory,
       scrcpy                                       AS SCRCPY,
       running_app                                  AS RunningApp,
       running_app_icon                             AS RunningAppIcon,
       updated_at                                   AS UpdatedAt
FROM headset_status;

-- Registry joined to live status on ID (ADR-0016), in display order.
DROP VIEW IF EXISTS v_headset_full;
CREATE VIEW v_headset_full AS
SELECT h.ID, h.Name, h.IPAddress, h.scrcpy_AutoRestart, h.Record, h.ScrcpyProfile,
       h.Brand, h.Model, h.SerialNumber, h.SortOrder,
       s.Ping, s.ADBWifi, s.Battery, s.Charging, s.ChargingWattage, s.Temp,
       s.BatteryControllerLeft, s.BatteryControllerRight, s.PowerState,
       s.TimeRemainingMin, s.BatteryHistory, s.SCRCPY, s.RunningApp, s.RunningAppIcon
FROM v_headsets h
JOIN v_headset_status s ON s.ID = h.ID;

DROP VIEW IF EXISTS v_kiosks;
CREATE VIEW v_kiosks AS
SELECT CAST(id AS TEXT)   AS ID,
       name               AS Name,
       ip_address         AS IPAddress,
       CAST(port AS TEXT) AS Port,
       pushed_url         AS PushedURL,
       last_pushed_at     AS LastPushedAt,
       sort_order         AS SortOrder
FROM kiosks;

DROP VIEW IF EXISTS v_app_catalog;
CREATE VIEW v_app_catalog AS
SELECT package_name    AS PackageName,
       display_name    AS DisplayName,
       icon_url        AS IconUrl,
       local_icon_path AS LocalIconPath,
       CASE third_party WHEN 1 THEN 'True' ELSE 'False' END AS ThirdParty,
       latest_version  AS LatestVersion
FROM app_catalog;

-- Pending proposals only: a serial that has since become known, or that the
-- operator forgot, is filtered out here as well as pruned by trigger.
DROP VIEW IF EXISTS v_discovered_pending;
CREATE VIEW v_discovered_pending AS
SELECT d.serial_number AS SerialNumber,
       d.ip_address    AS IPAddress,
       d.model         AS Model,
       d.brand         AS Brand,
       d.first_seen    AS FirstSeen,
       d.last_seen     AS LastSeen
FROM discovered_headsets d
WHERE d.serial_number NOT IN (SELECT serial_number FROM headsets WHERE serial_number <> '')
  AND d.serial_number NOT IN (SELECT serial_number FROM headset_discovery_ignore);


-- ==================================================================
-- Triggers
-- ==================================================================

-- ---- change counters + updated_at -------------------------------
-- The updated_at guard (NEW.updated_at = OLD.updated_at) lets a caller set
-- the timestamp explicitly without the trigger overwriting it.

CREATE TRIGGER IF NOT EXISTS trg_headsets_ins AFTER INSERT ON headsets
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headsets';
END;
CREATE TRIGGER IF NOT EXISTS trg_headsets_upd AFTER UPDATE ON headsets
BEGIN
    UPDATE headsets SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
     WHERE id = NEW.id AND NEW.updated_at = OLD.updated_at;
    UPDATE db_versions SET version = version + 1 WHERE name = 'headsets';
END;
CREATE TRIGGER IF NOT EXISTS trg_headsets_del AFTER DELETE ON headsets
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headsets';
END;

CREATE TRIGGER IF NOT EXISTS trg_kiosks_ins AFTER INSERT ON kiosks
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosks';
END;
CREATE TRIGGER IF NOT EXISTS trg_kiosks_upd AFTER UPDATE ON kiosks
BEGIN
    UPDATE kiosks SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
     WHERE id = NEW.id AND NEW.updated_at = OLD.updated_at;
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosks';
END;
CREATE TRIGGER IF NOT EXISTS trg_kiosks_del AFTER DELETE ON kiosks
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosks';
END;

CREATE TRIGGER IF NOT EXISTS trg_status_ins AFTER INSERT ON headset_status
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headset_status';
END;
CREATE TRIGGER IF NOT EXISTS trg_status_upd AFTER UPDATE ON headset_status
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headset_status';
END;
CREATE TRIGGER IF NOT EXISTS trg_status_del AFTER DELETE ON headset_status
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headset_status';
END;

CREATE TRIGGER IF NOT EXISTS trg_kiosk_status_ins AFTER INSERT ON kiosk_status
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosk_status';
END;
CREATE TRIGGER IF NOT EXISTS trg_kiosk_status_upd AFTER UPDATE ON kiosk_status
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosk_status';
END;

CREATE TRIGGER IF NOT EXISTS trg_catalog_ins AFTER INSERT ON app_catalog
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'app_catalog';
END;
CREATE TRIGGER IF NOT EXISTS trg_catalog_upd AFTER UPDATE ON app_catalog
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'app_catalog';
END;
CREATE TRIGGER IF NOT EXISTS trg_catalog_del AFTER DELETE ON app_catalog
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'app_catalog';
END;

CREATE TRIGGER IF NOT EXISTS trg_kv_ins AFTER INSERT ON app_kv
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'app_kv';
END;
CREATE TRIGGER IF NOT EXISTS trg_kv_upd AFTER UPDATE ON app_kv
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'app_kv';
END;

CREATE TRIGGER IF NOT EXISTS trg_timers_ins AFTER INSERT ON headset_timers
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headset_timers';
END;
CREATE TRIGGER IF NOT EXISTS trg_timers_upd AFTER UPDATE ON headset_timers
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headset_timers';
END;

CREATE TRIGGER IF NOT EXISTS trg_installed_ins AFTER INSERT ON headset_installed_apps
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'installed_apps';
END;
CREATE TRIGGER IF NOT EXISTS trg_installed_del AFTER DELETE ON headset_installed_apps
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'installed_apps';
END;

CREATE TRIGGER IF NOT EXISTS trg_favorites_ins AFTER INSERT ON headset_favorite_apps
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'favorite_apps';
END;
CREATE TRIGGER IF NOT EXISTS trg_favorites_del AFTER DELETE ON headset_favorite_apps
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'favorite_apps';
END;

CREATE TRIGGER IF NOT EXISTS trg_agent_ins AFTER INSERT ON kiosk_agent_reports
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosk_agent_reports';
END;
CREATE TRIGGER IF NOT EXISTS trg_agent_upd AFTER UPDATE ON kiosk_agent_reports
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosk_agent_reports';
END;

CREATE TRIGGER IF NOT EXISTS trg_discovered_ins AFTER INSERT ON discovered_headsets
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'discovered_headsets';
END;
CREATE TRIGGER IF NOT EXISTS trg_discovered_del AFTER DELETE ON discovered_headsets
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'discovered_headsets';
END;


-- ---- battery history -------------------------------------------
-- Sample on every numeric battery change, then keep only the newest 100
-- rows for that headset. GLOB '[0-9]*' skips the '-' placeholder.

CREATE TRIGGER IF NOT EXISTS trg_status_battery_sample
AFTER UPDATE OF battery ON headset_status
WHEN NEW.battery GLOB '[0-9]*' AND NEW.battery <> OLD.battery
BEGIN
    INSERT OR REPLACE INTO battery_history(headset_id, ts, pct)
    VALUES (NEW.headset_id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), CAST(NEW.battery AS INTEGER));
    DELETE FROM battery_history
     WHERE headset_id = NEW.headset_id
       AND ts NOT IN (SELECT ts FROM battery_history
                       WHERE headset_id = NEW.headset_id
                       ORDER BY ts DESC LIMIT 100);
END;


-- ---- discovery pruning ------------------------------------------
-- A proposal disappears the moment its serial becomes known or forgotten,
-- so the pending list cannot show a device the operator already dealt with.

CREATE TRIGGER IF NOT EXISTS trg_discovery_prune_on_known
AFTER INSERT ON headsets WHEN NEW.serial_number <> ''
BEGIN
    DELETE FROM discovered_headsets WHERE serial_number = NEW.serial_number;
END;

CREATE TRIGGER IF NOT EXISTS trg_discovery_prune_on_serial
AFTER UPDATE OF serial_number ON headsets WHEN NEW.serial_number <> ''
BEGIN
    DELETE FROM discovered_headsets WHERE serial_number = NEW.serial_number;
END;

CREATE TRIGGER IF NOT EXISTS trg_discovery_prune_on_ignore
AFTER INSERT ON headset_discovery_ignore
BEGIN
    DELETE FROM discovered_headsets WHERE serial_number = NEW.serial_number;
END;


-- ---- vqa history pruning ----------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_vqa_history_prune
AFTER INSERT ON vqa_history
BEGIN
    DELETE FROM vqa_history WHERE id <= NEW.id - 5000;
END;
