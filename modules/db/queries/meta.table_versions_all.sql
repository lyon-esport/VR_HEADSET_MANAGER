-- Every table change counter in one read.
-- The SSE pump polls several counters a few times per second; asking for them one at
-- a time would be one round trip per counter per tick, for data that all lives in a
-- single small table. Used by Get-DbTableVersionMap.
SELECT name, version FROM db_versions;
