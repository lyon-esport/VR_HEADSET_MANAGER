-- One headset's favourite apps in the operator's chosen order.
--
-- sort_order carries what used to be implicit CSV row order. DisplayName
-- prefers the value stored on the favourite row (the CSV had its own copy and
-- the operator may have edited it), falling back to the catalogue, then to the
-- package name. LocalIconPath only ever came from the catalogue.
SELECT f.package_name AS PackageName,
       COALESCE(NULLIF(f.display_name, ''), NULLIF(c.display_name, ''), f.package_name) AS DisplayName,
       COALESCE(c.local_icon_path, '') AS LocalIconPath,
       COALESCE(c.icon_url, '')        AS IconUrl
FROM headset_favorite_apps f
LEFT JOIN app_catalog c ON c.package_name = f.package_name
WHERE f.headset_id = @headset_id
ORDER BY f.sort_order, f.package_name COLLATE NOCASE;
