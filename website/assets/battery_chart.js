/* battery_chart.js - the only wrapper around uPlot in this project.
 *
 * It draws ANY per-headset metric recorded in metric_history, not just battery.
 * Three call sites share it so the step semantics, the colour thresholds and the
 * theme handling are defined once:
 *   - headsets_monitoring.html : mode 'mini', the 1h sparklines in the hover tooltip
 *   - metric_history.html      : mode 'full', the 24/12/3/1h/all page chart
 *   - battery_history.html     : legacy redirect stub, kept for old bookmarks
 *
 * Data contract - the payload is the raw body of GET /api/metric-history:
 *   { ok, id, metric, unit, hours, window, retentionHours, nowUtc,
 *     samples: [ { ts, value }, ... ] }
 * The retired GET /api/battery-history shape ({ ts, pct }) still parses, so the
 * legacy endpoint keeps working.
 *
 * Two things about that series matter and are handled here, not by callers:
 *
 *  1. It is a STEP function, not a line. A sample is only written when the value
 *     CHANGES, so between two samples the reading genuinely held - interpolating
 *     a slope between them would invent readings that never existed. Hence
 *     uPlot.paths.stepped and a synthetic tail point at nowUtc carrying the last
 *     known value, so the line reaches "now" instead of stopping at the last
 *     change.
 *
 *  2. The first sample is usually the seed row from BEFORE the window (see
 *     metric.window.sql). The x scale is therefore pinned to the requested window
 *     rather than to the data extent: a 24h window must read as 24 hours even when
 *     the only sample in it is one that predates it. uPlot clips the off-screen
 *     point and draws its segment into view, which is exactly the flat line wanted.
 *
 * uPlot bakes colours in at construction and does not follow CSS, so a theme change
 * means a rebuild - callers get that through MetricChart.observeTheme().
 */
