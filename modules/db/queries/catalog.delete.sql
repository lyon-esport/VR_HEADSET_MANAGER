-- Remove one package from the catalogue. The per-headset installed and
-- favourite rows are NOT touched: they record what is on a device, which is
-- independent of whether we hold display metadata for it.
DELETE FROM app_catalog WHERE package_name = @package_name;
