'use strict';

// Feather — a lightweight Chromium (Electron 26 / Chromium 116) browser that
// still runs on macOS 10.14 Mojave. Electron 26 is the last release whose
// Chromium supports Mojave; Chromium 117+ requires macOS 10.15.

const {
  app, BrowserWindow, BrowserView, Menu, ipcMain, session, shell, dialog,
} = require('electron');
const path = require('path');

// ---------------------------------------------------------------------------
// Memory-saving switches (must be set before the app is ready)
// ---------------------------------------------------------------------------
// Cap the number of renderer processes; extra tabs share processes instead of
// each spawning a new ~100 MB renderer.
app.commandLine.appendSwitch('renderer-process-limit', '4');
// Don't keep a whole extra copy of pages around for back/forward.
app.commandLine.appendSwitch('disable-features',
  'BackForwardCache,MediaRouter,DialMediaRouteProvider,Translate,OptimizationHints,InterestFeedContentSuggestions');
// Let V8 return memory to the OS more aggressively.
app.commandLine.appendSwitch('js-flags', '--optimize-for-size');

const HOME_URL = 'https://duckduckgo.com/';
const SEARCH_URL = 'https://duckduckgo.com/?q=';
const UI_HEIGHT = 78;                 // tab strip + toolbar, in px
// Background tabs are put to sleep (renderer freed) after 10 minutes.
// Override with FEATHER_TAB_SLEEP_SECONDS=<n> (0 disables sleeping).
const SLEEP_AFTER_MS = (Number(process.env.FEATHER_TAB_SLEEP_SECONDS) >= 0 &&
  process.env.FEATHER_TAB_SLEEP_SECONDS !== undefined && process.env.FEATHER_TAB_SLEEP_SECONDS !== ''
  ? Number(process.env.FEATHER_TAB_SLEEP_SECONDS) : 600) * 1000;
const SLEEP_CHECK_MS = Math.min(60 * 1000, Math.max(1000, SLEEP_AFTER_MS / 2));

// Look like regular Chrome so sites don't block the "Electron" user agent.
app.userAgentFallback = app.userAgentFallback
  .replace(/ Electron\/\S+/, '')
  .replace(/ feather-browser\/\S+/i, '')
  .replace(/ Feather\/\S+/, '');

/** @type {Map<BrowserWindow, WindowState>} */
const windows = new Map();
let nextTabId = 1;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function toUrl(input) {
  const text = String(input || '').trim();
  if (!text) return HOME_URL;
  if (/^(https?|file|about|data|chrome):/i.test(text)) return text;
  // Looks like a host (has a dot or is localhost[:port]) and contains no spaces.
  if (!/\s/.test(text) && (/^[^/]+\.[a-z]{2,}(?::\d+)?(\/.*)?$/i.test(text) ||
      /^localhost(:\d+)?(\/.*)?$/i.test(text) ||
      /^\d{1,3}(\.\d{1,3}){3}(:\d+)?(\/.*)?$/.test(text))) {
    return (/^localhost|^\d/.test(text) ? 'http://' : 'https://') + text;
  }
  return SEARCH_URL + encodeURIComponent(text);
}

function isSafeExternal(url) {
  return /^(mailto|tel|facetime|itms-apps|macappstore|zoommtg|slack|spotify):/i.test(url);
}

// ---------------------------------------------------------------------------
// Window + tabs
// ---------------------------------------------------------------------------
class WindowState {
  constructor(win) {
    this.win = win;
    /** @type {Array<Tab>} */
    this.tabs = [];
    this.activeId = null;
  }

  get active() {
    return this.tabs.find((t) => t.id === this.activeId) || null;
  }

  layout() {
    const tab = this.active;
    if (!tab || !tab.view) return;
    const [width, height] = this.win.getContentSize();
    tab.view.setBounds({ x: 0, y: UI_HEIGHT, width, height: Math.max(0, height - UI_HEIGHT) });
  }

  send() {
    if (this.win.isDestroyed()) return;
    this.win.webContents.send('tabs', {
      activeId: this.activeId,
      tabs: this.tabs.map((t) => t.snapshot()),
    });
    const tab = this.active;
    this.win.setTitle(tab ? `${tab.title || 'New Tab'} — Feather` : 'Feather');
  }

