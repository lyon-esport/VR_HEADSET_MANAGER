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

  // Inject shared styles: responsive topbar rule + shutdown-all modal.
  (function () {
    var s = document.createElement('style');
    s.textContent = [
      '@media (max-width:700px){#topbar-vqa-warning-label{display:none!important}}',
      '.shutdown-all-modal{position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.72);display:flex;align-items:center;justify-content:center}',
      '.shutdown-all-modal__box{background:#1a1a1a;border:1px solid #333;border-radius:10px;min-width:300px;max-width:380px;width:90%;padding:24px 26px;display:flex;flex-direction:column;gap:14px;box-shadow:0 8px 32px rgba(0,0,0,.6)}',
      '.shutdown-all-modal__title{display:flex;align-items:center;gap:10px;font-size:14px;font-weight:700;color:#ef4444}',
      '.shutdown-all-modal__sub{font-size:12px;color:#9ca3af;line-height:1.5}',
      '.shutdown-all-modal__sub strong{color:#e0e0e0}',
      '.shutdown-all-modal__list{display:flex;flex-direction:column;gap:5px;max-height:160px;overflow-y:auto;padding:8px 10px;border-radius:6px;background:rgba(239,68,68,.07);border:1px solid rgba(239,68,68,.2)}',
      '.shutdown-all-modal__list-item{display:flex;align-items:center;gap:7px;font-size:12px;color:#e0e0e0;padding:4px 6px;border-radius:5px;cursor:pointer;user-select:none}',
      '.shutdown-all-modal__list-item:hover{background:rgba(239,68,68,.1)}',
      '.shutdown-all-modal__list-item input[type=checkbox]{accent-color:#ef4444;width:13px;height:13px;cursor:pointer;flex-shrink:0}',
      '.shutdown-all-modal__list-item svg{flex-shrink:0;color:#ef4444}',
      '.shutdown-all-modal__empty{font-size:12px;color:#9ca3af;text-align:center;padding:4px 0}',
      '.shutdown-all-modal__app-row{display:flex;align-items:center;gap:9px;padding:9px 11px;border-radius:7px;background:#111;border:1px solid #2a2a2a;cursor:pointer;user-select:none}',
      '.shutdown-all-modal__app-row input[type=checkbox]{accent-color:#ef4444;width:14px;height:14px;cursor:pointer;flex-shrink:0}',
      '.shutdown-all-modal__app-row span{font-size:12px;color:#9ca3af}',
      '.shutdown-all-modal__confirm-row{font-size:12px;color:#9ca3af}',
      '.shutdown-all-modal__confirm-row strong{color:#e5e7eb}',
      '.shutdown-all-modal__input{display:block;margin-top:8px;background:#111;border:1px solid #444;border-radius:6px;color:#e0e0e0;font-size:13px;padding:7px 10px;width:100%;box-sizing:border-box;letter-spacing:2px;outline:none}',
      '.shutdown-all-modal__input:focus{border-color:#ef4444}',
      '.shutdown-all-modal__actions{display:flex;justify-content:flex-end;gap:8px}',
      '.shutdown-all-modal__status{font-size:12px;color:#9ca3af;text-align:center}',
      '.vrhm-sd-btn{padding:7px 16px;border-radius:6px;border:1px solid #333;background:transparent;color:#9ca3af;font-size:13px;font-weight:600;cursor:pointer;transition:background .12s,color .12s,border-color .12s}',
      '.vrhm-sd-btn:hover{color:#ccc;border-color:#444}',
      '.vrhm-sd-btn.danger{border-color:rgba(239,68,68,.4);background:rgba(239,68,68,.15);color:#ef4444}',
      '.vrhm-sd-btn.danger:hover{background:rgba(239,68,68,.25)}',
      '.vrhm-sd-btn:disabled{opacity:.35;cursor:not-allowed;pointer-events:none}',
      '[data-theme=light] .shutdown-all-modal__box{background:#fff;border-color:#e0e0e0;box-shadow:0 8px 32px rgba(0,0,0,.12)}',
      '[data-theme=light] .shutdown-all-modal__sub{color:#6b7280}',
      '[data-theme=light] .shutdown-all-modal__sub strong{color:#111}',
      '[data-theme=light] .shutdown-all-modal__list{background:rgba(239,68,68,.05)}',
      '[data-theme=light] .shutdown-all-modal__list-item{color:#111}',
      '[data-theme=light] .shutdown-all-modal__app-row{background:#f9fafb;border-color:#e5e7eb}',
      '[data-theme=light] .shutdown-all-modal__app-row span{color:#374151}',
      '[data-theme=light] .shutdown-all-modal__confirm-row{color:#374151}',
      '[data-theme=light] .shutdown-all-modal__confirm-row strong{color:#111}',
      '[data-theme=light] .shutdown-all-modal__input{background:#f5f5f5;border-color:#ccc;color:#111}',
      '[data-theme=light] .vrhm-sd-btn{background:#e8e8e8;border-color:#ccc;color:#444}',
      '[data-theme=light] .vrhm-sd-btn:hover{background:#ddd;border-color:#aaa;color:#111}',
    ].join('');
    document.head.appendChild(s);
  }());

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
    // Brand + a hidden VQA warning icon to its right. The icon is shown by
    // TopBar.initVqaWarning() when VQA detects a mitigation condition and VQO
    // auto-apply is off. Click navigates to the Video Quality Automation page.
    brandHTML:
      '<a href="/" class="topbar-brand">' +
        BRAND_SVG +
        '<span class="topbar-btn-label">VR Headset Manager</span>' +
      '</a>' +
      '<a href="/headsets_monitoring.html#vqa-section" id="topbar-vqa-warning" ' +
         'title="Video quality mitigation needed" ' +
         'style="display:none;align-items:center;gap:6px;padding:4px 10px;margin-left:8px;' +
         'border-radius:6px;text-decoration:none;font-size:11px;font-weight:700;letter-spacing:0.04em;' +
         'background:rgba(250,204,21,0.18);color:#b45309;border:1px solid rgba(250,204,21,0.55);' +
         'transition:background 0.15s,color 0.15s,border-color 0.15s">' +
        '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
             'stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
          '<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>' +
          '<line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>' +
        '</svg>' +
        '<span id="topbar-vqa-warning-label">MITIGATION RECOMMENDED</span>' +
      '</a>',

    vsepHTML: '<div class="v-sep"></div>',

    // Compact filter dropdown shell — always visible
    compactDropdownHTML:
      '<div class="headset-filter-compact" id="headset-filter-compact">' +
        '<button class="headset-filter-compact-btn" id="headset-filter-compact-toggle">' +
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
            '<rect x="2" y="3" width="20" height="14" rx="2"/><polyline points="8 21 12 17 16 21"/>' +
          '</svg>' +
          '<span class="topbar-btn-label">Filters</span>' +
          CHEVRON_SVG +
        '</button>' +
        '<div class="headset-filter-compact-panel" id="headset-filter-compact-panel"></div>' +
      '</div>',

    // Shared preset filter buttons — inject into .topbar-filters with document.write
    // IDs: filter-all, filter-online, filter-scrcpy, filter-offline
    // Wire actions with TopBar.initFilters(callback) or TopBar.setActiveFilter(id)
    filtersHTML:
      '<button class="filter-btn active" id="filter-all">' +
        '<span class="dot" style="background:#666"></span><span class="topbar-btn-label">All</span>' +
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

    // Set one preset button active, deactivate the others (pill buttons + compact items)
    setActiveFilter: function (id) {
      ['all', 'online', 'scrcpy', 'offline'].forEach(function (b) {
        var el = document.getElementById('filter-' + b);
        if (el) el.classList.toggle('active', b === id);
        var cel = document.getElementById('compact-filter-' + b);
        if (cel) cel.classList.toggle('checked', b === id);
      });
    },

    // Deactivate all preset buttons
    clearPresetFilters: function () {
      ['all', 'online', 'scrcpy', 'offline'].forEach(function (b) {
        var el = document.getElementById('filter-' + b);
        if (el) el.classList.remove('active');
      });
    },

    // Wire compact filter dropdown: open/close and preset items with colored dots.
    // Call once at boot. For per-headset items call addCompactDivider/addCompactItem after.
    initCompact: function () {
      document.addEventListener('DOMContentLoaded', function () {
        var toggle = document.getElementById('headset-filter-compact-toggle');
        var panel  = document.getElementById('headset-filter-compact-panel');
        if (!toggle || !panel) return;

        // Populate preset section with colored dots
        var LABELS = { all: 'All', online: 'Online', scrcpy: 'Scrcpy', offline: 'Offline' };
        var DOTS   = { all: '#666', online: '#22c55e', scrcpy: '#3b82f6', offline: '#ef4444' };
        ['all', 'online', 'scrcpy', 'offline'].forEach(function (id) {
          var item = document.createElement('button');
          item.className = 'headset-filter-compact-item' + (id === 'all' ? ' checked' : '');
          item.id = 'compact-filter-' + id;
          item.innerHTML =
            CHECK_SVG +
            '<span style="width:8px;height:8px;border-radius:50%;background:' + DOTS[id] + ';flex-shrink:0;display:inline-block"></span>' +
            LABELS[id];
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
      });
    },

    // Add a divider to the compact panel
    addCompactDivider: function () {
      var panel = document.getElementById('headset-filter-compact-panel');
      if (!panel) return;
      var div = document.createElement('div');
      div.className = 'headset-filter-compact-divider';
      panel.appendChild(div);
    },

    // Add a per-headset entry to the compact panel
    addCompactItem: function (label, dn, checked, onClick) {
      var panel = document.getElementById('headset-filter-compact-panel');
      if (!panel) return;
      var item = document.createElement('button');
      item.className = 'headset-filter-compact-item' + (checked ? ' checked' : '');
      item.dataset.compactHeadset = dn;
      item.innerHTML = CHECK_SVG + label;
      item.addEventListener('click', onClick);
      panel.appendChild(item);
    },

    // Update a per-headset compact entry's checked state
    setCompactItemChecked: function (dn, checked) {
      var item = document.querySelector('[data-compact-headset="' + dn + '"]');
      if (item) item.classList.toggle('checked', checked);
    },

    monitoringBtnHTML:
      '<a class="topbar-btn" href="/headsets_monitoring.html" id="headsets-monitoring-btn" title="Headsets Monitoring">' +
        '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
          '<rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="3" y1="15" x2="21" y2="15"/><line x1="9" y1="9" x2="9" y2="21"/>' +
        '</svg>' +
        '<span class="topbar-btn-label">Monitoring</span>' +
      '</a>',

    manageDevicesBtnHTML:
      '<div class="headset-menu" id="headset-menu">' +
        '<a class="topbar-btn headset-menu-btn" href="/headsets_settings.html" id="headset-settings-btn" title="Headset Settings">' +
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
            '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/>' +
            '<line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/>' +
            '<line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/>' +
            '<line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>' +
          '</svg>' +
          '<span class="topbar-btn-label">Headset Settings</span>' +
          CHEVRON_SVG +
        '</a>' +
        '<div class="headset-menu-dropdown" id="headset-menu-dropdown">' +

          '<div class="drop-section">' +
            '<a class="drop-item" href="/headsets_settings.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/>' +
                '<line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/>' +
                '<line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/>' +
                '<line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>' +
              '</svg>' +
              'Headset Settings' +
            '</a>' +
            '<a class="drop-item" href="/headsets_settings.html#manage">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>' +
              '</svg>' +
              'Add New Headset' +
            '</a>' +
            '<a class="drop-item" href="/vrhm_config.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<polygon points="12 2 2 7 12 12 22 7 12 2"/>' +
                '<polyline points="2 17 12 22 22 17"/>' +
                '<polyline points="2 12 12 17 22 12"/>' +
              '</svg>' +
              'Manage Scrcpy Capture Profiles' +
            '</a>' +
          '</div>' +

          '<div class="drop-section">' +
            '<div class="drop-section-label">Quick Actions</div>' +
            '<button class="drop-item" id="hs-start-all-btn">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<polygon points="5 3 19 12 5 21 5 3"/>' +
              '</svg>' +
              'Start Scrcpy for All Headsets' +
            '</button>' +
            '<button class="drop-item" id="hs-stop-all-btn">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<rect x="3" y="3" width="18" height="18" rx="2" ry="2"/>' +
              '</svg>' +
              'Stop Scrcpy for All Headsets' +
            '</button>' +
            '<button class="drop-item drop-item-danger" id="hs-shutdown-all-btn">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<path d="M18.36 6.64a9 9 0 1 1-12.73 0"/>' +
                '<line x1="12" y1="2" x2="12" y2="12"/>' +
              '</svg>' +
              'Shutdown All Headsets' +
            '</button>' +
          '</div>' +

        '</div>' +
      '</div>',

    // Wire the Headset Settings button (kept for backward compatibility).
    // If onOpen is provided it is called on click; otherwise navigates to /headsets_settings.html.
    initManageDevicesBtn: function (onOpen) {
      document.addEventListener('DOMContentLoaded', function () {
        var btn = document.getElementById('headset-settings-btn');
        if (!btn) return;
        if (typeof onOpen === 'function') {
          btn.addEventListener('click', function (e) { e.preventDefault(); onOpen(); });
        }
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
            '<a class="drop-item" href="/headsets_settings.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/>' +
                '<line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/>' +
                '<line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/>' +
                '<line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>' +
              '</svg>' +
              'Headset Settings' +
            '</a>' +
            '<a class="drop-item" href="/kiosk_screens.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>' +
              '</svg>' +
              'Kiosk Screens' +
            '</a>' +
          '</div>' +

          '<div class="drop-section">' +
            '<div class="drop-section-label">Applications Management</div>' +
            '<a class="drop-item" href="/headsets_apps_manager.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/>' +
                '<path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>' +
              '</svg>' +
              'Headsets Apps' +
            '</a>' +
            '<a class="drop-item" href="/known_apps_manager.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/>' +
                '<rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>' +
              '</svg>' +
              'Known Apps' +
            '</a>' +
          '</div>' +

          '<div class="drop-section">' +
            '<a class="drop-item" href="/headsets_settings.html#manage">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>' +
              '</svg>' +
              'Add New Headset' +
            '</a>' +
          '</div>' +

          '<div class="drop-section">' +
            '<a class="drop-item" href="/help.html">' +
              '<svg class="drop-item-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/>' +
              '</svg>' +
              'Help &amp; Diagnostics' +
            '</a>' +
            '<a class="drop-item" href="/vrhm_config.html">' +
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
      '</div>',

    // Show / hide / repaint the VQA warning chip in the brand area based on the
    // current recommendation snapshot. Called once at page load by initVqaWarning,
    // then on a 30 s poll.
    _vqaWarningUpdate: function () {
      var el = document.getElementById('topbar-vqa-warning');
      if (!el) return;
      fetch('/api/vqa/status').then(function (r) { return r.json(); }).then(function (s) {
        // Hidden when VQA is disabled OR when the derived VQO badge is ON (operator
        // chose auto-apply for at least one section, so a warning would just be noise).
        if (!s.enabled || s.enabled_vqo) { el.style.display = 'none'; return; }
        return fetch('/data/vqa_recommendation.json?_=' + Date.now())
          .then(function (r) { return r.ok ? r.json() : null; })
          .then(function (d) {
            if (!d || !d.Thresholds) { el.style.display = 'none'; return; }
            // Cooldown takes precedence: while the system is settling after an apply
            // or flag toggle, suppress the warning entirely.
            if ((d.CooldownRemaining || 0) > 0) { el.style.display = 'none'; return; }
            var max  = (d.Cpu >= d.Thresholds.CpuMax        || d.Gpu >= d.Thresholds.GpuMax);
            var mit  = (d.Cpu >= d.Thresholds.CpuMitigation || d.Gpu >= d.Thresholds.GpuMitigation);
            var lbl  = document.getElementById('topbar-vqa-warning-label');
            if (max) {
              el.style.display       = 'inline-flex';
              el.style.background    = '#dc2626';
              el.style.color         = '#ffffff';
              el.style.borderColor   = '#dc2626';
              if (lbl) lbl.textContent = 'MITIGATION REQUIRED';
              el.title = 'CPU/GPU above maximum threshold - immediate quality reduction required';
            } else if (mit) {
              el.style.display       = 'inline-flex';
              el.style.background    = 'rgba(250,204,21,0.18)';
              el.style.color         = '#b45309';
              el.style.borderColor   = 'rgba(250,204,21,0.55)';
              if (lbl) lbl.textContent = 'MITIGATION RECOMMENDED';
              el.title = 'CPU/GPU above mitigation threshold - quality reduction recommended';
            } else {
              el.style.display = 'none';
            }
          });
      }).catch(function () { /* api or json unreachable - leave hidden */ });
    },

    // Public initializer. Self-invoked below so individual pages do not need to
    // call it - the chip just maintains itself everywhere the topbar is used.
    initVqaWarning: function () {
      document.addEventListener('DOMContentLoaded', function () { TopBar._vqaWarningUpdate(); });
      setInterval(function () { TopBar._vqaWarningUpdate(); }, 30000);
    }
  };

  // Auto-init the VQA warning chip for every page that loads topbar.js.
  TopBar.initVqaWarning();

  // Auto-highlight the topbar button/dropdown item matching the current page.
  document.addEventListener('DOMContentLoaded', function () {
    var path = window.location.pathname.replace(/\/$/, '') || '/';

    // Pages that have a dedicated standalone topbar button
    var BTN_MAP = {
      '/headsets_monitoring.html': 'headsets-monitoring-btn',
      '/headsets_settings.html':   'headset-settings-btn'
    };

    if (BTN_MAP[path]) {
      var btn = document.getElementById(BTN_MAP[path]);
      if (btn) btn.classList.add('active');
    }

    // Highlight any dropdown item whose href matches (strip hash anchors before comparing)
    var anyDropActive = false;
    document.querySelectorAll('.drop-item[href]').forEach(function (a) {
      var href = a.getAttribute('href').split('#')[0];
      if (href === path) { a.classList.add('active'); anyDropActive = true; }
    });

    // If the active page has no standalone button, highlight Config toggle as a hint
    if (anyDropActive && !BTN_MAP[path]) {
      var configBtn = document.getElementById('actions-toggle');
      if (configBtn) configBtn.classList.add('active');
    }
  });

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

    // Headset Settings dropdown quick-action buttons
    function _refreshHeadsetPage() {
      if (typeof pollHeadsetsCsv === 'function') pollHeadsetsCsv();
      if (typeof pollInfosCsv    === 'function') pollInfosCsv();
    }
    var hsStartAll = document.getElementById('hs-start-all-btn');
    if (hsStartAll) {
      hsStartAll.addEventListener('click', function (e) {
        e.stopPropagation();
        TopBar.apiPost('/api/start-scrcpy-all', 'Start Scrcpy All', hsStartAll, _refreshHeadsetPage);
      });
    }
    var hsStopAll = document.getElementById('hs-stop-all-btn');
    if (hsStopAll) {
      hsStopAll.addEventListener('click', function (e) {
        e.stopPropagation();
        TopBar.apiPost('/api/stop-scrcpy-all', 'Stop Scrcpy All', hsStopAll, _refreshHeadsetPage);
      });
    }
    var hsShutdownAll = document.getElementById('hs-shutdown-all-btn');
    if (hsShutdownAll) {
      hsShutdownAll.addEventListener('click', function (e) {
        e.stopPropagation();
        if (typeof TopBar._shutdownAllOverride === 'function') {
          TopBar._shutdownAllOverride();
        } else {
          TopBar._showShutdownAllModal(hsShutdownAll);
        }
      });
    }

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

    // Cross-tab theme sync: update this page when another tab changes the theme
    try {
      window.addEventListener('storage', function(e) {
        if (e.key !== 'vrm-theme') return;
        if (e.newValue === 'light') {
          document.documentElement.setAttribute('data-theme', 'light');
        } else {
          document.documentElement.removeAttribute('data-theme');
        }
        _updateThemeBtn();
      });
    } catch(e) {}
  });

  // Utility for pages: TopBar.apiPost(url, label, btn, onSuccess) - POST with visual feedback
  // onSuccess is an optional callback called after a successful response.
  window.TopBar.apiPost = function(url, label, btn, onSuccess) {
    if (btn) { btn.disabled = true; btn.style.opacity = '0.6'; }
    var origHTML = btn ? btn.innerHTML : '';
    fetch(url, { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(j) {
        if (j && j.ok) {
          if (btn) btn.innerHTML = btn.innerHTML.replace(/>[^<]*(<\/button>)?$/, function(m) { return '>Done' + (m.indexOf('</') !== -1 ? '</button>' : ''); });
          setTimeout(function() { if (btn) { btn.innerHTML = origHTML; btn.disabled = false; btn.style.opacity = ''; } }, 2000);
          if (typeof onSuccess === 'function') onSuccess();
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

  // Shutdown-all modal: headset checklist + YES guard + optional app shutdown.
  // CSS is injected by the style block above; HTML uses .shutdown-all-modal__ classes
  // shared with headsets_settings.html so both entry points render identically.
  window.TopBar._showShutdownAllModal = function() {
    var existing = document.getElementById('vrhm-shutdown-modal');
    if (existing) existing.remove();

    var powerIcon = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>';

    var overlay = document.createElement('div');
    overlay.id        = 'vrhm-shutdown-modal';
    overlay.className = 'shutdown-all-modal';
    overlay.innerHTML =
      '<div class="shutdown-all-modal__box">' +
        '<div class="shutdown-all-modal__title">' +
          '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/>' +
          '</svg>Shutdown ALL headsets?' +
        '</div>' +
        '<div class="shutdown-all-modal__sub">This will power off every ADB-connected headset.</div>' +
        '<div id="vrhm-sd-list"></div>' +
        '<label class="shutdown-all-modal__app-row" id="vrhm-sd-app-row">' +
          '<input type="checkbox" id="vrhm-sd-app-chk">' +
          '<span>Also shutdown VRHM application</span>' +
        '</label>' +
        '<div class="shutdown-all-modal__confirm-row" id="vrhm-sd-confirm-row">' +
          'Type <strong>YES</strong> to confirm:' +
          '<input class="shutdown-all-modal__input" id="vrhm-sd-input" type="text" placeholder="YES" autocomplete="off" spellcheck="false">' +
        '</div>' +
        '<div class="shutdown-all-modal__actions">' +
          '<button class="vrhm-sd-btn" id="vrhm-sd-cancel">Cancel</button>' +
          '<button class="vrhm-sd-btn danger" id="vrhm-sd-confirm" disabled>Shutdown All</button>' +
        '</div>' +
        '<div class="shutdown-all-modal__status" id="vrhm-sd-status" style="display:none"></div>' +
      '</div>';

    document.body.appendChild(overlay);

    var listEl    = document.getElementById('vrhm-sd-list');
    var inputEl   = document.getElementById('vrhm-sd-input');
    var appChk    = document.getElementById('vrhm-sd-app-chk');
    var confirmBtn= document.getElementById('vrhm-sd-confirm');
    var cancelBtn = document.getElementById('vrhm-sd-cancel');
    var statusEl  = document.getElementById('vrhm-sd-status');

    function updateBtn() {
      var anyHeadset = !!listEl.querySelector('.vrhm-sd-chk:checked');
      var ok = inputEl.value === 'YES' && (anyHeadset || appChk.checked);
      confirmBtn.disabled = !ok;
    }

    function renderList(connected) {
      if (!connected || connected.length === 0) {
        listEl.innerHTML = '<div class="shutdown-all-modal__empty">No connected headset to shutdown.</div>';
        return;
      }
      var items = connected.map(function(dn) {
        var safe = dn.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
        return '<label class="shutdown-all-modal__list-item">' +
          '<input type="checkbox" class="vrhm-sd-chk" data-dn="' + safe + '" checked>' +
          powerIcon + dn.replace(/_/g, ' ') + '</label>';
      }).join('');
      listEl.innerHTML = '<div class="shutdown-all-modal__list">' + items + '</div>';
      listEl.addEventListener('change', updateBtn);
    }

    // Fetch connected headsets - API returns an array of {display_name, adb, ...}
    fetch('/api/headsets-status').then(function(r) { return r.json(); }).then(function(items) {
      var connected = [];
      if (Array.isArray(items)) {
        items.forEach(function(item) {
          if (item && item.adb && item.display_name) connected.push(item.display_name);
        });
      }
      renderList(connected);
      updateBtn();
      setTimeout(function() { if (inputEl) inputEl.focus(); }, 50);
    }).catch(function() {
      listEl.innerHTML = '<div class="shutdown-all-modal__empty">Could not load headset status.</div>';
      updateBtn();
    });

    inputEl.addEventListener('input', updateBtn);
    appChk.addEventListener('change', updateBtn);

    function close() { overlay.remove(); }
    cancelBtn.addEventListener('click', close);
    overlay.addEventListener('click', function(e) { if (e.target === overlay) close(); });
    document.addEventListener('keydown', function onEsc(e) {
      if (e.key === 'Escape' && document.getElementById('vrhm-shutdown-modal')) { close(); document.removeEventListener('keydown', onEsc); }
    });

    confirmBtn.addEventListener('click', function() {
      var alsoShutdownApp = appChk.checked;
      var selected = Array.from(listEl.querySelectorAll('.vrhm-sd-chk:checked')).map(function(c) { return c.dataset.dn; });
      statusEl.style.display = 'block';
      confirmBtn.disabled = true;
      cancelBtn.disabled  = true;

      if (selected.length === 0) {
        statusEl.textContent = alsoShutdownApp ? 'Shutting down application...' : 'Nothing to do.';
        if (alsoShutdownApp) fetch('/api/app-shutdown', { method: 'POST' }).catch(function() {});
        setTimeout(close, 1500);
        return;
      }

      statusEl.textContent = 'Shutting down selected headsets...';
      fetch('/api/shutdown-all', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ headsets: selected, alsoShutdownApp: alsoShutdownApp })
      }).then(function(r) { return r.json(); }).then(function(data) {
        statusEl.textContent = data.ok ? 'Done. Selected headsets shutting down.' : ('Error: ' + (data.error || 'unknown'));
        cancelBtn.disabled = false;
        setTimeout(close, 2000);
      }).catch(function() {
        statusEl.textContent = 'Request failed.';
        cancelBtn.disabled = false;
      });
    });
  };

  // Placeholder kept for compatibility (modal moved to vrhm_config.html)
  function _openLogsModal() {
    // Moved to vrhm_config.html
  }

}());
