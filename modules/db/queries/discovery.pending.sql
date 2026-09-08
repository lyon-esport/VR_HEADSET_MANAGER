-- Devices awaiting an operator decision. The view already excludes serials
-- that have since become known or been forgotten, so this needs no pruning
-- pass of its own - which is what the JSON version had to do on every read.
SELECT SerialNumber, IPAddress, Model, Brand, FirstSeen, LastSeen
FROM v_discovered_pending;
