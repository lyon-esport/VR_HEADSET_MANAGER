-- ==================================================================
-- VR HEADSET MANAGER - complete the change-counter triggers (migration 004)
--
-- db_versions is the cache-invalidation mechanism: a consumer reads the
-- counter for a table and re-reads the rows only when it moved. A counter that
-- cannot report one of its own operations is worse than having no counter at
-- all, because the consumer caches on it and then serves that stale copy
-- forever, with nothing logged and nothing failing.
--
-- Migration 002 already fixed this for the two per-headset app tables. This
-- completes the remaining five gaps, which the new static check in
-- Test-DbStatic.ps1 now makes impossible to reintroduce:
--
--   discovered_headsets  - had INSERT and DELETE but no UPDATE, and its only
--                          writer (discovery.upsert) is an upsert. Refreshing
--                          LastSeen on an already-proposed device moved nothing.
--   app_kv               - had INSERT and UPDATE but no DELETE, and
--                          Remove-DbKeyValue is called three times by the video
--                          quality automation (vqa_cooldown, vqa_originals).
--   headset_timers       - no DELETE. Rows disappear by ON DELETE CASCADE when
--                          a headset is removed.
--   kiosk_status         - no DELETE. kiosk_status.truncate empties the table at
--                          every startup.
--   kiosk_agent_reports  - no DELETE.
--
-- Only headset_status is cached on its counter today, so none of these is
-- currently visible. They are fixed now precisely because the next consumer to
-- use a counter would inherit a silent bug.
--
-- ASCII only.
-- ==================================================================

CREATE TRIGGER IF NOT EXISTS trg_discovered_upd AFTER UPDATE ON discovered_headsets
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'discovered_headsets';
END;

CREATE TRIGGER IF NOT EXISTS trg_kv_del AFTER DELETE ON app_kv
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'app_kv';
END;

CREATE TRIGGER IF NOT EXISTS trg_timers_del AFTER DELETE ON headset_timers
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'headset_timers';
END;

CREATE TRIGGER IF NOT EXISTS trg_kiosk_status_del AFTER DELETE ON kiosk_status
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosk_status';
END;

CREATE TRIGGER IF NOT EXISTS trg_agent_del AFTER DELETE ON kiosk_agent_reports
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'kiosk_agent_reports';
END;
