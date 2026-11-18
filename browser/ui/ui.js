'use strict';
/* global feather */
const $ = (id) => document.getElementById(id);
const tabsEl = $('tabs');
const address = $('address');
const back = $('back');
const forward = $('forward');
const reload = $('reload');
const secure = $('secure');
const findForm = $('find-form');
const findInput = $('find');
const findCount = $('find-count');

let state = { activeId: null, tabs: [] };
let editing = false;

function displayUrl(url) {
  if (!url || url.startsWith('data:')) return '';
  return url;
}

function renderTab(t) {
  const el = document.createElement('div');
  el.className = 'tab' + (t.id === state.activeId ? ' active' : '') + (t.asleep ? ' asleep' : '');
  el.setAttribute('role', 'tab');
  el.title = t.asleep ? `${t.title} (sleeping to save memory)` : t.title;
  el.dataset.id = t.id;

  if (t.loading) {
    const s = document.createElement('span'); s.className = 'spin'; el.append(s);
  } else if (t.favicon) {
    const img = document.createElement('img');
    img.className = 'fav'; img.src = t.favicon; img.alt = '';
    img.onerror = () => { img.removeAttribute('src'); img.className = 'fav placeholder'; };
    el.append(img);
  } else {
    const s = document.createElement('span'); s.className = 'fav placeholder'; el.append(s);
  }
  const title = document.createElement('span');
  title.className = 'title';
  title.textContent = t.title || displayUrl(t.url) || 'New Tab';
  el.append(title);
  if (t.audible) {
    const a = document.createElement('span'); a.className = 'audio'; a.textContent = '♪'; el.append(a);
  }
  const close = document.createElement('button');
  close.className = 'close'; close.textContent = '×'; close.title = 'Close Tab (⌘W)';
  close.addEventListener('click', (e) => { e.stopPropagation(); feather.send('close-tab', t.id); });
  el.append(close);

  el.addEventListener('mousedown', (e) => {
    if (e.button === 1) { e.preventDefault(); feather.send('close-tab', t.id); }
  });
  el.addEventListener('click', () => feather.send('activate', t.id));
  return el;
}

function render() {
  tabsEl.replaceChildren(...state.tabs.map(renderTab));
  const t = state.tabs.find((x) => x.id === state.activeId);
  back.disabled = !t || !t.canGoBack;
  forward.disabled = !t || !t.canGoForward;
  reload.classList.toggle('loading', !!(t && t.loading));
  reload.title = t && t.loading ? 'Stop' : 'Reload (⌘R)';
  if (!editing) address.value = t ? displayUrl(t.url) : '';
  secure.textContent = t && t.url.startsWith('https:') ? '🔒' : (t && t.url.startsWith('http:') ? '⚠︎' : '');
}

feather.on('tabs', (s) => { state = s; render(); });
feather.on('focus-address', () => { address.focus(); address.select(); });
feather.on('fullscreen', (on) => document.body.classList.toggle('fullscreen', on));

$('new-tab').addEventListener('click', () => feather.send('new-tab'));
back.addEventListener('click', () => feather.send('back'));
forward.addEventListener('click', () => feather.send('forward'));
reload.addEventListener('click', () => feather.send(reload.classList.contains('loading') ? 'stop' : 'reload'));
$('tabstrip').addEventListener('dblclick', (e) => { if (e.target === tabsEl) feather.send('new-tab'); });

address.addEventListener('focus', () => { editing = true; address.select(); });
address.addEventListener('blur', () => { editing = false; render(); });
address.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { editing = false; render(); address.blur(); feather.send('focus-page'); }
});
$('address-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const value = address.value.trim();
  if (!value) return;
  editing = false;
  address.blur();
  feather.send('navigate', value);
});

// Find in page
let findTimer = null;
function closeFind() {
  findForm.hidden = true; findCount.textContent = ''; findInput.value = '';
  feather.send('find-stop'); feather.send('focus-page');
}
feather.on('find', () => { findForm.hidden = false; findInput.focus(); findInput.select(); });
feather.on('find-result', (r) => { findCount.textContent = r.total ? `${r.current}/${r.total}` : '0/0'; });
findInput.addEventListener('input', () => {
  clearTimeout(findTimer);
  findTimer = setTimeout(() => {
    if (findInput.value) feather.send('find', { text: findInput.value });
    else { findCount.textContent = ''; feather.send('find-stop'); }
  }, 120);
});
findInput.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { e.preventDefault(); closeFind(); }
});
findForm.addEventListener('submit', (e) => {
  e.preventDefault();
  if (findInput.value) feather.send('find', { text: findInput.value, next: true });
});
findInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && e.shiftKey) { e.preventDefault(); if (findInput.value) feather.send('find', { text: findInput.value, next: true, forward: false }); }
});
$('find-close').addEventListener('click', closeFind);
