-- Clear one headset's favourites before rewriting them in order.
DELETE FROM headset_favorite_apps WHERE headset_id = @headset_id;
