-- One headset's installed apps with the catalogue metadata grafted on.
--
-- The CSV era wrote DisplayName and IconUrl into the per-headset file, then
-- stopped when the file went to a lean schema - leaving readers that still
-- expected those columns (the console Launch-app menu) showing blanks. The
-- join restores them from the single place that owns them.
--
-- LEFT JOIN on purpose: a package installed on the headset but absent from the
-- catalogue must still be listed. DisplayName then falls back to the package
-- name, and ThirdParty to true, matching Get-AppInfoFromKnownApps' defaults.
SELECT i.package_name                            AS PackageName,
       i.version                                 AS Version,
       i.pending_version                         AS PendingVersion,
       i.store_version                           AS StoreVersion,
       i.size_bytes                              AS SizeBytes,
       COALESCE(NULLIF(c.display_name, ''), i.package_name) AS DisplayName,
       COALESCE(c.icon_url, '')                  AS IconUrl,
       COALESCE(c.local_icon_path, '')           AS LocalIconPath,
       CASE COALESCE(c.third_party, 1) WHEN 1 THEN 'True' ELSE 'False' END AS ThirdParty
FROM headset_installed_apps i
LEFT JOIN app_catalog c ON c.package_name = i.package_name
WHERE i.headset_id = @headset_id
ORDER BY DisplayName COLLATE NOCASE, i.package_name COLLATE NOCASE;
