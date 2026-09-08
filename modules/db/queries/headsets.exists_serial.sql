-- 1 when this serial is already registered. An empty serial is never a
-- duplicate: it means "not learned yet", not "the same device".
SELECT COUNT(*) FROM headsets WHERE serial_number <> '' AND serial_number = @serial_number;
