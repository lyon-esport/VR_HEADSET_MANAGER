-- Every proposal, including ones already superseded. The pending view is what
-- callers normally want; this is the raw table, for the -SkipPrune path.
SELECT serial_number AS SerialNumber,
       ip_address    AS IPAddress,
       model         AS Model,
       brand         AS Brand,
       first_seen    AS FirstSeen,
       last_seen     AS LastSeen
FROM discovered_headsets;
