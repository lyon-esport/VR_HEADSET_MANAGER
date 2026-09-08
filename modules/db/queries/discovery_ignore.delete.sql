-- Un-forget a device. An explicit manual add clears the entry, so the operator
-- never has to know the list exists to undo a mistake.
DELETE FROM headset_discovery_ignore WHERE serial_number = @serial_number;
