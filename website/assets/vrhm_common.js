/*
 * vrhm_common.js - shared front-end poller and helpers (S7-1).
 *
 * Plain script, no dependency (the server routinely runs offline). Exposes ONE global, VRHM.
 * Load it BEFORE the page script; load live_events.js too if a poll uses liveEventsCounter.
 *
 *   VRHM.poll(fn, opts) -> { stop(), runNow() }
 *     fn()  must return a Promise (or a value). The next run is scheduled with a chained
 *           setTimeout AFTER fn settles, so two runs never overlap (in-flight guard).
 *           A rejection (fetch failure, non-2xx through VRHM.fetchJson, a throw) counts as
 *           an error.
 *     opts.intervalMs        base period, default 4000. A number, or a function returning
 *                            ms that is re-read before every schedule (dynamic period)
 *     opts.hiddenIntervalMs  period while document.hidden; omitted/0/null = pause entirely
 *                            (one run happens at once when the tab becomes visible again)
 *     opts.maxBackoffMs      ceiling of the error backoff, default 30000. Each consecutive
 *                            error doubles the period (intervalMs * 2^errors); a success
 *                            resets it
 *     opts.liveEventsCounter name of a LiveEvents counter (ADR-0020). While
 *                            LiveEvents.isConnected() the period is stretched to 15 s and
 *                            fn is also run when that counter moves
 *     opts.immediate         run once right away (default true)
 *     runNow()  run now (a run already in flight is not doubled: one more run is queued
 *               behind it). Returns a Promise that settles when that run is done.
 *     stop()    cancel the timer for good; later runNow() calls do nothing.
 *
 *   VRHM.fetchJson(url, opts) -> Promise<parsed JSON>
 *     fetch with a timeout (opts.timeoutMs, default 10000, AbortController). Rejects on a
 *     non-2xx status, a timeout or invalid JSON, so VRHM.poll backs off. Other opts go to fetch.
 *
 *   VRHM.esc(s)           HTML-escape text for innerHTML or an attribute (& < > " ').
 *                         null/undefined give ''.
 *   VRHM.toDisplayName(n) headset name to its file/URL form (spaces become underscores),
 *                         as the [video].html / [monitoring].html names are built.
 */
(function () {
  'use strict';

  var LIVE_STRETCH_MS = 15000;   // period while the push channel is flowing (as pages did)

  // ---- helpers -----------------------------------------------------------------------
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function toDisplayName(name) {
    return String(name == null ? '' : name).replace(/ /g, '_');
  }

  function fetchJson(url, opts) {
    opts = opts || {};
    var timeoutMs = opts.timeoutMs == null ? 10000 : opts.timeoutMs;
    var init = {};
    Object.keys(opts).forEach(function (k) { if (k !== 'timeoutMs') init[k] = opts[k]; });
    var timer = null;
    if (typeof AbortController !== 'undefined' && timeoutMs > 0) {
      var ac = new AbortController();
      if (!init.signal) init.signal = ac.signal;
      timer = setTimeout(function () { ac.abort(); }, timeoutMs);
    }
    return fetch(url, init).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (d) {
      if (timer) clearTimeout(timer);
      return d;
    }, function (e) {
      if (timer) clearTimeout(timer);
      throw e;
    });
  }

  // ---- poller ------------------------------------------------------------------------
  function poll(fn, opts) {
    opts = opts || {};
    // intervalMs may be a function returning ms: it is read before EVERY schedule, so a
    // period that follows a run-time value (the load-tier multiplier) needs no restart.
    var intervalOpt = opts.intervalMs;
    function baseInterval() {
      var v = typeof intervalOpt === 'function' ? intervalOpt() : intervalOpt;
      return v > 0 ? v : 4000;
    }
    var hiddenMs    = opts.hiddenIntervalMs > 0 ? opts.hiddenIntervalMs : 0;
    var maxBackoff  = opts.maxBackoffMs > 0 ? opts.maxBackoffMs : 30000;
    var counter     = opts.liveEventsCounter || '';

    var timer = null;
    var stopped = false;
    var current = null;     // Promise of the run in flight
    var again = false;      // a runNow() arrived while a run was in flight
    var errors = 0;

    function live() {
      return counter && window.LiveEvents && window.LiveEvents.isConnected();
    }

    function delay() {
      var base = document.hidden ? hiddenMs : baseInterval();
      if (!document.hidden && live()) base = Math.max(base, LIVE_STRETCH_MS);
      if (errors > 0) {
        base = Math.min(maxBackoff, base * Math.pow(2, Math.min(errors, 10)));
      }
      return base;
    }

    function schedule() {
      if (timer) { clearTimeout(timer); timer = null; }
      if (stopped || current) return;
      var d = delay();
      if (!(d > 0)) return;            // hidden and no hiddenIntervalMs: paused
      timer = setTimeout(function () { timer = null; run(); }, d);
    }

    function run() {
      if (stopped) return Promise.resolve();
      if (current) { again = true; return current; }
      if (timer) { clearTimeout(timer); timer = null; }
      var p;
      try { p = Promise.resolve(fn()); } catch (e) { p = Promise.reject(e); }
      current = p.then(function () { errors = 0; }, function () { errors++; })
        .then(function () {
          current = null;
          if (again) { again = false; run(); } else { schedule(); }
        });
      return current;
    }

    document.addEventListener('visibilitychange', function () {
      if (stopped) return;
      if (document.hidden) schedule();   // switches to hiddenIntervalMs or pauses
      else run();
    });

    if (counter && window.LiveEvents) {
      window.LiveEvents.subscribe(counter, function () {
        if (!stopped && !document.hidden) run();
      });
    }

    if (opts.immediate === false) schedule(); else run();

    return {
      stop: function () {
        stopped = true;
        if (timer) { clearTimeout(timer); timer = null; }
      },
      runNow: run
    };
  }

  window.VRHM = {
    poll: poll,
    fetchJson: fetchJson,
    esc: esc,
    toDisplayName: toDisplayName
  };
})();
