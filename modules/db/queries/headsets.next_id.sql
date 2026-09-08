-- Next free headset id: max + 1. Ids are permanent identities and are never
-- reused, so a freed id stays free.
SELECT COALESCE(MAX(id), 0) + 1 FROM headsets;
