// App Launcher modal - shared across all pages.
// Exposes:
//   window.openLaunchModal(displayName)
//   window.appLauncher.setStatusResolver(fn)  -- fn(dn) -> bool, returns true if ADB is up
//                                                Call once after this script loads.
//                                                Defaults to always-true when not set.
(function () {

  // ---- Inject CSS ----
  var style = document.createElement('style');
  style.textContent = [
    /* App launcher modal */
    '.app-launcher{position:fixed;inset:0;z-index:1000;background:rgba(0,0,0,0.72);display:flex;align-items:flex-start;justify-content:center;padding-top:0;}',
    '.app-launcher-box{background:#1a1a1a;border:1px solid #333;border-bottom-left-radius:10px;border-bottom-right-radius:10px;width:100%;max-width:520px;display:flex;flex-direction:column;box-shadow:0 8px 32px rgba(0,0,0,0.7);max-height:80vh;overflow:hidden;}',
    '.lm-header{display:flex;align-items:center;justify-content:space-between;padding:14px 18px 12px;border-bottom:1px solid #252525;flex-shrink:0;}',
    '.lm-title-wrap{display:flex;flex-direction:column;gap:2px;}',
    '.lm-headset-label{font-size:10px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:0.06em;}',
    '.lm-title{font-size:14px;font-weight:700;color:#e0e0e0;}',
    '.lm-close{display:inline-flex;align-items:center;justify-content:center;width:26px;height:26px;padding:0;background:transparent;border:1px solid transparent;border-radius:5px;color:#555;cursor:pointer;transition:color 0.12s,border-color 0.12s;}',
    '.lm-close:hover{color:#aaa;border-color:#333;}',
    '.lm-list{overflow-y:auto;flex:1;padding:6px 0;}',
    '.lm-section-label{padding:8px 18px 4px;font-size:10px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:0.06em;}',
    '.lm-app-row{display:flex;align-items:center;gap:10px;padding:7px 18px;cursor:default;transition:background 0.1s;}',
    '.lm-app-row:hover{background:#202020;}',
    '.lm-app-name{flex:1;font-size:13px;color:#ccc;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}',
    '.lm-app-row.is-meta .lm-app-name{color:#67e8f9;font-weight:600;}',
    '.lm-star-btn{display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;padding:0;flex-shrink:0;background:transparent;border:none;border-radius:4px;cursor:pointer;color:#3a3a3a;transition:color 0.12s;}',
    '.lm-star-btn.active{color:#facc15;}',
    '.lm-star-btn:hover{color:#facc15;}',
    '.lm-app-row.is-meta .lm-star-btn{visibility:hidden;}',
    '.lm-app-version{font-size:11px;color:#444;flex-shrink:0;white-space:nowrap;}',
    '.lm-launch-btn{display:inline-flex;align-items:center;gap:5px;padding:3px 10px;border-radius:5px;border:1px solid #444;background:#2a2a2a;color:#888;font-size:11px;font-weight:700;cursor:pointer;font-family:inherit;flex-shrink:0;transition:background 0.12s,border-color 0.12s,color 0.12s;}',
    '.lm-launch-btn:hover{background:rgba(59,130,246,0.22);border-color:#3b82f6;color:#3b82f6;}',
    '.lm-footer{border-top:1px solid #252525;padding:10px 18px;flex-shrink:0;display:flex;flex-direction:column;gap:8px;}',
    '.lm-show-all-btn{display:flex;align-items:center;justify-content:center;gap:6px;padding:7px;border-radius:6px;border:1px solid #333;background:#161616;color:#666;font-size:12px;font-weight:600;cursor:pointer;font-family:inherit;width:100%;transition:color 0.12s,border-color 0.12s;}',
    '.lm-show-all-btn:hover{color:#aaa;border-color:#444;}',
    '.lm-status{font-size:11px;color:#555;text-align:center;min-height:16px;}',
    '.lm-status.ok{color:#22c55e;}',
    '.lm-status.err{color:#ef4444;}',
    /* Search */
    '.lm-search-wrap{display:flex;align-items:center;gap:4px;flex:1;margin:0 12px;}',
    '.lm-search{flex:1;background:#111;border:1px solid #333;border-radius:5px;color:#ccc;font-family:inherit;font-size:12px;padding:4px 8px;outline:none;min-width:0;}',
    '.lm-search:focus{border-color:#555;}',
    /* Light mode */
    '[data-theme="light"] .app-launcher{background:rgba(0,0,0,0.32);}',
    '[data-theme="light"] .app-launcher-box{background:#fff;border-color:#e0e0e0;box-shadow:0 8px 32px rgba(0,0,0,0.12);}',
    '[data-theme="light"] .lm-header{border-color:#efefef;}',
    '[data-theme="light"] .lm-headset-label{color:#bbb;}',
    '[data-theme="light"] .lm-title{color:#111;}',
    '[data-theme="light"] .lm-close{color:#bbb;}',
    '[data-theme="light"] .lm-close:hover{color:#555;border-color:#ddd;}',
    '[data-theme="light"] .lm-section-label{color:#bbb;}',
    '[data-theme="light"] .lm-app-row:hover{background:#f5f5f5;}',
    '[data-theme="light"] .lm-app-name{color:#333;}',
    '[data-theme="light"] .lm-app-row.is-meta .lm-app-name{color:#0e7490;}',
    '[data-theme="light"] .lm-app-version{color:#bbb;}',
    '[data-theme="light"] .lm-star-btn{color:#ccc;}',
    '[data-theme="light"] .lm-star-btn.active{color:#facc15;}',
    '[data-theme="light"] .lm-star-btn:hover{color:#facc15;}',
    '[data-theme="light"] .lm-footer{border-color:#efefef;}',
    '[data-theme="light"] .lm-launch-btn{background:#e8e8e8;border-color:#ccc;color:#555;}',
    '[data-theme="light"] .lm-launch-btn:hover{background:rgba(59,130,246,0.12);border-color:#3b82f6;color:#2563eb;}',
    '[data-theme="light"] .lm-show-all-btn{background:#f5f5f5;border-color:#ddd;color:#666;}',
    '[data-theme="light"] .lm-show-all-btn:hover{color:#222;border-color:#bbb;}',
    '[data-theme="light"] .lm-status{color:#aaa;}',
    '[data-theme="light"] .lm-search{background:#f5f5f5;border-color:#ccc;color:#222;}',
    '[data-theme="light"] .lm-search:focus{border-color:#999;}'
  ].join('');
  document.head.appendChild(style);

  // ---- Inject HTML ----
  var wrapper = document.createElement('div');
  wrapper.innerHTML =
    '<div class="app-launcher" id="app-launcher" style="display:none">' +
      '<div class="app-launcher-box">' +
        '<div class="lm-header">' +
          '<div class="lm-title-wrap">' +
            '<span class="lm-headset-label" id="lm-headset-label"></span>' +
            '<span class="lm-title">Launch App</span>' +
          '</div>' +
          '<div class="lm-search-wrap" id="lm-search-wrap" style="display:none">' +
            '<input class="lm-search" id="lm-search" type="search" placeholder="Search apps..." autocomplete="off" spellcheck="false">' +
          '</div>' +
          '<button class="lm-close" id="lm-close" title="Close">' +
            '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
              '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>' +
            '</svg>' +
          '</button>' +
        '</div>' +
        '<div class="lm-list" id="lm-list"></div>' +
        '<div class="lm-footer">' +
          '<button class="lm-show-all-btn" id="lm-show-all-btn">' +
            '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
              '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/>' +
              '<line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>' +
            '</svg>' +
            ' Show all installed apps' +
          '</button>' +
          '<button class="lm-show-all-btn" id="lm-refresh-btn" style="display:none">' +
            '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
              '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/>' +
              '<path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>' +
            '</svg>' +
            ' Refresh application list' +
          '</button>' +
          '<div class="lm-status" id="lm-status"></div>' +
        '</div>' +
      '</div>' +
    '</div>';
  document.body.appendChild(wrapper.firstChild);

  // ---- State ----
  var _launchDn         = null;
  var _allAppsLoaded    = false;
  var _allApps          = [];
  var _favoritePackages = {};
  var _appNameCache     = {};
  var _statusResolver   = null;   // optional fn(dn) -> bool for ADB status

  function _isAdbUp() {
    return _statusResolver ? !!_statusResolver(_launchDn) : false;
  }

  // ---- Core functions ----
  function openLaunchModal(dn) {
    _launchDn      = dn;
    _allAppsLoaded = false;
    _allApps       = [];
    document.getElementById('lm-headset-label').textContent = dn.replace(/_/g, ' ');
    document.getElementById('lm-status').textContent = '';
    document.getElementById('lm-status').className   = 'lm-status';
    document.getElementById('lm-show-all-btn').disabled = false;
    document.getElementById('lm-show-all-btn').style.display = '';
    document.getElementById('lm-show-all-btn').innerHTML =
      '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
      '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/>' +
      '<line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>' +
      '</svg> Show all installed apps';
    document.getElementById('lm-refresh-btn').style.display = 'none';
    document.getElementById('lm-search-wrap').style.display = 'none';
    document.getElementById('lm-search').value = '';
    document.getElementById('app-launcher').style.display = 'flex';
    renderLaunchList([]);
    fetch('/api/favoriteapps?name=' + encodeURIComponent(_launchDn))
      .then(function (r) { return r.json(); })
      .then(function (favs) {
        _favoritePackages = {};
        favs.forEach(function (a) {
          _favoritePackages[a.package] = true;
          _appNameCache[a.package] = a.displayName;
        });
        renderLaunchList(favs, true);
      })
      .catch(function () {
        document.getElementById('lm-status').textContent = 'Could not load favorites.';
        document.getElementById('lm-status').className   = 'lm-status err';
      });
  }

  function closeLaunchModal() {
    document.getElementById('app-launcher').style.display = 'none';
    _launchDn = null;
  }

  function renderLaunchList(apps, isFavView) {
    var list = document.getElementById('lm-list');
    list.innerHTML = '';
    var metaHomePkg = 'com.oculus.vrshell';
    var hasMetaHome = apps.some(function (a) { return a.package === metaHomePkg; });
    var displayApps = apps.slice();
    if (!hasMetaHome && (isFavView || _allAppsLoaded)) {
      displayApps.unshift({ package: metaHomePkg, displayName: 'Meta Home', favorite: true });
    }
    if (displayApps.length === 0) {
      list.innerHTML = '<div class="lm-section-label" style="padding-top:14px;text-align:center">Loading...</div>';
      return;
    }
    if (isFavView && !_allAppsLoaded) {
      var s = document.createElement('div'); s.className = 'lm-section-label'; s.textContent = 'Favorites'; list.appendChild(s);
    }
    displayApps.forEach(function (app) { renderAppRow(app, list); });
  }

  function renderAppRow(app, list) {
    var metaHomePkg = 'com.oculus.vrshell';
    var isMeta = app.package === metaHomePkg;
    var isFav  = isMeta || !!_favoritePackages[app.package];
    var row = document.createElement('div');
    row.className = 'lm-app-row' + (isMeta ? ' is-meta' : '');

    var starBtn = document.createElement('button');
    starBtn.className = 'lm-star-btn' + (isFav ? ' active' : '');
    starBtn.title = isFav ? 'Remove from favorites' : 'Add to favorites';
    starBtn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="' + (isFav ? 'currentColor' : 'none') + '" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>';
    (function (a, sb) {
      sb.addEventListener('click', function (e) {
        e.stopPropagation();
        if (isMeta) return;
        var newFav = !_favoritePackages[a.package];
        if (newFav) { _favoritePackages[a.package] = true; } else { delete _favoritePackages[a.package]; }
        sb.className = 'lm-star-btn' + (newFav ? ' active' : '');
        sb.title = newFav ? 'Remove from favorites' : 'Add to favorites';
        sb.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="' + (newFav ? 'currentColor' : 'none') + '" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>';
        fetch('/api/togglefavorite', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: _launchDn, package: a.package, displayName: a.displayName, favorite: newFav })
        }).catch(function () {});
      });
    })(app, starBtn);

    var nameEl = document.createElement('span');
    nameEl.className = 'lm-app-name';
    nameEl.textContent = _appNameCache[app.package] || app.displayName || app.package;
    nameEl.title = app.package;

    var verEl = document.createElement('span');
    verEl.className = 'lm-app-version';
    verEl.textContent = app.version || '';

    var launchBtn = document.createElement('button');
    launchBtn.className = 'lm-launch-btn';
    launchBtn.innerHTML = '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"/></svg> Launch';
    (function (a, lb) {
      lb.addEventListener('click', function () { launchApp(_launchDn, a.package, a.displayName, lb); });
    })(app, launchBtn);

    row.appendChild(starBtn);
    row.appendChild(nameEl);
    row.appendChild(verEl);
    row.appendChild(launchBtn);
    list.appendChild(row);
  }

  function _renderAllApps(apps) {
    apps.forEach(function (a) {
      if (a.displayName) _appNameCache[a.package] = a.displayName;
      if (a.favorite) _favoritePackages[a.package] = true;
    });
    var list = document.getElementById('lm-list');
    list.innerHTML = '';
    var metaHomePkg = 'com.oculus.vrshell';
    var metaApp   = apps.find(function (a) { return a.package === metaHomePkg; }) || { package: metaHomePkg, displayName: 'Meta Home', favorite: true };
    var favApps   = apps.filter(function (a) { return a.package !== metaHomePkg && _favoritePackages[a.package]; });
    var otherApps = apps.filter(function (a) { return a.package !== metaHomePkg && !_favoritePackages[a.package]; });
    function addSection(label) { var s = document.createElement('div'); s.className = 'lm-section-label'; s.textContent = label; list.appendChild(s); }
    addSection('Meta Home');
    renderAppRow(metaApp, list);
    if (favApps.length)   { addSection('Favorites'); favApps.forEach(function (a) { renderAppRow(a, list); }); }
    if (otherApps.length) { addSection('All Apps');  otherApps.forEach(function (a) { renderAppRow(a, list); }); }
  }

  function _applySearch(query) {
    if (!_allAppsLoaded) return;
    var q = query.toLowerCase();
    var filtered = q ? _allApps.filter(function (a) {
      return (a.package || '').toLowerCase().indexOf(q) !== -1 ||
             ((_appNameCache[a.package] || a.displayName || '')).toLowerCase().indexOf(q) !== -1;
    }) : _allApps;
    _renderAllApps(filtered);
  }

  function launchApp(dn, pkg, displayName, btn) {
    if (!dn || !pkg) return;
    if (btn) btn.disabled = true;
    var statusEl = document.getElementById('lm-status');
    statusEl.textContent = 'Launching ' + (displayName || pkg) + '...';
    statusEl.className   = 'lm-status';
    fetch('/api/launchapp', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: dn, package: pkg })
    })
    .then(function (r) { return r.json(); })
    .then(function (j) {
      if (j.ok) {
        statusEl.textContent = (displayName || pkg) + ' launched successfully.';
        statusEl.className   = 'lm-status ok';
      } else {
        statusEl.textContent = 'Failed to launch ' + (displayName || pkg) + '.';
        statusEl.className   = 'lm-status err';
      }
      if (btn) btn.disabled = false;
      setTimeout(function () {
        if (statusEl.textContent.indexOf('launched successfully') !== -1) {
          statusEl.textContent = '';
          statusEl.className   = 'lm-status';
        }
      }, 3000);
    })
    .catch(function () {
      statusEl.textContent = 'Error communicating with server.';
      statusEl.className   = 'lm-status err';
      if (btn) btn.disabled = false;
    });
  }

  // ---- Event wiring (deferred until DOM ready) ----
  function init() {
    document.getElementById('lm-close').addEventListener('click', closeLaunchModal);
    document.getElementById('lm-search').addEventListener('input', function () { _applySearch(this.value.trim()); });
    document.getElementById('lm-search').addEventListener('search', function () { _applySearch(this.value.trim()); });
    document.getElementById('app-launcher').addEventListener('click', function (e) { if (e.target === this) closeLaunchModal(); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && _launchDn) closeLaunchModal(); });

    document.getElementById('lm-show-all-btn').addEventListener('click', function () {
      if (_allAppsLoaded || !_launchDn) return;
      var btn = this;
      btn.disabled = true;
      var statusEl = document.getElementById('lm-status');
      var adbUp = _isAdbUp();
      if (adbUp) {
        btn.textContent = 'Loading installed apps...';
        statusEl.textContent = 'Fetching app list from headset...';
      } else {
        btn.textContent = 'Loading cached apps...';
        statusEl.textContent = 'ADB offline - loading cached list...';
      }
      statusEl.className = 'lm-status';
      var url = '/api/installedapps?name=' + encodeURIComponent(_launchDn) + (adbUp ? '&refresh=1' : '');
      fetch(url)
        .then(function (r) { return r.json(); })
        .then(function (apps) {
          btn.disabled = false;
          if (!apps || !apps.length) {
            btn.textContent = 'Show all installed apps';
            statusEl.textContent = adbUp ? 'No apps found.' : 'ADB offline and no cached list available.';
            statusEl.className   = 'lm-status' + (adbUp ? '' : ' err');
            return;
          }
          _allAppsLoaded = true;
          _allApps = apps;
          statusEl.textContent = adbUp ? '' : 'Showing cached list (ADB offline).';
          statusEl.className   = 'lm-status';
          btn.style.display = 'none';
          document.getElementById('lm-refresh-btn').style.display = '';
          document.getElementById('lm-search-wrap').style.display = '';
          document.getElementById('lm-search').value = '';
          _renderAllApps(apps);
        })
        .catch(function () {
          btn.disabled = false;
          btn.innerHTML =
            '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
            '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/>' +
            '<line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>' +
            '</svg> Show all installed apps';
          statusEl.textContent = 'Could not load app list.';
          statusEl.className   = 'lm-status err';
        });
    });

    document.getElementById('lm-refresh-btn').addEventListener('click', function () {
      if (!_launchDn) return;
      var btn = this;
      btn.disabled = true;
      btn.textContent = 'Refreshing...';
      var statusEl = document.getElementById('lm-status');
      statusEl.textContent = 'Fetching app list and resolving names...';
      statusEl.className   = 'lm-status';
      fetch('/api/installedapps?name=' + encodeURIComponent(_launchDn) + '&refresh=1&resolveMissing=1')
        .then(function (r) { return r.json(); })
        .then(function (apps) {
          _allApps = apps;
          btn.disabled = false;
          btn.innerHTML =
            '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
            '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/>' +
            '<path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>' +
            '</svg> Refresh application list';
          statusEl.textContent = '';
          statusEl.className   = 'lm-status';
          _renderAllApps(apps);
        })
        .catch(function () {
          btn.disabled = false;
          btn.innerHTML =
            '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
            '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/>' +
            '<path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>' +
            '</svg> Refresh application list';
          statusEl.textContent = 'Refresh failed.';
          statusEl.className   = 'lm-status err';
        });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  window.openLaunchModal = openLaunchModal;
  window.appLauncher = {
    open: openLaunchModal,
    setStatusResolver: function (fn) { _statusResolver = fn; }
  };
})();
