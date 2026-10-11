-- Close a recording once its session ended.
-- codec/width/height keep their previous value when the media probe failed and
-- passed an empty/null value, so a failed probe never erases known data.
UPDATE recordings
   SET ended_at     = @ended_at,
       duration_sec = @duration_sec,
       size_bytes   = @size_bytes,
       codec        = COALESCE(NULLIF(@codec, ''), codec),
       width        = COALESCE(NULLIF(@width, 0), width),
       height       = COALESCE(NULLIF(@height, 0), height),
       status       = @status
 WHERE file_path = @file_path;