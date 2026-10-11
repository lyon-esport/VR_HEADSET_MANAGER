-- ==================================================================
-- VR HEADSET MANAGER - recordings catalogue (migration 008)
--
-- One row per recording file written by a headset stream (ADR-0029). The
-- file on disk stays the source of truth for the video; this table is the
-- index the Recordings page browses, plus the two things a file cannot
-- carry: the operator's keep flag and note.
--
-- Design points:
--   * file_path is UNIQUE and is the upsert key (recordings.insert), so a
--     rescan or a restart never duplicates a row and never resets keep/note.
--   * headset_id is ON DELETE SET NULL, NOT CASCADE: removing a headset from
--     the registry must not make its recordings vanish from the catalogue.
--     headset_name / safe_name keep the row addressable afterwards.
--   * started_at / ended_at are LOCAL time 'yyyy-MM-ddTHH:mm:ss' (the file
--     name carries local time; the page groups by local day).
--   * status: 'recording' | 'done' | 'interrupted'. source: 'live' | 'scan'.
--
-- The change counter 'recordings' follows the 001/004 pattern: one trigger per
-- operation, so a consumer caching on the counter never misses a delete.
--
-- ASCII only.
-- ==================================================================

CREATE TABLE IF NOT EXISTS recordings (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    headset_id     INTEGER NULL REFERENCES headsets(id) ON DELETE SET NULL,
    headset_name   TEXT    NOT NULL DEFAULT '',
    safe_name      TEXT    NOT NULL,
    file_path      TEXT    NOT NULL UNIQUE,
    rel_path       TEXT    NOT NULL DEFAULT '',
    started_at     TEXT    NOT NULL,
    ended_at       TEXT    NULL,
    duration_sec   REAL    NULL,
    size_bytes     INTEGER NOT NULL DEFAULT 0,
    status         TEXT    NOT NULL DEFAULT 'recording',
    source         TEXT    NOT NULL DEFAULT 'live',
    keep           INTEGER NOT NULL DEFAULT 0,
    note           TEXT    NULL,
    model          TEXT    NOT NULL DEFAULT '',
    scrcpy_profile TEXT    NOT NULL DEFAULT '',
    view           TEXT    NOT NULL DEFAULT '',
    eye            TEXT    NOT NULL DEFAULT '',
    fps            INTEGER NULL,
    bitrate_mbps   INTEGER NULL,
    max_size       INTEGER NULL,
    codec          TEXT    NOT NULL DEFAULT '',
    width          INTEGER NULL,
    height         INTEGER NULL,
    capture_mode   TEXT    NOT NULL DEFAULT '',
    eye_merge      INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS ix_recordings_name_start ON recordings(safe_name, started_at);
CREATE INDEX IF NOT EXISTS ix_recordings_status     ON recordings(status);
CREATE INDEX IF NOT EXISTS ix_recordings_start      ON recordings(started_at);

INSERT OR IGNORE INTO db_versions(name) VALUES ('recordings');

CREATE TRIGGER IF NOT EXISTS trg_recordings_ins AFTER INSERT ON recordings
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'recordings';
END;

CREATE TRIGGER IF NOT EXISTS trg_recordings_upd AFTER UPDATE ON recordings
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'recordings';
END;

CREATE TRIGGER IF NOT EXISTS trg_recordings_del AFTER DELETE ON recordings
BEGIN
    UPDATE db_versions SET version = version + 1 WHERE name = 'recordings';
END;