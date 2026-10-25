/*
 * offline_guard.js - "VRHM application unavailable" full-screen notice.
 *
 * Include in TOP-LEVEL operator / kiosk pages (never in the transparent OBS overlays):
 *   <script src="assets/offline_guard.js"></script>
 *   <script src="assets/offline_guard.js" data-no-reload></script>   (page with unsaved input)
 *
 * What it does
 *   - Pings GET /api/version every 5 s (15 s in a hidden tab). Two failures in a row (or a
 *     'vrhm:fetch-error' event from vrhm_common.js followed by one failed ping) show a
 *     full-screen overlay: logo, Nyan Cat, text, elapsed counter.
 *   - While shown it pings every 2 s. On the first answer {"app":"VRHM"} it reloads the SAME
 *     url (query string and hash kept), or only hides itself with data-no-reload.
 *   - Works with no internet: logo is inline SVG, the cat is assets/nyancat.gif preloaded
 *     into a data: URI while the server is still up (a plain SVG cat is the fallback).
 *   - Top-level windows only: an iframe never shows a copy of its own.
 *
 * ASCII-only file: non-ASCII characters are written as \u escapes.
 */
(function () {
  'use strict';
  if (window.top !== window) return;
  if (window.__vrhmOfflineGuard) return;
  window.__vrhmOfflineGuard = true;

  var VERSION_URL   = '/api/version';
  var CAT_URL       = '/assets/nyancat.gif';
  var NORMAL_MS     = 5000;
  var HIDDEN_MS     = 15000;
  var DOWN_MS       = 2000;
  var PING_TIMEOUT  = 3000;
  var FAILS_TO_SHOW = 2;
  var BG            = '#003366';   // classic Nyan Cat night-sky blue (the GIF is transparent)

  var scriptEl = document.currentScript;
  var noReload = !!(scriptEl && scriptEl.hasAttribute('data-no-reload'));

  var lang = ((navigator.language || 'en') + '').toLowerCase().indexOf('fr') === 0 ? 'fr' : 'en';
  var T = {
    en: {
      title: 'VRHM application currently unavailable',
      sub:   'The server is restarting or has been closed. This page will come back by itself.',
      wait:  'Waiting for the server',
      back:  'Server is back'
    },
    fr: {
      title: 'Application VRHM actuellement indisponible',
      sub:   'Le serveur red\u00e9marre ou a \u00e9t\u00e9 ferm\u00e9. Cette page reviendra toute seule.',
      wait:  'En attente du serveur',
      back:  'Le serveur est de retour'
    }
  }[lang];

  var fails = 0;
  var shown = false;
  var downSince = 0;
  var timer = null;
  var pinging = false;
  var catData = '';
  var overlay = null;
  var counterEl = null;
  var counterTimer = null;

  // ---- cat: preload the GIF as a data: URI while the server is up ----------------------
  function preloadCat() {
    try {
      fetch(CAT_URL, { cache: 'force-cache' }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.blob();
      }).then(function (b) {
        var fr = new FileReader();
        fr.onload = function () { catData = String(fr.result || ''); };
        fr.readAsDataURL(b);
      }).catch(function () {});
    } catch (e) {}
  }

  // plain SVG cat, used only when the GIF is missing
  var FALLBACK_CAT =
    '<svg viewBox="0 0 120 90" width="180" height="135" xmlns="http://www.w3.org/2000/svg">' +
    '<polygon points="22,30 30,6 46,24" fill="#ffcc99"/><polygon points="98,30 90,6 74,24" fill="#ffcc99"/>' +
    '<ellipse cx="60" cy="52" rx="42" ry="34" fill="#ffcc99"/>' +
    '<circle cx="45" cy="48" r="5" fill="#111"/><circle cx="75" cy="48" r="5" fill="#111"/>' +
    '<polygon points="56,58 64,58 60,63" fill="#ff7799"/>' +
    '<path d="M60 63 Q54 70 48 66 M60 63 Q66 70 72 66" stroke="#111" stroke-width="2" fill="none"/></svg>';

  // ---- overlay ---------------------------------------------------------------------------
  var LOGO =
    '<svg viewBox="0 0 464 150" width="300" height="97" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="VR Headset Manager">' +
    '<g transform="translate(8,10) scale(2.03)">' +
    '<rect x="5" y="5" width="54" height="54" rx="11" fill="#161616"/>' +
    '<rect x="5" y="5" width="54" height="54" rx="11" fill="none" stroke="#60a5fa" stroke-width="5"/>' +
    '<rect x="14" y="23" width="36" height="19" rx="9" fill="#ffffff"/>' +
    '<circle cx="32" cy="43" r="6" fill="#161616"/></g>' +
    '<text x="310" y="80" text-anchor="middle" font-family="Segoe UI, Arial, Helvetica, sans-serif" font-size="44" font-weight="700" fill="#93c5fd" letter-spacing="1">VR HEADSET</text>' +
    '<text x="310" y="122" text-anchor="middle" font-family="Segoe UI, Arial, Helvetica, sans-serif" font-size="34" font-weight="600" fill="#cbd5e1" letter-spacing="10">MANAGER</text></svg>';

  var CSS =
    '.vrhm-og-rainbow{position:absolute;right:calc(100% - 100px);top:30%;height:46%;display:flex;flex-direction:row-reverse}' +
    '.vrhm-og-rainbow i{display:block;flex:none;width:20px;height:100%;' +
    'background:linear-gradient(to bottom,#ff0000 0 16.66%,#ff9900 0 33.33%,#ffff00 0 50%,' +
    '#33ff00 0 66.66%,#0099ff 0 83.33%,#6633ff 0 100%);' +
    'animation:vrhm-og-wave 1s steps(1) infinite}' +
    '@keyframes vrhm-og-wave{0%{transform:translateY(0)}25%{transform:translateY(-8px)}' +
    '50%{transform:translateY(0)}75%{transform:translateY(8px)}}';

  function buildOverlay() {
    if (overlay) return;
    if (!document.getElementById('vrhm-og-style')) {
      var st = document.createElement('style');
      st.id = 'vrhm-og-style';
      st.textContent = CSS;
      document.head.appendChild(st);
    }
    overlay = document.createElement('div');
    overlay.setAttribute('role', 'alert');
    overlay.style.cssText =
      'position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483647;background:' + BG + ';' +
      'color:#fff;display:flex;flex-direction:column;align-items:center;justify-content:center;' +
      'text-align:center;padding:16px;font-family:Segoe UI,Arial,Helvetica,sans-serif;overflow-x:hidden;overflow-y:auto;';
    overlay.innerHTML =
      '<div style="margin-bottom:24px">' + LOGO + '</div>' +
      '<div id="vrhm-og-cat" style="margin-bottom:24px;min-height:135px"></div>' +
      '<div style="font-size:clamp(20px,4vw,34px);font-weight:700;margin-bottom:10px"></div>' +
      '<div style="font-size:clamp(14px,2vw,18px);color:#cbd5e1;max-width:640px;margin-bottom:18px"></div>' +
      '<div style="font-size:14px;color:#93c5fd"><span></span> <b></b></div>';
    var kids = overlay.children;
    kids[2].textContent = T.title;
    kids[3].textContent = T.sub;
    kids[4].firstChild.textContent = T.wait;
    counterEl = kids[4].lastChild;
  }

  function setCat() {
    var holder = overlay.querySelector('#vrhm-og-cat');
    holder.innerHTML = '';
    holder.style.position = 'relative';
    holder.style.display = 'inline-block';
    // rainbow trail: six stripes from behind the pop-tart to the left edge of the screen,
    // bobbing in two steps like the cat (the GIF itself has no trail)
    var rb = document.createElement('div');
    rb.className = 'vrhm-og-rainbow';
    // one column per 20 px, each phase-shifted, so the wave travels away from the cat;
    // the first columns sit under the pop-tart (the image is drawn above the rainbow)
    var cols = Math.ceil(window.innerWidth / 2 / 20) + 6;
    for (var c = 0; c < cols; c++) {
      var col = document.createElement('i');
      // phase lags with the distance from the cat: the wave travels right to left
      col.style.animationDelay = '-' + ((1 - (c * 0.125) % 1) % 1).toFixed(3) + 's';
      rb.appendChild(col);
    }
    holder.appendChild(rb);
    var img = new Image();
    img.alt = 'Nyan Cat';
    img.style.cssText = 'height:168px;max-width:90vw;image-rendering:pixelated;position:relative;display:block;';
    img.onerror = function () { holder.innerHTML = FALLBACK_CAT; };
    img.src = catData || CAT_URL;
    holder.appendChild(img);
  }

  function fmt(sec) {
    var m = Math.floor(sec / 60), s = sec % 60;
    return (m ? m + ' min ' : '') + s + ' s';
  }

  function show() {
    if (shown) return;
    shown = true;
    downSince = Date.now();
    buildOverlay();
    setCat();
    counterEl.textContent = '0 s';
    document.body.appendChild(overlay);
    counterTimer = setInterval(function () {
      counterEl.textContent = fmt(Math.floor((Date.now() - downSince) / 1000));
    }, 1000);
  }

  function hide() {
    if (!shown) return;
    shown = false;
    if (counterTimer) { clearInterval(counterTimer); counterTimer = null; }
    if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
  }

  // ---- watchdog --------------------------------------------------------------------------
  function ping() {
    if (pinging) return Promise.resolve();
    pinging = true;
    var ac = (typeof AbortController !== 'undefined') ? new AbortController() : null;
    var t = ac ? setTimeout(function () { ac.abort(); }, PING_TIMEOUT) : null;
    return fetch(VERSION_URL + '?_=' + Date.now(), { cache: 'no-store', signal: ac ? ac.signal : undefined })
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then(function (d) {
        if (!d || d.app !== 'VRHM') throw new Error('not VRHM');
        return true;
      })
      .catch(function () { return false; })
      .then(function (ok) {
        if (t) clearTimeout(t);
        pinging = false;
        if (ok) onUp(); else onDown();
      });
  }

  function onDown() {
    fails++;
    if (fails >= FAILS_TO_SHOW) show();
    next();
  }

  function onUp() {
    var wasShown = shown;
    fails = 0;
    if (wasShown) {
      if (noReload) { hide(); }
      else {
        if (counterEl) counterEl.textContent = T.back;
        location.reload();
        return;
      }
    }
    next();
  }

  function next() {
    if (timer) clearTimeout(timer);
    var d = shown ? DOWN_MS : (document.hidden ? HIDDEN_MS : NORMAL_MS);
    timer = setTimeout(function () { timer = null; ping(); }, d);
  }

  // a poller of the page failed: check now instead of waiting for the next tick
  window.addEventListener('vrhm:fetch-error', function () {
    if (!pinging && !shown) { if (timer) clearTimeout(timer); ping(); }
  });

  function start() {
    preloadCat();
    next();
  }
  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
})();
