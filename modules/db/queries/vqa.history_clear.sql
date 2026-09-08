-- Truncate the recommendation history. Called at startup: history is
-- per-session, so a new run never inherits the previous one's decisions.
DELETE FROM vqa_history;
