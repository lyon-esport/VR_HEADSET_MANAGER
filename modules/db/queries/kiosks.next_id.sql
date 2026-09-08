-- Next free kiosk id: max + 1, never a row count. Ids are permanent now, so a
-- count would collide with an existing row as soon as anything is deleted.
SELECT COALESCE(MAX(id), 0) + 1 FROM kiosks;
