/*
 * live_events.js - shared Server-Sent Events client (ADR-0020).
 *
 * The server pushes an INVALIDATION NUDGE, never data: one frame carrying the
 * database change counters, e.g.
 *
 *     data: {"v":{"headsets":7909,"headset_status":6415,...}}
 *
 * A page subscribes to the counters it cares about and, when one moves, runs the
 * fetch it already had. Nothing about how a page renders changes - only what
 * decides when to re-fetch. That is why this is a nudge and not a payload: the
 * existing endpoints stay the single source of shape, and the pump stays one
 * indexed database read per tick no matter how many browsers are attached.
 *
 * Every page keeps its polling timer as a fallback. If SSE is unavailable (older
 * browser, SSE disabled in config, a proxy that buffers event streams) the page
 * behaves exactly as it did before - see nextStatusDelay() in each page.
 *
 * Usage:
 *     LiveEvents.subscribe('headset_status', pollHeadsetsStatus);
 *     if (LiveEvents.isConnected()) { ...use a slow heartbeat instead of polling... }
 */
(function (global) {
  'use strict';

  var SUBS      = {};     // counter name -> [callback]
  var stateCbs  = [];
  var last      = null;   // last counter map seen
  var es        = null;
  var started   = false;
  var connected = false;
  var disabled  = false;  // server said no - stop trying, stay on polling
  var resync    = false;  // fire everything on the first frame after a (re)connect

  function notifyState() {
    for (var i = 0; i < stateCbs.length; i++) {
      try { stateCbs[i](connected); } catch (e) { }
    }
  }

  // Coalescing. A counter can move faster than a page needs to redraw - the monitor
  // writes status whenever its fingerprint changes, which a fluctuating charging
  // wattage can make sub-second. Without this, SSE would out-poll the fixed timer it
  // replaced. Leading edge fires immediately; anything inside the window collapses
  // into ONE trailing call, so a burst costs two fetches, not twenty.
  var MIN_FIRE_MS = 300;
  var lastFire = {};
  var pending  = {};

  function runCallbacks(name) {
    var cbs = SUBS[name];
    if (!cbs) { return; }
    for (var j = 0; j < cbs.length; j++) {
      try { cbs[j](); } catch (e) { }
    }
  }

  function fireOne(name) {
    if (!SUBS[name]) { return; }
    var now  = Date.now();
    var wait = MIN_FIRE_MS - (now - (lastFire[name] || 0));
    if (wait <= 0) {
      lastFire[name] = now;
      runCallbacks(name);
      return;
    }
    if (pending[name]) { return; }
    pending[name] = setTimeout(function () {
      pending[name] = null;
      lastFire[name] = Date.now();
      runCallbacks(name);
    }, wait);
  }

  function fire(names) {
    for (var i = 0; i < names.length; i++) { fireOne(names[i]); }
  }

  function handle(data) {
    var v = data && data.v;
    if (!v) { return; }

    if (resync) {
      // First frame after connecting or reconnecting. We cannot know what changed
      // while we were not listening, so refresh everything once. On initial load
      // that costs one extra fetch; after a dropped connection it is what stops the
      // page sitting on stale data until the fallback heartbeat comes round.
      resync = false;
      last = v;
      var all = [];
      for (var key in SUBS) { if (SUBS.hasOwnProperty(key)) { all.push(key); } }
      fire(all);
      return;
    }

    var changed = [];
    for (var k in v) {
      if (!v.hasOwnProperty(k)) { continue; }
      if (!last || !last.hasOwnProperty(k) || last[k] !== v[k]) { changed.push(k); }
    }
    last = v;
    fire(changed);
  }

  function start() {
    if (started || disabled || typeof EventSource === 'undefined') { return; }
    started = true;
    try {
      es = new EventSource('/api/events');
    } catch (e) {
      started = false; disabled = true; return;
    }
    es.onopen = function () {
      connected = true; resync = true; notifyState();
    };
    es.onmessage = function (ev) {
      try { handle(JSON.parse(ev.data)); } catch (e) { }
    };
    es.onerror = function () {
      connected = false;
      notifyState();
      // EventSource reconnects by itself while readyState is CONNECTING (0). CLOSED
      // (2) means the server refused us - 404 because SSE is off or the pump failed
      // to start, or 503 at the client cap. Give up quietly and let the page poll.
      if (es && es.readyState === 2) {
        disabled = true;
        try { es.close(); } catch (e) { }
        es = null;
      }
    };
  }

  global.LiveEvents = {
    subscribe: function (counter, cb) {
      if (!counter || typeof cb !== 'function') { return; }
      if (!SUBS[counter]) { SUBS[counter] = []; }
      SUBS[counter].push(cb);
      start();
    },
    onConnectionChange: function (cb) {
      if (typeof cb === 'function') { stateCbs.push(cb); }
    },
    isConnected: function () { return connected; },
    counters:    function () { return last; }
  };
})(window);
