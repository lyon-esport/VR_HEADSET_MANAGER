/* VR Headset Manager - Shared Topbar
 * Provides shared brand HTML, Config dropdown HTML, and dropdown JS behaviour.
 * Include in <head> before the page's own scripts.
 * Usage in <header class="topbar">:
 *   <script>document.write(TopBar.brandHTML)</script>
 *   ... (page-specific center section) ...
 *   <div class="topbar-right">
 *     ... (page-specific buttons) ...
 *     <script>document.write(TopBar.configMenuHTML)</script>
 *   </div>
 */
(function () {
  // Apply saved theme immediately to avoid flash of wrong theme
  try { if (localStorage.getItem('vrm-theme') === 'light') document.documentElement.setAttribute('data-theme', 'light'); } catch (e) {}

  var _filterCallback = null;

  var BRAND_SVG =
    '<svg width="16" height="16" viewBox="0 0 24 24" fill="none"' +
    ' stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/>' +
    '<circle cx="12" cy="12" r="3"/>' +
    '</svg>';

  var CHEVRON_SVG =
    '<svg class="chevron" width="12" height="12" viewBox="0 0 24 24" fill="none"' +
    ' stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">' +
    '<polyline points="6 9 12 15 18 9"/></svg>';

  var CHECK_SVG =
    '<svg class="item-check" width="12" height="12" viewBox="0 0 24 24" fill="none"' +
    ' stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">' +
    '<polyline points="20 6 9 17 4 12"/></svg>';

  window.TopBar = {
    brandHTML:
      '<a href="/" class="topbar-brand">' +
        BRAND_SVG +
        '<span class="topbar-btn-label">VR Headset Manager</span>' +
      '</a>',

    vsepHTML: '<div class="v-sep"></div>',

    // Compact dropdown shell — inject between v-sep and topbar-filters
    compactDropdownHTML:
      '<div class="headset-compact" id="headset-compact">' +
        '<button class="headset-compact-btn" id="headset-compact-toggle">' +
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
            '<rect x="2" y="3" width="20" height="14" rx="2"/><polyline points="8 21 12 17 16 21"/>' +
          '</svg>' +
          '<span class="topbar-btn-label">Filters</span>' +
          CHEVRON_SVG +
        '</button>' +
        '<div class="headset-compact-panel" id="headset-compact-panel"></div>' +
      '</div>',

    // Shared preset filter buttons — inject into .topbar-filters with document.write
    // IDs: filter-all, filter-online, filter-scrcpy, filter-offline
    // Wire actions with TopBar.initFilters(callback) or TopBar.setActiveFilter(id)
    filtersHTML:
      '<button class="filter-btn active" id="filter-all">' +
        '<span class="dot" style="background:#444"></span><span class="topbar-btn-label">All</span>' +
      '</button>' +
      '<button class="filter-btn" id="filter-online">' +
        '<span class="dot" style="background:#22c55e"></span><span class="topbar-btn-label">Online</span>' +
      '</button>' +
      '<button class="filter-btn" id="filter-scrcpy">' +
        '<span class="dot" style="background:#3b82f6"></span><span class="topbar-btn-label">Scrcpy</span>' +
      '</button>' +
      '<button class="filter-btn" id="filter-offline">' +
        '<span class="dot" style="background:#ef4444"></span><span class="topbar-btn-label">Offline</span>' +
      '</button>',

    // Wire the 4 preset filter buttons. onFilter(id) is called with the selected filter id.
    initFilters: function (onFilter) {
      _filterCallback = onFilter;
      var ids = ['all', 'online', 'scrcpy', 'offline'];
      document.addEventListener('DOMContentLoaded', function () {
        ids.forEach(function (id) {
          var btn = document.getElementById('filter-' + id);
          if (!btn) return;
          btn.addEventListener('click', function () {
            TopBar.triggerFilter(id);
          });
        });
      });
    },

    // Trigger a filter — updates active state AND calls the page callback
    triggerFilter: function (id) {
      TopBar.setActiveFilter(id);
      if (_filterCallback) _filterCallback(id);
    },

    // Set one preset button active, deactivate the others
    setActiveFilter: function (id) {
      ['all', 'online', 'scrcpy', 'offline'].forEach(function (b) {
        var el = document.getElementById('filter-' + b);
        if (el) el.classList.toggle('active', b === id);
      });
    },

    // Deactivate all preset buttons
    clearPresetFilters: function () {
      ['all', 'online', 'scrcpy', 'offline'].forEach(function (b) {
        var el = document.getElementById('filter-' + b);
        if (el) el.classList.remove('active');
      });
    },

    // Wire compact dropdown: open/close, overflow detection, and preset items.
    // Call once at boot. For per-headset items call addCompactDivider/addCompactItem after.
    initCompact: function () {
      document.addEventListener('DOMContentLoaded', function () {
        var toggle  = document.getElementById('headset-compact-toggle');
        var panel   = document.getElementById('headset-compact-panel');
        var topbar  = document.querySelector('.topbar');
        var filters = document.querySelector('.topbar-filters');
        if (!toggle || !panel) return;

        // Populate preset section
        var LABELS = { all: 'All', online: 'Online', scrcpy: 'Scrcpy', offline: 'Offline' };
        ['all', 'online', 'scrcpy', 'offline'].forEach(function (id) {
          var item = document.createElement('button');
          item.className = 'headset-compact-item';
          item.innerHTML = '<span class="item-check"></span>' + LABELS[id];
          item.addEventListener('click', function () {
            TopBar.triggerFilter(id);
            panel.classList.remove('open');
            toggle.classList.remove('open');
          });
          panel.appendChild(item);
        });

        // Toggle open / close
        toggle.addEventListener('click', function (e) {
          e.stopPropagation();
          var open = panel.classList.toggle('open');
          toggle.classList.toggle('open', open);
        });
        document.addEventListener('click', function () {
          panel.classList.remove('open');
          toggle.classList.remove('open');
        });

        // Overflow detection
        if (topbar && filters) {
          var check = function () {
            topbar.classList.remove('compact');
            topbar.classList.toggle('compact', filters.scrollWidth > filters.clientWidth);
          };
          new ResizeObserver(check).observe(topbar);
        }
      });
    },

    // Add a divider to the compact panel
    addCompactDivider: function () {
      var panel = document.getElementById('headset-compact-panel');
      if (!panel) return;
      var div = document.createElement('div');
      div.className = 'headset-compact-divider';
      panel.appendChild(div);
    },

    // Add a per-item entry to the compact panel
    addCompactItem: function (label, dn, checked, onClick) {
      var panel = document.getElementById('headset-compact-panel');
      if (!panel) return;
      var item = document.createElement('button');
      item.className = 'headset-compact-item' + (checked ? ' checked' : '');
      item.dataset.compactHeadset = dn;
      item.innerHTML = CHECK_SVG + label;
      item.addEventListener('click', onClick);
      panel.appendChild(item);
    },

    // Update a per-item compact entry's checked state
    setCompactItemChecked: function (dn, checked) {
      var item = document.querySelector('[data-compact-headset="' + dn + '"]');
      if (item) item.classList.toggle('checked', checked);
    },

    manageDevicesBtnHTML:
      '<button class="topbar-btn" id="headset-settings-btn" title="Headset Settings">' +
        '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
          '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/>' +
          '<line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/>' +
          '<line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/>' +
          '<line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>' +
        '</svg>' +
        '<span class="topbar-btn-label">Headset Settings</span>' +
      '</button>',

    // Wire the Headset Settings button.
    // If onOpen is provided it is called on click; otherwise navigates to /headset_settings.html.
    initManageDevicesBtn: function (onOpen) {
      document.addEventListener('DOMContentLoaded', function () {
        var btn = document.getElementById('headset-settings-btn');
        if (!btn) return;
        btn.addEventListener('click', function () {
          if (typeof onOpen === 'function') {
            onOpen();
          } else {
            window.location.href = '/headset_settings.html';
          }
        });
      });
    },

    configMenuHTML:
      '<div class="actions-menu" id="actions-menu">' +
        '<button class="actions-btn" id="actions-toggle">' +
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
            '<line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/>' +
          '</svg>' +
          '<span class="topbar-btn-label">Config</span>' +
          CHEVRON_SVG +
        '</button>' +
        '<div class="actions-dropdown" id="actions-dropdown">' +

          '<div class="drop-section">' +
            '<div class="drop-section-label">Navigate</div>' +
            '<a class="drop-item" href="/">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<polygon points="23 7 16 12 23 17 23 7"/><rect x="1" y="5" width="15" height="14" rx="2" ry="2"/>' +
              '</svg>' +
              'Video Monitor' +
            '</a>' +
            '<a class="drop-item" href="/headsets_monitoring.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="3" y1="15" x2="21" y2="15"/><line x1="9" y1="9" x2="9" y2="21"/>' +
              '</svg>' +
              'Headsets Monitoring' +
            '</a>' +
            '<a class="drop-item" href="/headset_settings.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/>' +
                '<line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/>' +
                '<line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/>' +
                '<line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>' +
              '</svg>' +
              'Headset Settings' +
            '</a>' +
          '</div>' +

          '<div class="drop-section">' +
            '<a class="drop-item" href="/headset_settings.html#manage">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>' +
              '</svg>' +
              'Manage New Devices' +
            '</a>' +
          '</div>' +

          '<div class="drop-section">' +
            '<a class="drop-item" href="/help.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/>' +
              '</svg>' +
              'Help &amp; Diagnostics' +
            '</a>' +
            '<a class="drop-item" href="/app_config.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<circle cx="12" cy="12" r="3"/>' +
                '<path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>' +
              '</svg>' +
              'App Configuration' +
            '</a>' +
          '</div>' +

          '<div class="drop-section">' +
            '<div class="drop-section-label">Display</div>' +
            '<button class="drop-item" id="theme-toggle-btn">' +
              '<svg class="drop-item-icon" id="theme-toggle-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<circle cx="12" cy="12" r="5"/>' +
                '<line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/>' +
                '<line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/>' +
                '<line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/>' +
                '<line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>' +
              '</svg>' +
              '<span id="theme-toggle-label">Light Mode</span>' +
            '</button>' +
          '</div>' +

        '</div>' +
      '</div>'
  };

  // Wire up Config dropdown toggle (runs after DOM is ready)
  document.addEventListener('DOMContentLoaded', function () {
    var toggle   = document.getElementById('actions-toggle');
    var dropdown = document.getElementById('actions-dropdown');
    if (!toggle || !dropdown) return;
    toggle.addEventListener('click', function (e) {
      e.stopPropagation();
      var open = dropdown.classList.toggle('open');
      toggle.classList.toggle('open', open);
    });
    document.addEventListener('click', function () {
      dropdown.classList.remove('open');
      toggle.classList.remove('open');
    });

    // Theme toggle
    function _updateThemeBtn() {      var lbl = document.getElementById('theme-toggle-label');
      var ico = document.getElementById('theme-toggle-icon');
      var isLight = document.documentElement.getAttribute('data-theme') === 'light';
      if (lbl) lbl.textContent = isLight ? 'Dark Mode' : 'Light Mode';
      if (ico) ico.innerHTML = isLight
        ? '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>'
        : '<circle cx="12" cy="12" r="5"/>' +
          '<line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/>' +
          '<line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/>' +
          '<line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/>' +
          '<line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>';
    }
    _updateThemeBtn();
    var themeBtn = document.getElementById('theme-toggle-btn');
    if (themeBtn) {
      themeBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        var isLight = document.documentElement.getAttribute('data-theme') === 'light';
        if (isLight) {
          document.documentElement.removeAttribute('data-theme');
          try { localStorage.setItem('vrm-theme', 'dark'); } catch (e) {}
        } else {
          document.documentElement.setAttribute('data-theme', 'light');
          try { localStorage.setItem('vrm-theme', 'light'); } catch (e) {}
        }
        _updateThemeBtn();
      });
    }
  });

  // Utility for pages: TopBar.apiPost(url, label, btn) - POST with visual feedback
  window.TopBar.apiPost = function(url, label, btn) {
    if (btn) { btn.disabled = true; btn.style.opacity = '0.6'; }
    var origHTML = btn ? btn.innerHTML : '';
    fetch(url, { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(j) {
        if (j && j.ok) {
          if (btn) btn.innerHTML = btn.innerHTML.replace(/>[^<]*(<\/button>)?$/, function(m) { return '>Done' + (m.indexOf('</') !== -1 ? '</button>' : ''); });
          setTimeout(function() { if (btn) { btn.innerHTML = origHTML; btn.disabled = false; btn.style.opacity = ''; } }, 2000);
        } else {
          if (btn) { btn.disabled = false; btn.style.opacity = ''; }
          alert((label || 'Action') + ' failed: ' + (j && j.error ? j.error : 'unknown error'));
        }
      })
      .catch(function() {
        if (btn) { btn.disabled = false; btn.style.opacity = ''; }
        alert((label || 'Action') + ': server unreachable.');
      });
  };

  // Placeholder kept for compatibility (modal moved to app_config.html)
  function _openLogsModal() {
    // Moved to app_config.html
  }

}());
