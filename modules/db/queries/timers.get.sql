-- One headset's timer configuration.
SELECT CAST(headset_id AS TEXT) AS HeadsetID,
       minutes AS Minutes,
       seconds AS Seconds,
       mode    AS Mode
FROM headset_timers
WHERE headset_id = @headset_id;
