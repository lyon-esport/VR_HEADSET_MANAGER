uPlot - vendored third-party library
====================================

Version : 1.6.32
Source  : https://github.com/leeoniya/uPlot
Files   : uPlot.iife.min.js (51 KB), uPlot.min.css (2 KB), LICENSE
Fetched : https://cdn.jsdelivr.net/npm/uplot@1.6.32/dist/
License : MIT (see LICENSE)

Why vendored and not loaded from a CDN
--------------------------------------
No page in website/ loads anything from an external host. This server routinely
runs on a LAN with no internet access (VR labs, showrooms), so a CDN <script>
would leave every chart blank exactly where the tool is used. The library is
committed to the repo for the same reason adb.exe / scrcpy.exe / mediamtx.exe
are committed under sources/.

Used by
-------
website/assets/battery_chart.js  - the only wrapper; do not call uPlot directly
                                   from a page.

Updating
--------
Download the new dist/uPlot.iife.min.js + dist/uPlot.min.css + LICENSE, replace
the files here, bump the Version line above, then re-test both call sites
(the hover sparkline on headsets_monitoring.html and battery_history.html)
with the machine disconnected from the internet.
