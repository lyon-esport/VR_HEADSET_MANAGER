-- Change counter of one table, bumped by triggers on every write.
-- Used to invalidate caches instead of the file mtimes of the CSV era.
SELECT version FROM db_versions WHERE name = @name;
