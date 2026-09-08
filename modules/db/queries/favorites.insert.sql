-- One favourite-app row for a headset. sort_order carries the operator's
-- chosen order, previously implicit in CSV row order.
INSERT INTO headset_favorite_apps (headset_id, package_name, display_name, sort_order)
VALUES (@headset_id, @package_name, @display_name, @sort_order)
ON CONFLICT(headset_id, package_name) DO UPDATE SET
    display_name = excluded.display_name,
    sort_order   = excluded.sort_order;
