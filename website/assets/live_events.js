/*
 * live_events.js - push channel client (ADR-0020).
 *
 * The web server's /api/events stream sends the database CHANGE COUNTERS, never data:
 *   data: {"v":{"headset_status":123,"headsets":45,...}}
 * A page subscribes a fetch it already has to a counter; when that counter moves the
 * fetch runs again. No render path changes, and every page KEEPS its own polling timer
 * as the fallback, so a browser without push behaves exactly as before.
 *
 *   LiveEvents.subscribe('headset_status', pollHeadsetsStatus);
 *   LiveEvents.isConnected();   // true while push updates are flowing
 *
 * ONE stream per browser, on purpose. A browser allows only ~6 open connections per
 * server address, shared by every tab, iframe and OBS browser source. An event stream
 * holds one for good, so one per page (or per overlay iframe) used up the budget and
 * every other request from that browser queued forever - the web UI looked frozen.
 * So:
 *   - iframes never connect (the per-headset overlays keep their own polling);
 *   - top-level tabs elect ONE leader through a localStorage lease; only the leader
 *     opens the stream and relays each frame to the other tabs over a BroadcastChannel.
 * Without BroadcastChannel (very old browsers) the page simply does not connect.
 */
(function () {
  'use strict';

  var EVENTS_URL     = '/api/events';
  var CHANNEL_NAME   = 'vrhm-live-events';
  var LEASE_KEY      = 'vrhm_live_events_leader';
  var LEASE_MS       = 6000;    // a leader that stops renewing is replaced after this
  var RENEW_MS       = 2000;    // lease renewal + "alive" broadcast period
  var RETRY_MS       = 30000;   // retry after the server refused the stream (404/503)
  var COALESCE_MS    = 300;     // at most one trailing call per subscriber in this window

  var isTop = (function () { try { return window.top === window; } catch (e) { return false; } })();
  var hasChannel = (typeof BroadcastChannel !== 'undefined') && (typeof EventSource !== 'undefined');

  var subs      = {};     // counter -> [ {fn, last, timer} ]
  var lastMap   = null;   // last counter map seen
  var aliveAt   = 0;      // last time a frame or an "alive" signal arrived
  var tabId     = Math.random().toString(36).slice(2) + Date.now().toString(36);
  var channel   = null;
  var es        = null;
  var isLeader  = false;
  var retryTimer = null;

  // ---- subscribers -------------------------------------------------------------------
  function callCoalesced(entry) {
    var now = Date.now();
    if (now - entry.last >= COALESCE_MS && !entry.timer) {
      entry.last = now;
      try { entry.fn(); } catch (e) { }
      return;
    }
    if (entry.timer) return;   // a trailing call is already queued
    entry.timer = setTimeout(function () {
      entry.timer = null;
      entry.last = Date.now();
      try { entry.fn(); } catch (e) { }
    }, Math.max(0, COALESCE_MS - (now - entry.last)));
  }

  function handleMap(map) {
    aliveAt = Date.now();
    if (!map) return;
    var prev = lastMap;
    lastMap = map;
    // First frame (page just loaded): nothing to catch up on, the page has just fetched.
    if (!prev) return;
    Object.keys(subs).forEach(function (key) {
      if (map[key] !== prev[key]) {
        subs[key].forEach(callCoalesced);
      }
    });
  }

  // ---- leader: owns the EventSource --------------------------------------------------
  function openStream() {
    if (es || retryTimer) return;
    try { es = new EventSource(EVENTS_URL); } catch (e) { es = null; scheduleRetry(); return; }
    es.onmessage = function (evt) {
      var data = null;
      try { data = JSON.parse(evt.data); } catch (e) { return; }
      if (!data || !data.v) return;
      handleMap(data.v);
      if (channel) { try { channel.postMessage({ type: 'frame', v: data.v, from: tabId }); } catch (e) { } }
    };
    es.onopen = function () { aliveAt = Date.now(); };
    es.onerror = function () {
      // CLOSED = the server refused the stream (SSE disabled -> 404, full -> 503):
      // EventSource will not retry by itself, so wait and try again later. Otherwise
      // it is reconnecting on its own (e.g. web server restart).
      if (es && es.readyState === 2) { closeStream(); scheduleRetry(); }
    };
  }

  function closeStream() {
    if (es) { try { es.close(); } catch (e) { } es = null; }
  }

  function scheduleRetry() {
    if (retryTimer) return;
    retryTimer = setTimeout(function () { retryTimer = null; if (isLeader) openStream(); }, RETRY_MS);
  }

  // ---- leader election (localStorage lease) -----------------------------------------
  function readLease() {
    try { return JSON.parse(localStorage.getItem(LEASE_KEY) || 'null'); } catch (e) { return null; }
  }

  function tick() {
    var now = Date.now();
    var lease = readLease();
    var free = !lease || !lease.id || (now - lease.ts) > LEASE_MS || lease.id === tabId;
    if (free) {
      try { localStorage.setItem(LEASE_KEY, JSON.stringify({ id: tabId, ts: now })); } catch (e) { }
      var check = readLease();
      // localStorage unavailable (private mode, blocked): this tab streams on its own.
      var won = !check || check.id === tabId;
      if (won && !isLeader) { isLeader = true; openStream(); }
      if (!won && isLeader) { isLeader = false; closeStream(); }
    } else if (isLeader) {
      isLeader = false;
      closeStream();
    }
    if (isLeader && es && es.readyState === 1) {
      aliveAt = now;
      try { channel.postMessage({ type: 'alive', from: tabId }); } catch (e) { }
    }
  }

  function start() {
    if (!isTop || !hasChannel) return;
    channel = new BroadcastChannel(CHANNEL_NAME);
    channel.onmessage = function (evt) {
      var m = evt.data || {};
      if (m.from === tabId) return;
      if (m.type === 'frame') { handleMap(m.v); }
      else if (m.type === 'alive') { aliveAt = Date.now(); }
      else if (m.type === 'hello' && isLeader && lastMap) {
        try { channel.postMessage({ type: 'frame', v: lastMap, from: tabId }); } catch (e) { }
      }
    };
    try { channel.postMessage({ type: 'hello', from: tabId }); } catch (e) { }
    tick();
    setInterval(tick, RENEW_MS);
    window.addEventListener('pagehide', function () {
      closeStream();
      if (isLeader) {
        var lease = readLease();
        if (lease && lease.id === tabId) { try { localStorage.removeItem(LEASE_KEY); } catch (e) { } }
      }
    });
  }

  window.LiveEvents = {
    // fn runs when the named counter moves (coalesced, never more than ~3 times a second).
    subscribe: function (counter, fn) {
      if (typeof fn !== 'function') return;
      (subs[counter] = subs[counter] || []).push({ fn: fn, last: 0, timer: null });
    },
    // True while updates are flowing (this tab leads an open stream, or the leader
    // signalled recently). Pages may use it to slow their fallback polling.
    isConnected: function () {
      return (Date.now() - aliveAt) < (LEASE_MS + RENEW_MS);
    }
  };

  start();
})();
