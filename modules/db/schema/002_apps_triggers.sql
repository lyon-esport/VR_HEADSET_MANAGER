-- ==================================================================
-- VR HEADSET MANAGER - apps change counters (migration 002)
--
-- 001 gave headset_installed_apps and headset_favorite_apps an AFTER
-- INSERT and an AFTER DELETE counter trigger, but no AFTER UPDATE.
-- Both installed.insert and favorites.insert are upserts
-- (ON CONFLICT ... DO UPDATE), so a row that changes IN PLACE - a new
-- version for an app that is already installed, a favourite that moves
-- position - left the counter untouched. Any consumer that caches on
-- Get-DbTableVersion would then serve that stale copy forever.
--
-- The other tables with an upsert path (headsets, kiosks, timers,
-- agent reports) already have their AFTER UPDATE trigger in 001; these
-- two were the omission.
--
-- ASCII only. Applied by Update-DatabaseSchema; PRAGMA user_version
-- becomes 002 afterwards.
-- ==================================================================

CREATE TRIGGER IF NOT EXISTS trg_installed_upd AFTER UPDATE ON headset_installed_apps
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'installed_apps';
END;

CREATE TRIGGER IF NOT EXISTS trg_favorites_upd AFTER UPDATE ON headset_favorite_apps
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'favorite_apps';
END;