  newTab(url = HOME_URL, { background = false } = {}) {
    const tab = new Tab(this, url);
    const idx = this.tabs.findIndex((t) => t.id === this.activeId);
    this.tabs.splice(idx < 0 ? this.tabs.length : idx + 1, 0, tab);
    if (!background || !this.activeId) this.activate(tab.id);
    else this.send();
    return tab;
  }

  activate(id) {
    const tab = this.tabs.find((t) => t.id === id);
    if (!tab) return;
    const prev = this.active;
    if (prev && prev !== tab && prev.view) {
      this.win.removeBrowserView(prev.view);
      prev.lastActive = Date.now();
    }
    this.activeId = id;
    tab.wake();
    this.win.addBrowserView(tab.view);
    this.layout();
    tab.lastActive = Date.now();
    if (tab.url === HOME_URL && !tab.loading) this.focusAddressBar();
    else tab.view.webContents.focus();
    this.send();
  }

  close(id) {
    const i = this.tabs.findIndex((t) => t.id === id);
    if (i < 0) return;
    const [tab] = this.tabs.splice(i, 1);
    if (tab.view) this.win.removeBrowserView(tab.view);
    tab.destroy();
    if (this.tabs.length === 0) {
      this.win.close();
      return;
    }
    if (this.activeId === id) {
      this.activeId = null;
      this.activate(this.tabs[Math.min(i, this.tabs.length - 1)].id);
    } else {
      this.send();
    }
  }

  focusAddressBar() {
    this.win.webContents.focus();
    this.win.webContents.send('focus-address');
  }

  sleepIdleTabs() {
    const now = Date.now();
    for (const tab of this.tabs) {
      if (tab.id === this.activeId || !tab.view) continue;
      const wc = tab.view.webContents;
      if (wc.isCurrentlyAudible()) { tab.lastActive = now; continue; }
      if (now - tab.lastActive > SLEEP_AFTER_MS) tab.sleep();
    }
  }
}

class Tab {
  constructor(state, url) {
    this.state = state;
    this.id = nextTabId++;
    this.url = toUrl(url);
    this.title = 'New Tab';
    this.favicon = null;
    this.loading = false;
    this.lastActive = Date.now();
    this.view = null;
    this.wake();
  }

  snapshot() {
    const wc = this.view && this.view.webContents;
    return {
      id: this.id,
      url: this.url,
      title: this.title,
      favicon: this.favicon,
      loading: this.loading,
      asleep: !this.view,
      canGoBack: !!wc && wc.canGoBack(),
      canGoForward: !!wc && wc.canGoForward(),
      audible: !!wc && wc.isCurrentlyAudible(),
    };
  }

  wake() {
    if (this.view) return;
    this.view = new BrowserView({
      webPreferences: {
        partition: 'persist:feather',
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        spellcheck: false,
        backgroundThrottling: true,
        enableWebSQL: false,
        autoplayPolicy: 'document-user-activation-required',
      },
    });
    this.view.setBackgroundColor('#ffffff');
    this.bind(this.view.webContents);
    this.view.webContents.loadURL(this.url).catch(() => {});
  }

  /** Free the renderer process, keep only url/title/favicon. */
  sleep() {
    if (!this.view) return;
    const wc = this.view.webContents;
    this.url = wc.getURL() || this.url;
    if (this.state.win.getBrowserViews().includes(this.view)) {
      this.state.win.removeBrowserView(this.view);
    }
    this.view = null;
    this.loading = false;
    if (!wc.isDestroyed()) wc.close();
    this.state.send();
  }

  destroy() {
    if (!this.view) return;
    const wc = this.view.webContents;
    this.view = null;
    if (!wc.isDestroyed()) wc.close();
  }