(function () {
  'use strict';

  /* The metric registry. Mirrors Get-HeadsetMetricDefinition in
   * modules\headsets_monitoring.ps1 and the trg_status_*_sample triggers in
   * migration 006 - all three change together when a metric is added.
   *
   *   dir   'low-bad'  a LOW value is the problem (battery, controllers)
   *         'high-bad' a HIGH value is the problem (temperature)
   *         'neutral'  no configured bands, one accent colour
   *   scale [min,max] pins the y axis; 'auto' lets uPlot fit the data. Pinning a
   *         temperature to 0..100 would flatten a 30->45 C swing into a straight
   *         line, so only percent metrics are pinned.
   *   dp    decimal places shown in the legend, the stats and the tooltip.
   *
   * Band defaults mirror config_files_loader.ps1's own defaults, so a failed
   * /api/config fetch still colours the way a default install does. */
  var METRICS = {
    battery: {
      label: 'Battery', unit: '%', dir: 'low-bad', scale: [0, 100], dp: 0,
      cfgWarn: 'headset_battery_warningLevel', cfgCrit: 'headset_battery_criticalLevel',
      warn: 40, crit: 30
    },
    temp: {
      label: 'Temperature', unit: 'C', dir: 'high-bad', scale: 'auto', dp: 1,
      cfgWarn: 'temperature_warningLevel', cfgCrit: 'temperature_highLevel',
      warn: 42, crit: 50
    },
    ctrl_left: {
      label: 'Controller L', unit: '%', dir: 'low-bad', scale: [0, 100], dp: 0,
      cfgWarn: 'controllers_battery_warningLevel', cfgCrit: 'controllers_battery_criticalLevel',
      warn: 30, crit: 20
    },
    ctrl_right: {
      label: 'Controller R', unit: '%', dir: 'low-bad', scale: [0, 100], dp: 0,
      cfgWarn: 'controllers_battery_warningLevel', cfgCrit: 'controllers_battery_criticalLevel',
      warn: 30, crit: 20
    },
    wattage: {
      label: 'Charging power', unit: 'W', dir: 'neutral', scale: 'auto', dp: 1
    }
  };

  var DEFAULT_METRIC = 'battery';

  // Retention period in hours, from config. metric_history.html uses it to decide
  // whether an "all records" window is worth offering at all.
  var retentionHours = 24;

  function metricDef(key) {
    return METRICS[key] || METRICS[DEFAULT_METRIC];
  }

  function metricKeys() {
    return Object.keys(METRICS);
  }

  /* Bands are OPERATOR CONFIG, not constants, so the graph agrees with the
   * per-headset overlay and with vrhm_config.html instead of inventing its own
   * scale. setThresholds patches one metric; loadThresholds fills them all.
   *
   * Boundary convention for the percent metrics follows headset_status.pshtml's
   * applyBatteryClass() (<= critical, < warning), because that is the code
   * colouring the battery VALUE, which is what this colours too. Note the
   * PowerShell icon logic in the same template uses < critical, so those two
   * already disagree at exactly the critical value; this matches the JS one
   * rather than adding a third reading. Temperature is a NEW reading with no such
   * legacy, so it uses the plain >= on both bands. */
  function setThresholds(metric, t) {
    var d = METRICS[metric];
    if (!d || !t) return;
    var w = parseFloat(t.warning);
    var c = parseFloat(t.critical);
    if (!isNaN(w)) d.warn = w;
    if (!isNaN(c)) d.crit = c;
  }

  /* Reads the live thresholds and the retention period once per page load.
   * /api/config already returns the whole config, so this needs no endpoint of
   * its own and one fetch covers every metric. Always resolves - on any failure
   * the defaults above stand. */
  function loadThresholds() {
    return fetch('/api/config')
      .then(function (r) { return r.json(); })
      .then(function (cfg) {
        var t = cfg && cfg.Monitoring && cfg.Monitoring.thresholds;
        if (t) {
          metricKeys().forEach(function (k) {
            var d = METRICS[k];
            if (!d.cfgWarn) return;   // neutral metric, no bands to fill
            setThresholds(k, { warning: t[d.cfgWarn], critical: t[d.cfgCrit] });
          });
        }
        var rh = cfg && cfg.database &&
                 (cfg.database.metric_history_hours != null
                    ? cfg.database.metric_history_hours
                    : cfg.database.battery_history_hours);
        var n = parseFloat(rh);
        if (!isNaN(n) && n > 0) retentionHours = n;
      })
      .catch(function () {});
  }

  /* Colour for one value of one metric. 'low-bad' keeps the battery bands, which
   * are the INVERSE of the CPU/GPU load bars on headsets_monitoring.html: there a
   * high number is bad, here a LOW one is. 'high-bad' is the load-bar direction
   * again, for temperature. Same palette throughout, so it all reads as one
   * system. */
  function levelColor(v, metric) {
    if (v == null || isNaN(v)) return '#6b7280';
    var d = metricDef(metric || DEFAULT_METRIC);
    if (d.dir === 'neutral') return '#3b82f6';
    if (d.dir === 'high-bad') {
      if (v >= d.crit) return '#ef4444';   // at or over the high threshold
      if (v >= d.warn) return '#f97316';   // warm
      return '#22c55e';                    // ok
    }
    if (v <= d.crit) return '#ef4444';     // critical
    if (v <  d.warn) return '#f97316';     // warning
    return '#22c55e';                      // ok
  }

  // Transparent variant of the line colour, for the area under the step.
  function fillFor(hex) {
    var r = parseInt(hex.slice(1, 3), 16),
        g = parseInt(hex.slice(3, 5), 16),
        b = parseInt(hex.slice(5, 7), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',0.14)';
  }

  // Value as text, at the metric's precision, with its unit.
  function formatValue(v, metric) {
    if (v == null || isNaN(v)) return '-';
    var d = metricDef(metric || DEFAULT_METRIC);
    var n = Number(v).toFixed(d.dp);
    return d.unit === '%' ? (n + ' %') : (n + ' ' + d.unit);
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
      // 'value' is the current shape; 'pct' is the retired /api/battery-history one.
      var raw = (samples[i].value != null) ? samples[i].value : samples[i].pct;
      var y = Number(raw);
      if (x == null || raw == null || isNaN(y)) continue;
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

  function buildOpts(mode, s, width, height, metric) {
    var d    = metricDef(metric);
    var line = levelColor(s.last, metric);
    var grid = isLight() ? 'rgba(0,0,0,0.10)' : 'rgba(255,255,255,0.08)';
    var axis = cssVar('--muted', isLight() ? '#6b7280' : '#999');
    var mini = (mode === 'mini');
    var pinned = Array.isArray(d.scale);

    var series1 = {
      label:  d.label,
      stroke: line,
      fill:   fillFor(line),
      width:  mini ? 1.5 : 2,
      points: { show: false },
      paths:  uPlot.paths.stepped({ align: 1 }),
      value:  function (self, raw) { return formatValue(raw, metric); }
    };

    var yAxis = {
      stroke: axis, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid },
      font: '11px system-ui, sans-serif', size: 46,
      values: function (self, splits) {
        return splits.map(function (v) { return Number(v).toFixed(d.dp) + (d.unit === '%' ? '%' : ' ' + d.unit); });
      }
    };
    if (pinned) { yAxis.splits = [0, 25, 50, 75, 100]; }

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
        // Percent metrics are pinned: an auto y scale would turn a 2% dip into a
        // cliff. Everything else is auto, because pinning degrees to 0..100 hides
        // the whole signal.
        y: pinned ? { auto: false, range: d.scale } : { auto: true }
      },
      axes: mini ? [{ show: false }, { show: false }] : [
        {
          stroke: axis, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid },
          font: '11px system-ui, sans-serif'
        },
        yAxis
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
   *   payload - the /api/metric-history body
   *   opts    - { mode: 'mini'|'full', width, height, metric }
   * The metric comes from opts.metric, falling back to the payload's own metric
   * field, so a caller that just forwards the response needs to pass nothing.
   * Returns { plot, stats, metric } or null when there is nothing to draw. */
  function render(el, payload, opts) {
    opts = opts || {};
    var mode = opts.mode === 'mini' ? 'mini' : 'full';
    if (!el) return null;
    el.innerHTML = '';

    if (typeof uPlot === 'undefined') {
      el.textContent = 'Chart library not loaded.';
      return null;
    }

    var metric = opts.metric || (payload && payload.metric) || DEFAULT_METRIC;
    if (!METRICS[metric]) metric = DEFAULT_METRIC;

    var s = toSeries(payload);
    if (!s) return null;

    var width  = opts.width  || el.clientWidth || (mode === 'mini' ? 190 : 720);
    var height = opts.height || (mode === 'mini' ? 56 : 300);

    var plot = new uPlot(buildOpts(mode, s, width, height, metric), [s.xs, s.ys], el);
    return { plot: plot, stats: s, metric: metric };
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

  window.MetricChart = {
    render: render,
    toSeries: toSeries,
    levelColor: levelColor,
    formatValue: formatValue,
    metrics: METRICS,
    metricKeys: metricKeys,
    metricDef: metricDef,
    setThresholds: setThresholds,
    loadThresholds: loadThresholds,
    getThresholds: function (metric) {
      var d = metricDef(metric || DEFAULT_METRIC);
      return { warning: d.warn, critical: d.crit };
    },
    getRetentionHours: function () { return retentionHours; },
    observeTheme: observeTheme
  };

  /* Legacy facade, bound to battery. Kept because CLAUDE.md names BatteryChart as
   * this file's public surface and headsets_monitoring.html shipped against it. */
  window.BatteryChart = {
    render: function (el, payload, opts) {
      opts = opts || {};
      if (!opts.metric) opts.metric = 'battery';
      return render(el, payload, opts);
    },
    toSeries: toSeries,
    levelColor: function (pct) { return levelColor(pct, 'battery'); },
    setThresholds: function (t) { setThresholds('battery', t); },
    loadThresholds: loadThresholds,
    getThresholds: function () { return { warning: METRICS.battery.warn, critical: METRICS.battery.crit }; },
    observeTheme: observeTheme
  };
})();
