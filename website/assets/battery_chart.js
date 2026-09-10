/* battery_chart.js - the only wrapper around uPlot in this project.
 *
 * Two call sites share it so the step semantics, the colour thresholds and the
 * theme handling are defined once:
 *   - headsets_monitoring.html : mode 'mini', the 1h sparkline in the hover tooltip
 *   - battery_history.html     : mode 'full', the 24/12/3/1h page chart
 *
 * Data contract - the payload is the raw body of GET /api/battery-history:
 *   { ok, id, hours, retentionHours, nowUtc, samples: [ { ts, pct }, ... ] }
 *
 * Two things about that series matter and are handled here, not by callers:
 *
 *  1. It is a STEP function, not a line. A sample is only written when the level
 *     CHANGES, so between two samples the battery genuinely held its value -
 *     interpolating a slope between them would invent readings that never existed.
 *     Hence uPlot.paths.stepped and a synthetic tail point at nowUtc carrying the
 *     last known value, so the line reaches "now" instead of stopping at the last
 *     change.
 *
 *  2. The first sample is usually the seed row from BEFORE the window (see
 *     battery.window.sql). The x scale is therefore pinned to the requested window
 *     rather than to the data extent: a 24h window must read as 24 hours even when
 *     the only sample in it is one that predates it. uPlot clips the off-screen
 *     point and draws its segment into view, which is exactly the flat line wanted.
 *
 * uPlot bakes colours in at construction and does not follow CSS, so a theme change
 * means a rebuild - callers get that through BatteryChart.observeTheme().
 */