  bind(wc) {
    const update = () => this.state.send();
    const isActive = () => this.state.activeId === this.id;

    wc.on('did-start-loading', () => { this.loading = true; update(); });
    wc.on('did-stop-loading', () => { this.loading = false; update(); });
    wc.on('page-title-updated', (_e, title) => { this.title = title; update(); });
    wc.on('page-favicon-updated', (_e, icons) => { this.favicon = icons[0] || null; update(); });
    wc.on('media-started-playing', update);
    wc.on('media-paused', update);
    const onNav = (_e, url) => { this.url = url; update(); };
    wc.on('did-navigate', (e, url) => { this.favicon = null; onNav(e, url); });
    wc.on('did-navigate-in-page', (e, url, isMainFrame) => { if (isMainFrame) onNav(e, url); });
    wc.on('did-fail-load', (_e, code, desc, url, isMainFrame) => {
      if (!isMainFrame || code === -3 /* ABORTED */) return;
      this.title = 'Can’t open page';
      const html = `<!doctype html><meta charset="utf-8"><title>Can’t open page</title>
        <body style="font:15px -apple-system,sans-serif;color:#333;padding:12vh 10vw">
        <h2 style="font-weight:600">Feather can’t open this page</h2>
        <p>${String(url).replace(/[<>&"]/g, '')}</p><p style="color:#888">${desc} (${code})</p></body>`;
      wc.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html), { baseURLForDataURL: url }).catch(() => {});
      update();
    });
    wc.on('found-in-page', (_e, r) => {
      if (isActive() && !this.state.win.isDestroyed()) {
        this.state.win.webContents.send('find-result', { current: r.activeMatchOrdinal, total: r.matches });
      }
    });
    wc.on('render-process-gone', () => { this.title = 'Page crashed — reload'; this.loading = false; update(); });

    // window.open / target=_blank → new tab (never a new native window).
    wc.setWindowOpenHandler(({ url, disposition }) => {
      if (isSafeExternal(url)) { shell.openExternal(url); return { action: 'deny' }; }
      this.state.newTab(url, { background: disposition === 'background-tab' });
      return { action: 'deny' };
    });
    wc.on('will-navigate', (e, url) => {
      if (isSafeExternal(url)) { e.preventDefault(); shell.openExternal(url); }
    });

    wc.on('enter-html-full-screen', () => { this.state.win.setFullScreen(true); });
    wc.on('leave-html-full-screen', () => {
      this.state.win.setFullScreen(false);
    });

    wc.on('before-input-event', (event, input) => {
      // Escape while the page has focus stops loading.
      if (input.type === 'keyDown' && input.key === 'Escape' && this.loading && isActive()) wc.stop();
    });
  }
}

function createWindow(url) {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 480,
    minHeight: 320,
    title: 'Feather',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 12, y: 12 },
    backgroundColor: '#e9e9ed',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });
  const state = new WindowState(win);
  windows.set(win, state);

  win.loadFile(path.join(__dirname, 'ui', 'index.html'));
  win.webContents.once('did-finish-load', () => {
    state.newTab(url || HOME_URL);
    win.show();
  });
  win.on('resize', () => state.layout());
  win.on('enter-full-screen', () => { win.webContents.send('fullscreen', true); state.layout(); });
  win.on('leave-full-screen', () => { win.webContents.send('fullscreen', false); state.layout(); });
  win.on('closed', () => {
    for (const t of state.tabs) t.destroy();
    windows.delete(win);
  });
  return state;
}

function stateFor(sender) {
  const win = BrowserWindow.fromWebContents(sender);
  return win ? windows.get(win) : null;
}

function focusedState() {
  const win = BrowserWindow.getFocusedWindow();
  return (win && windows.get(win)) || [...windows.values()].pop() || null;
}

// ---------------------------------------------------------------------------
// IPC from the toolbar UI
// ---------------------------------------------------------------------------
ipcMain.on('ui', (event, cmd, arg) => {
  const state = stateFor(event.sender);
  if (!state) return;
  const tab = state.active;
  const wc = tab && tab.view && tab.view.webContents;
  switch (cmd) {
    case 'new-tab': state.newTab(arg || HOME_URL); break;
    case 'close-tab': state.close(arg); break;
    case 'activate': state.activate(arg); break;
    case 'navigate':
      if (tab) {
        tab.url = toUrl(arg);
        tab.wake();
        tab.view.webContents.loadURL(tab.url).catch(() => {});
        tab.view.webContents.focus();
      }
      break;
    case 'back': if (wc && wc.canGoBack()) wc.goBack(); break;
    case 'forward': if (wc && wc.canGoForward()) wc.goForward(); break;
    case 'reload': if (wc) wc.reload(); break;
    case 'stop': if (wc) wc.stop(); break;
    case 'home': if (wc) wc.loadURL(HOME_URL).catch(() => {}); break;
    case 'focus-page': if (wc) wc.focus(); break;
    case 'find':
      // Electron 26 only emits 'found-in-page' when findNext is true.
      if (wc && arg && arg.text) wc.findInPage(arg.text, { forward: arg.forward !== false, findNext: true });
      break;
    case 'find-stop': if (wc) wc.stopFindInPage('clearSelection'); break;
    default: break;
  }
});

