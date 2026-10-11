-- Register (or refresh) one recording file.
-- Upsert on file_path so a rescan or a restart never duplicates a row. keep and
-- note are deliberately NOT in the update list (and id is untouched): they are
-- operator data, which INSERT OR REPLACE would have reset.
INSERT INTO recordings (headset_id, headset_name, safe_name, file_path, rel_path,
                        started_at, ended_at, duration_sec, size_bytes, status, source,
                        model, scrcpy_profile, view, eye, fps, bitrate_mbps, max_size,
                        codec, width, height, capture_mode, eye_merge)
VALUES (@headset_id, @headset_name, @safe_name, @file_path, @rel_path,
        @started_at, @ended_at, @duration_sec, @size_bytes, @status, @source,
        @model, @scrcpy_profile, @view, @eye, @fps, @bitrate_mbps, @max_size,
        @codec, @width, @height, @capture_mode, @eye_merge)
ON CONFLICT(file_path) DO UPDATE SET
    headset_id     = excluded.headset_id,
    headset_name   = excluded.headset_name,
    safe_name      = excluded.safe_name,
    rel_path       = excluded.rel_path,
    started_at     = excluded.started_at,
    ended_at       = excluded.ended_at,
    duration_sec   = excluded.duration_sec,
    size_bytes     = excluded.size_bytes,
    status         = excluded.status,
    source         = excluded.source,
    model          = excluded.model,
    scrcpy_profile = excluded.scrcpy_profile,
    view           = excluded.view,
    eye            = excluded.eye,
    fps            = excluded.fps,
    bitrate_mbps   = excluded.bitrate_mbps,
    max_size       = excluded.max_size,
    codec          = excluded.codec,
    width          = excluded.width,
    height         = excluded.height,
    capture_mode   = excluded.capture_mode,
    eye_merge      = excluded.eye_merge;