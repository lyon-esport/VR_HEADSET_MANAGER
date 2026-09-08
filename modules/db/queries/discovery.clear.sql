-- Drop every proposal. Used only by Save-PendingDiscoveredHeadsets, which
-- replaces the whole set the way overwriting the JSON file used to.
DELETE FROM discovered_headsets;