// ---------------------------------------------------------------------------
// Menu + keyboard shortcuts
// ---------------------------------------------------------------------------
function withActive(fn) {
  return () => {
    const state = focusedState();
    const wc = state && state.active && state.active.view && state.active.view.webContents;
    if (wc) fn(wc, state);
  };
}

function buildMenu() {
  const tabShortcuts = [];
  for (let n = 1; n <= 9; n++) {
    tabShortcuts.push({
      label: n === 9 ? 'Last Tab' : `Tab ${n}`,
      accelerator: `CmdOrCtrl+${n}`,
      visible: false,
      click: () => {
        const s = focusedState();
        if (!s || !s.tabs.length) return;
        const t = n === 9 ? s.tabs[s.tabs.length - 1] : s.tabs[n - 1];
        if (t) s.activate(t.id);
      },
    });
  }
  const cycle = (dir) => () => {
    const s = focusedState();
    if (!s || s.tabs.length < 2) return;
    const i = s.tabs.findIndex((t) => t.id === s.activeId);
    s.activate(s.tabs[(i + dir + s.tabs.length) % s.tabs.length].id);
  };

  const template = [
    { role: 'appMenu' },
    {
      label: 'File',
      submenu: [
        { label: 'New Tab', accelerator: 'CmdOrCtrl+T', click: () => { const s = focusedState(); if (s) s.newTab(); else createWindow(); } },
        { label: 'New Window', accelerator: 'CmdOrCtrl+N', click: () => createWindow() },
        { label: 'Open Location…', accelerator: 'CmdOrCtrl+L', click: () => { const s = focusedState(); if (s) s.focusAddressBar(); } },
        { type: 'separator' },
        { label: 'Close Tab', accelerator: 'CmdOrCtrl+W', click: () => { const s = focusedState(); if (s && s.activeId) s.close(s.activeId); } },
        { label: 'Close Window', accelerator: 'CmdOrCtrl+Shift+W', click: () => { const w = BrowserWindow.getFocusedWindow(); if (w) w.close(); } },
      ],
    },
    { role: 'editMenu' },
    {
      label: 'View',
      submenu: [
        { label: 'Reload', accelerator: 'CmdOrCtrl+R', click: withActive((wc) => wc.reload()) },
        { label: 'Force Reload', accelerator: 'CmdOrCtrl+Shift+R', click: withActive((wc) => wc.reloadIgnoringCache()) },
        { label: 'Stop', accelerator: 'CmdOrCtrl+.', click: withActive((wc) => wc.stop()) },
        { type: 'separator' },
        { label: 'Actual Size', accelerator: 'CmdOrCtrl+0', click: withActive((wc) => wc.setZoomLevel(0)) },
        { label: 'Zoom In', accelerator: 'CmdOrCtrl+=', click: withActive((wc) => wc.setZoomLevel(Math.min(wc.getZoomLevel() + 0.5, 5))) },
        { label: 'Zoom In', accelerator: 'CmdOrCtrl+Plus', visible: false, click: withActive((wc) => wc.setZoomLevel(Math.min(wc.getZoomLevel() + 0.5, 5))) },
        { label: 'Zoom Out', accelerator: 'CmdOrCtrl+-', click: withActive((wc) => wc.setZoomLevel(Math.max(wc.getZoomLevel() - 0.5, -5))) },
        { type: 'separator' },
        { label: 'Find in Page…', accelerator: 'CmdOrCtrl+F', click: () => { const s = focusedState(); if (s) { s.win.webContents.focus(); s.win.webContents.send('find'); } } },
        { type: 'separator' },
        { role: 'togglefullscreen' },
        { label: 'Developer Tools', accelerator: 'Alt+CmdOrCtrl+I', click: withActive((wc) => wc.toggleDevTools()) },
      ],
    },
    {
      label: 'History',
      submenu: [
        { label: 'Back', accelerator: 'CmdOrCtrl+[', click: withActive((wc) => wc.canGoBack() && wc.goBack()) },
        { label: 'Forward', accelerator: 'CmdOrCtrl+]', click: withActive((wc) => wc.canGoForward() && wc.goForward()) },
        { label: 'Back', accelerator: 'CmdOrCtrl+Left', visible: false, click: withActive((wc) => wc.canGoBack() && wc.goBack()) },
        { label: 'Forward', accelerator: 'CmdOrCtrl+Right', visible: false, click: withActive((wc) => wc.canGoForward() && wc.goForward()) },
        { label: 'Home', accelerator: 'CmdOrCtrl+Shift+H', click: withActive((wc) => wc.loadURL(HOME_URL).catch(() => {})) },
      ],
    },
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        { type: 'separator' },
        { label: 'Next Tab', accelerator: 'CmdOrCtrl+Alt+Right', click: cycle(1) },
        { label: 'Previous Tab', accelerator: 'CmdOrCtrl+Alt+Left', click: cycle(-1) },
        { label: 'Next Tab', accelerator: 'Ctrl+Tab', visible: false, click: cycle(1) },
        { label: 'Previous Tab', accelerator: 'Ctrl+Shift+Tab', visible: false, click: cycle(-1) },
        ...tabShortcuts,
        { type: 'separator' },
        { role: 'front' },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------------------------------------------------------------------------
// Session: permissions, downloads
// ---------------------------------------------------------------------------
function setupSession() {
  const ses = session.fromPartition('persist:feather');
  ses.setSpellCheckerEnabled(false);

  const alwaysAllow = new Set(['fullscreen', 'clipboard-sanitized-write', 'pointerLock']);
  const askUser = new Set(['media', 'geolocation', 'notifications', 'midi', 'midiSysex']);
  const decided = new Map(); // origin|permission -> bool (for this session)

  ses.setPermissionRequestHandler((wc, permission, callback, details) => {
    if (alwaysAllow.has(permission)) return callback(true);
    if (!askUser.has(permission)) return callback(false);
    let origin = '';
    try { origin = new URL(details.requestingUrl).origin; } catch { /* ignore */ }
    const key = `${origin}|${permission}`;
    if (decided.has(key)) return callback(decided.get(key));
    const win = BrowserWindow.fromWebContents(wc) ||
      [...windows.values()].find((s) => s.tabs.some((t) => t.view && t.view.webContents === wc))?.win;
    const what = permission === 'media'
      ? `use your ${(details.mediaTypes || []).join(' and ') || 'camera/microphone'}`
      : { geolocation: 'know your location', notifications: 'show notifications' }[permission] || `use ${permission}`;
    dialog.showMessageBox(win, {
      type: 'question',
      buttons: ['Allow', 'Block'],
      defaultId: 1,
      cancelId: 1,
      message: `${origin || 'This site'} wants to ${what}.`,
    }).then(({ response }) => {
      const ok = response === 0;
      decided.set(key, ok);
      callback(ok);
    }).catch(() => callback(false));
  });

  // Save downloads straight to ~/Downloads and reveal them when finished.
  ses.on('will-download', (_e, item) => {
    const dir = app.getPath('downloads');
    let target = path.join(dir, item.getFilename());
    const fs = require('fs');
    const ext = path.extname(target);
    const base = target.slice(0, target.length - ext.length);
    for (let i = 1; fs.existsSync(target); i++) target = `${base} (${i})${ext}`;
    item.setSavePath(target);
    item.once('done', (_ev, state) => {
      if (state === 'completed') {
        app.dock && app.dock.downloadFinished && app.dock.downloadFinished(target);
        shell.showItemInFolder(target);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------
let pendingUrl = null;
app.on('open-url', (event, url) => {
  event.preventDefault();
  if (!app.isReady()) { pendingUrl = url; return; }
  const s = focusedState();
  if (s) { s.newTab(url); s.win.show(); } else createWindow(url);
});

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    const url = argv.find((a) => /^https?:\/\//i.test(a));
    const s = focusedState();
    if (s) { if (url) s.newTab(url); s.win.show(); s.win.focus(); } else createWindow(url);
  });

  app.whenReady().then(() => {
    setupSession();
    buildMenu();
    const argUrl = process.argv.slice(1).find((a) => /^https?:\/\//i.test(a));
    createWindow(pendingUrl || argUrl);
    if (SLEEP_AFTER_MS > 0) {
      setInterval(() => { for (const s of windows.values()) s.sleepIdleTabs(); }, SLEEP_CHECK_MS);
    }
  });

  app.on('activate', () => { if (windows.size === 0) createWindow(); });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}

// Keep the toolbar UI from navigating away or opening windows.
app.on('web-contents-created', (_e, wc) => {
  if (wc.getType() === 'window') {
    wc.on('will-navigate', (e) => e.preventDefault());
    wc.setWindowOpenHandler(() => ({ action: 'deny' }));
  }
});
