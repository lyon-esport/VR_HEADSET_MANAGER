-- Remove one favourite from one headset.
DELETE FROM headset_favorite_apps
WHERE headset_id = @headset_id AND package_name = @package_name;
