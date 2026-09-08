-- Stop proposing one device, by serial.
DELETE FROM discovered_headsets WHERE serial_number = @serial_number;
