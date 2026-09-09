-- One headset's installed-app cache, aliased to the legacy
-- <Name>_installed_apps.csv header names. Addressed by permanent headset id,
-- never by the mutable display name the filename used to carry.
SELECT package_name    AS PackageName,
       version         AS Version,
       pending_version AS PendingVersion,
       store_version   AS StoreVersion,
       size_bytes      AS SizeBytes
FROM headset_installed_apps
WHERE headset_id = @headset_id
ORDER BY package_name COLLATE NOCASE;
