-- Append one video-quality recommendation cycle. A trigger prunes the table
-- to the most recent rows.
INSERT INTO vqa_history (ts, cpu_pct, gpu_pct, scrcpy_count, client_count,
                         direction, reason, json)
VALUES (@ts, @cpu_pct, @gpu_pct, @scrcpy_count, @client_count,
        @direction, @reason, @json);