(function () {
  'use strict';

  /* Operator-configured battery bands (config.json Monitoring.thresholds), so the
   * graph agrees with the per-headset overlay and with vrhm_config.html instead of
   * inventing its own scale. Defaults mirror config_files_loader.ps1's own defaults,
   * so a failed fetch still colours the same way a default install does.
   *
   * Headset values only - the chart never plots controller levels, so
   * controllers_battery_* is deliberately not read here.
   *
   * Boundary convention follows headset_status.pshtml's applyBatteryClass()
   * (<= critical, < warning) because that is the code colouring the battery VALUE,
   * which is what this colours too. Note the PowerShell icon logic in the same
   * template uses < critical, so the two already disagree at exactly the critical
   * value; this matches the JS one rather than adding a third reading. */
  var thresholds = { warning: 40, critical: 30 };

  function setThresholds(t) {
    if (!t) return;
    var w = parseInt(t.warning, 10);
    var c = parseInt(t.critical, 10);
    if (!isNaN(w)) thresholds.warning = w;
    if (!isNaN(c)) thresholds.critical = c;
  }

  /* Reads the live thresholds once per page load. /api/config already returns the
   * whole config, so this needs no endpoint of its own. Always resolves - on any
   * failure the defaults above stand. */
  function loadThresholds() {
    return fetch('/api/config')
      .then(function (r) { return r.json(); })
      .then(function (cfg) {
        var t = cfg && cfg.Monitoring && cfg.Monitoring.thresholds;
        if (t) {
          setThresholds({
            warning:  t.headset_battery_warningLevel,
            critical: t.headset_battery_criticalLevel
          });
        }
      })
      .catch(function () {});
  }

  // Battery bands are the INVERSE of the CPU/GPU load bars on
  // headsets_monitoring.html: there a high number is bad, here a LOW one is.
  // Same palette, so the two still look like one system.
  function levelColor(pct) {
    if (pct == null || isNaN(pct)) return '#6b7280';
    if (pct <= thresholds.critical) return '#ef4444';   // critical
    if (pct <  thresholds.warning)  return '#f97316';   // warning
    return '#22c55e';                                   // ok
  }

  // Transparent variant of the line colour, for the area under the step.
  function fillFor(hex) {
    var r = parseInt(hex.slice(1, 3), 16),
        g = parseInt(hex.slice(3, 5), 16),
        b = parseInt(hex.slice(5, 7), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',0.14)';
  }

  function cssVar(name, fallback) {
    try {
      var v = getComputedStyle(document.documentElement).getPropertyValue(name);
      v = (v || '').trim();
      return v || fallback;
    } catch (e) { return fallback; }
  }

  function isLight() {
    return document.documentElement.getAttribute('data-theme') === 'light';
  }

  // ISO-8601 UTC ("2026-09-09T19:47:15Z") -> unix seconds. uPlot wants seconds
  // and renders them in the viewer's LOCAL timezone, which is what an operator
  // standing next to the headset expects to read.
  function toEpochSec(iso) {
    var ms = Date.parse(iso);
    return isNaN(ms) ? null : Math.round(ms / 1000);
  }

  /* Builds uPlot's [xs, ys] from the API payload.
   * Returns null when there is nothing to draw. */
  function toSeries(payload) {
    if (!payload) return null;

    // PowerShell 5.1's ConvertTo-Json can emit a one-element array as a bare
    // object. Normalise rather than trust it.
    var samples = payload.samples;
    if (!samples) samples = [];
    if (!Array.isArray(samples)) samples = [samples];
    if (!samples.length) return null;

    var nowSec = toEpochSec(payload.nowUtc) || Math.round(Date.now() / 1000);
    var hours  = Number(payload.hours) || 24;
    var startSec = nowSec - hours * 3600;

    var xs = [], ys = [];
    for (var i = 0; i < samples.length; i++) {
      var x = toEpochSec(samples[i].ts);
      var y = Number(samples[i].pct);
      if (x == null || isNaN(y)) continue;
      // Guard against a non-monotonic series - uPlot requires ascending x.
      if (xs.length && x <= xs[xs.length - 1]) { ys[ys.length - 1] = y; continue; }
      xs.push(x); ys.push(y);
    }
    if (!xs.length) return null;

    // Tail point: hold the last known value out to now (see header, point 1).
    if (xs[xs.length - 1] < nowSec) { xs.push(nowSec); ys.push(ys[ys.length - 1]); }

    return {
      xs: xs, ys: ys,
      range: [startSec, nowSec],
      last: ys[ys.length - 1],
      first: ys[0],
      min: Math.min.apply(null, ys),
      max: Math.max.apply(null, ys),
      count: samples.length
    };
  }

  function buildOpts(mode, s, width, height) {
    var line = levelColor(s.last);
    var grid = isLight() ? 'rgba(0,0,0,0.10)' : 'rgba(255,255,255,0.08)';
    var axis = cssVar('--muted', isLight() ? '#6b7280' : '#999');
    var mini = (mode === 'mini');

    var series1 = {
      label:  'Battery',
      stroke: line,
      fill:   fillFor(line),
      width:  mini ? 1.5 : 2,
      points: { show: false },
      paths:  uPlot.paths.stepped({ align: 1 }),
      value:  function (self, raw) { return raw == null ? '-' : raw + ' %'; }
    };

    return {
      width: width,
      height: height,
      // Mini keeps a little headroom on top: a full battery sits at y=100 and the
      // stroke would otherwise be flush against the tooltip border.
      padding: mini ? [7, 4, 2, 4] : [12, 16, 4, 4],
      cursor: mini ? { show: false } : { y: false, points: { size: 6 } },
      legend: { show: !mini },
      scales: {
        x: { time: true, range: s.range },
        // Pinned 0..100: an auto y scale would turn a 2% dip into a cliff.
        y: { auto: false, range: [0, 100] }
      },
      axes: mini ? [{ show: false }, { show: false }] : [
        {
          stroke: axis, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid },
          font: '11px system-ui, sans-serif'
        },
        {
          stroke: axis, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid },
          font: '11px system-ui, sans-serif', size: 46,
          splits: [0, 25, 50, 75, 100],
          values: function (self, splits) {
            return splits.map(function (v) { return v + '%'; });
          }
        }
      ],
      series: [
        {
          value: function (self, raw) {
            if (raw == null) return '-';
            return uPlot.fmtDate('{YYYY}-{MM}-{DD} {HH}:{mm}:{ss}')(new Date(raw * 1000));
          }
        },
        series1
      ]
    };
  }

  /* render(el, payload, opts)
   *   el      - container element, emptied first
   *   payload - the /api/battery-history body
   *   opts    - { mode: 'mini'|'full', width, height }
   * Returns { plot, stats } or null when there is nothing to draw. */
  function render(el, payload, opts) {
    opts = opts || {};
    var mode = opts.mode === 'mini' ? 'mini' : 'full';
    if (!el) return null;
    el.innerHTML = '';

    if (typeof uPlot === 'undefined') {
      el.textContent = 'Chart library not loaded.';
      return null;
    }

    var s = toSeries(payload);
    if (!s) return null;

    var width  = opts.width  || el.clientWidth || (mode === 'mini' ? 190 : 720);
    var height = opts.height || (mode === 'mini' ? 56 : 300);

    var plot = new uPlot(buildOpts(mode, s, width, height), [s.xs, s.ys], el);
    return { plot: plot, stats: s };
  }

  /* Rebuilds on a theme flip. topbar.js toggles data-theme on <html> and fires no
   * event, and uPlot cannot restyle in place, so watch the attribute. Returns a
   * disconnect function. */
  function observeTheme(cb) {
    var obs = new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        if (muts[i].attributeName === 'data-theme') { cb(); return; }
      }
    });
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    return function () { obs.disconnect(); };
  }

  window.BatteryChart = {
    render: render,
    toSeries: toSeries,
    levelColor: levelColor,
    setThresholds: setThresholds,
    loadThresholds: loadThresholds,
    getThresholds: function () { return { warning: thresholds.warning, critical: thresholds.critical }; },
    observeTheme: observeTheme
  };
})();
