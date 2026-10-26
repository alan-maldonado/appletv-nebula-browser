'use strict';
// Nebula Remote panel. All page/tab/favorite text goes through textContent, never innerHTML.

// Admin actions turned on so far; their buttons stay disabled until listed here.
var ENABLED_ACTIONS = ['tabs/switch', 'tabs/close', 'tabs/new',
  'favorites/add', 'favorites/update', 'favorites/remove', 'favorites/move', 'favorites/open', 'home'];

var $ = function (id) { return document.getElementById(id); };
var state = null;
var version = 0;
var failures = 0;
var field = null;
var favoritesBusy = false; // an inline editor/confirmation is open: don't re-render under it

var INPUT_TYPES = ['password', 'email', 'number', 'url', 'search', 'tel'];

function el(tag, className, text) {
  var node = document.createElement(tag);
  if (className) { node.className = className; }
  if (text !== undefined) { node.textContent = text; }
  return node;
}

function button(label, className, onClick, action) {
  var node = el('button', className, label);
  node.type = 'button';
  node.onclick = onClick;
  if (action && ENABLED_ACTIONS.indexOf(action) < 0) { node.disabled = true; }
  return node;
}

function domainOf(url) {
  try { return new URL(url).host || url; } catch (e) { return url; }
}

function toast(id, text, warn) {
  var node = $(id);
  node.textContent = text;
  node.className = warn ? 'toast warn' : 'toast';
  setTimeout(function () { if (node.textContent === text) { node.textContent = ''; } }, 2500);
}

function status(text, off) {
  $('status').className = off ? 'status off' : 'status';
  $('statusText').textContent = text;
}

function post(path, body) {
  return fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    .then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (json) {
        return { ok: response.ok, status: response.status, body: json };
      });
    });
}

var ERROR_TEXT = {
  'tab-not-found': 'That tab no longer exists on the TV',
  'max-tabs': 'The TV already has the maximum number of tabs',
  'favorite-changed': 'Changed on the TV, refreshed',
  'invalid-url': 'Invalid URL (use http:// or https://)',
  'invalid-index': 'Invalid position',
  'invalid-launch': 'Invalid option',
  'no-current-page': 'The TV has no page open',
  'invalid-request': 'Invalid request',
  'tv-busy': 'The TV is closing a tab, try again'
};

// POST /api/<action>; reports errors in the section's toast.
function act(action, payload, toastId, okText) {
  if (ENABLED_ACTIONS.indexOf(action) < 0) { return Promise.resolve(false); }
  return post('/api/' + action, payload).then(function (result) {
    if (result.ok) {
      if (okText) { toast(toastId, okText); }
      return true;
    }
    var code = result.body && result.body.error;
    toast(toastId, ERROR_TEXT[code] || ('Error (' + result.status + ')'), true);
    if (code === 'favorite-changed') { favoritesBusy = false; renderFavorites(); }
    return false;
  }).catch(function () {
    toast(toastId, 'Not connected to the TV', true);
    return false;
  });
}

// ---- Escribir ----------------------------------------------------------------

function sendOpen(newTab) {
  var text = $('openText').value.trim();
  if (!text) { return; }
  post('/api/open', { text: text, newTab: newTab }).then(function (result) {
    if (result.ok) {
      $('openText').value = '';
      toast('openToast', newTab ? 'Opened in a new tab' : 'Opened on the TV');
    } else {
      var code = result.body && result.body.error;
      toast('openToast', ERROR_TEXT[code] || ('Could not open (' + result.status + ')'), true);
    }
  }).catch(function () { toast('openToast', 'Not connected to the TV', true); });
}

function sendField() {
  if (!field) { return; }
  padRelockAfterField(); // must run inside the click/Enter gesture, before any await
  post('/api/field', { id: field.id, text: $('fieldInput').value, submit: $('fieldSubmit').checked }).then(function (result) {
    if (result.ok) { toast('fieldToast', 'Sent'); }
    else if (result.status === 409) { toast('fieldToast', 'That field is no longer active on the TV', true); }
    else { toast('fieldToast', 'Error (' + result.status + ')', true); }
  }).catch(function () { toast('fieldToast', 'Not connected to the TV', true); });
}

function renderField(next) {
  if (next && (!field || field.id !== next.id)) {
    $('fieldTitle').textContent = next.title || next.placeholder || 'Text';
    $('fieldInput').type = INPUT_TYPES.indexOf(next.type) >= 0 ? next.type : 'text';
    $('fieldInput').placeholder = next.placeholder || '';
    $('fieldInput').value = next.value || '';
    $('fieldSubmit').checked = false;
    // The address bar has no form to submit.
    $('fieldSubmit').parentNode.hidden = next.kind === 'address';
    $('fieldCard').hidden = false;
    padRelease();
    $('fieldInput').focus();
  }
  if (!next) { $('fieldCard').hidden = true; }
  field = next || null;
}

// ---- Tabs --------------------------------------------------------------------

function renderTabs() {
  var list = $('tabList');
  var tabs = state.tabs || [];
  list.textContent = '';
  $('tabCount').textContent = tabs.length ? String(tabs.length) : '';
  if (!tabs.length) { list.appendChild(el('li', 'empty', 'No tabs')); return; }
  tabs.forEach(function (tab) {
    var item = el('li', tab.active ? 'active' : '');
    var main = el('div', 'main');
    main.appendChild(el('span', 'title', tab.title || domainOf(tab.url) || 'New tab'));
    main.appendChild(el('span', 'domain', domainOf(tab.url)));
    main.onclick = function () { if (!tab.active) { act('tabs/switch', { id: tab.id }, 'tabsToast'); } };
    item.appendChild(main);
    item.appendChild(button('✕', 'icon', function () { act('tabs/close', { id: tab.id }, 'tabsToast'); }, 'tabs/close'));
    list.appendChild(item);
  });
}

// ---- Favoritos ---------------------------------------------------------------

function favoritePayload(index, favorite, extra) {
  var payload = { index: index, url: favorite.url };
  Object.keys(extra || {}).forEach(function (key) { payload[key] = extra[key]; });
  return payload;
}

function closeFavoriteEditors() {
  favoritesBusy = false;
  renderedFavorites = null;
  if (state) { renderFavorites(); }
}

function openFavoriteMenu(item, index, favorite) {
  favoritesBusy = true;
  var actions = el('div', 'actions');
  var count = (state.favorites || []).length;
  actions.appendChild(button('Edit', 'secondary small', function () { openFavoriteEditor(item, index, favorite); }, 'favorites/update'));
  actions.appendChild(button('Open in new tab', 'secondary small', function () {
    act('favorites/open', favoritePayload(index, favorite, { newTab: true }), 'favToast', 'Opened in a new tab').then(closeFavoriteEditors);
  }, 'favorites/open'));
  var up = button('Move up', 'secondary small', function () {
    act('favorites/move', favoritePayload(index, favorite, { to: index - 1 }), 'favToast').then(closeFavoriteEditors);
  }, 'favorites/move');
  up.disabled = up.disabled || index === 0;
  actions.appendChild(up);
  var down = button('Move down', 'secondary small', function () {
    act('favorites/move', favoritePayload(index, favorite, { to: index + 1 }), 'favToast').then(closeFavoriteEditors);
  }, 'favorites/move');
  down.disabled = down.disabled || index === count - 1;
  actions.appendChild(down);
  actions.appendChild(button('Delete', 'secondary small', function () {
    actions.textContent = '';
    actions.appendChild(el('span', 'domain', 'Delete?'));
    actions.appendChild(button('Yes', 'primary small', function () {
      act('favorites/remove', favoritePayload(index, favorite), 'favToast', 'Deleted').then(closeFavoriteEditors);
    }, 'favorites/remove'));
    actions.appendChild(button('No', 'secondary small', closeFavoriteEditors));
  }, 'favorites/remove'));
  actions.appendChild(button('Close', 'secondary small', closeFavoriteEditors));
  item.classList.add('editing');
  item.appendChild(actions);
}

function openFavoriteEditor(item, index, favorite) {
  favoritesBusy = true;
  item.textContent = '';
  var editor = el('div', 'editor');
  var title = el('input'); title.type = 'text'; title.value = favorite.title; title.placeholder = 'Name';
  var url = el('input'); url.type = 'url'; url.value = favorite.url; url.placeholder = 'https://…';
  editor.appendChild(title);
  editor.appendChild(url);
  var row = el('div', 'row');
  row.appendChild(button('Save', 'primary small', function () {
    act('favorites/update', favoritePayload(index, favorite, { title: title.value, newURL: url.value }), 'favToast', 'Saved')
      .then(function (ok) { if (ok) { closeFavoriteEditors(); } });
  }, 'favorites/update'));
  row.appendChild(button('Close', 'secondary small', closeFavoriteEditors));
  editor.appendChild(row);
  item.appendChild(editor);
  title.focus();
}

var dragIndex = null;

var renderedFavorites = null; // JSON of the list last drawn

function renderFavorites() {
  var favorites = state.favorites || [];
  var json = JSON.stringify(favorites);
  if (favoritesBusy) {
    if (json === renderedFavorites) { return; } // keep the open menu/editor
    // The list really changed (e.g. on the TV): the open editor points at stale data.
    favoritesBusy = false;
    toast('favToast', ERROR_TEXT['favorite-changed'], true);
  }
  renderedFavorites = json;
  var list = $('favList');
  list.textContent = '';
  if (!favorites.length) { list.appendChild(el('li', 'empty', 'No favorites yet')); return; }
  var canMove = ENABLED_ACTIONS.indexOf('favorites/move') >= 0;
  favorites.forEach(function (favorite, index) {
    var item = el('li');
    if (canMove) {
      item.draggable = true;
      item.appendChild(el('span', 'handle', '≡'));
      item.ondragstart = function (event) { dragIndex = index; item.classList.add('dragging'); event.dataTransfer.effectAllowed = 'move'; };
      item.ondragend = function () { dragIndex = null; item.classList.remove('dragging'); };
      item.ondragover = function (event) { if (dragIndex !== null && dragIndex !== index) { event.preventDefault(); item.classList.add('drop-target'); } };
      item.ondragleave = function () { item.classList.remove('drop-target'); };
      item.ondrop = function (event) {
        event.preventDefault();
        item.classList.remove('drop-target');
        if (dragIndex === null || dragIndex === index) { return; }
        var from = dragIndex;
        act('favorites/move', favoritePayload(from, favorites[from], { to: index }), 'favToast').then(closeFavoriteEditors);
      };
    }
    var main = el('div', 'main');
    main.appendChild(el('span', 'title', favorite.title));
    main.appendChild(el('span', 'domain', domainOf(favorite.url)));
    main.onclick = function () { act('favorites/open', favoritePayload(index, favorite, { newTab: false }), 'favToast', 'Opened on the TV'); };
    item.appendChild(main);
    item.appendChild(button('Open', 'primary small', function () {
      act('favorites/open', favoritePayload(index, favorite, { newTab: false }), 'favToast', 'Opened on the TV');
    }, 'favorites/open'));
    item.appendChild(button('⋯', 'icon', function () {
      if (item.classList.contains('editing')) { closeFavoriteEditors(); } else { openFavoriteMenu(item, index, favorite); }
    }));
    list.appendChild(item);
  });
}

// ---- Inicio ------------------------------------------------------------------

function renderHome() {
  var home = state.home || {};
  if (document.activeElement !== $('homeURL')) { $('homeURL').value = home.url || ''; }
  document.querySelectorAll('input[name=launch]').forEach(function (radio) { radio.checked = radio.value === home.launch; });
}

// ---- Trackpad ----------------------------------------------------------------
// Movement is accumulated and sent once per animation frame over /api/trackpad.

var DESKTOP = window.matchMedia('(min-width: 900px)');
var TOUCH = window.matchMedia('(pointer: coarse)').matches;
var SPEED_KEY = 'nebula.trackpadSpeed';
var pad = { socket: null, wanted: false, failures: 0, retry: null,
            move: { x: 0, y: 0 }, scroll: { x: 0, y: 0 }, frame: false, clickTimer: null, lastTap: 0 };

function padSpeed() { return parseFloat($('padSpeed').value) || (TOUCH ? 3 : 2); }

function loadPadSpeed() {
  var saved = null;
  try { saved = localStorage.getItem(SPEED_KEY); } catch (e) {}
  $('padSpeed').value = saved || (TOUCH ? '3' : '2');
}

function padStatus(connected) {
  $('padStatus').textContent = connected ? 'Connected' : 'Disconnected';
  $('padStatus').className = connected ? 'pad-status on' : 'pad-status';
}

function padOpen() {
  pad.wanted = true;
  if (pad.socket) { return; }
  if (document.hidden) { return; } // reopened on visibilitychange
  var socket = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/trackpad');
  pad.socket = socket;
  socket.onopen = function () {
    if (pad.socket !== socket) { return; }
    pad.failures = 0;
    padStatus(true);
  };
  socket.onclose = function () {
    if (pad.socket !== socket) { return; } // a superseded socket closing late
    pad.socket = null;
    padStatus(false);
    if (!pad.wanted) { return; }
    pad.failures++;
    pad.retry = setTimeout(padOpen, Math.min(5000, 1000 * pad.failures));
  };
}

function padClose() {
  pad.wanted = false;
  padRelease();
  clearTimeout(pad.retry);
  if (pad.socket) { pad.socket.close(1000); pad.socket = null; }
  padStatus(false);
}

// Hidden tabs and sleeping phones must not hold one of the server's 8 connection slots:
// drop the socket while hidden (the server also closes it after 60 s without frames).
function padSuspend() {
  clearTimeout(pad.retry);
  if (pad.socket) { var socket = pad.socket; pad.socket = null; socket.close(1000); }
  padStatus(false);
}

function padSend(message) {
  if (pad.socket && pad.socket.readyState === WebSocket.OPEN) { pad.socket.send(JSON.stringify(message)); }
}

function padFlush() {
  pad.frame = false;
  if (pad.move.x || pad.move.y) { padSend({ t: 'm', dx: Math.round(pad.move.x), dy: Math.round(pad.move.y) }); }
  if (pad.scroll.x || pad.scroll.y) { padSend({ t: 's', dx: Math.round(pad.scroll.x), dy: Math.round(pad.scroll.y) }); }
  pad.move = { x: 0, y: 0 };
  pad.scroll = { x: 0, y: 0 };
}

function padQueue(kind, dx, dy) {
  var target = kind === 'm' ? pad.move : pad.scroll;
  target.x += dx;
  target.y += dy;
  if (!pad.frame) { pad.frame = true; requestAnimationFrame(padFlush); }
}

function padClick() { padFlush(); padSend({ t: 'c' }); }
function padDoubleClick() { padFlush(); padSend({ t: 'd' }); }

// A single click waits (250 ms mouse, 300 ms touch = the double-tap window) so a
// double click doesn't also send a single click.
function padDeferredClick(delay) {
  if (pad.clickTimer) { return; }
  pad.clickTimer = setTimeout(function () { pad.clickTimer = null; padClick(); }, delay);
}
function padCancelClick() { clearTimeout(pad.clickTimer); pad.clickTimer = null; }

function padLocked() { return document.pointerLockElement === $('pad'); }

// When the TV asks for text, give the mouse back so the "Nebula pide" field can be
// typed into; sending it (a user gesture, which pointer lock requires) recaptures it.
function padRelease() {
  if (padLocked()) { pad.relockAfterField = true; document.exitPointerLock(); }
}
function padRelockAfterField() {
  if (pad.relockAfterField && !TOUCH) { pad.relockAfterField = false; $('pad').requestPointerLock(); }
}

function setupPad() {
  var area = $('pad');
  loadPadSpeed();
  var hoverHint = 'Move the mouse here to move the TV cursor · click = click · two fingers = scroll';
  $('padHint').textContent = TOUCH ? 'Drag to move the cursor · tap to click · two fingers to scroll' : hoverHint;
  if (TOUCH) { $('padCapture').hidden = true; } else { area.classList.add('hover-mode'); }
  $('padCapture').onclick = function () { area.requestPointerLock(); };
  $('padSpeed').oninput = function () { try { localStorage.setItem(SPEED_KEY, $('padSpeed').value); } catch (e) {} };
  $('padClick').onclick = padClick;
  $('padDouble').onclick = padDoubleClick;

  // Mac / desktop. Hover mode (default): moving over the pad drives the cursor, no click
  // needed. "Capturar mouse" switches to pointer lock (no edges, Esc releases).
  area.addEventListener('mousemove', function (event) {
    // While locked, events are handled once by the document listener below.
    if (!TOUCH && !padLocked()) { padQueue('m', event.movementX * padSpeed(), event.movementY * padSpeed()); }
  });
  document.addEventListener('mousemove', function (event) {
    if (padLocked()) { padQueue('m', event.movementX * padSpeed(), event.movementY * padSpeed()); }
  });
  area.addEventListener('click', function () {
    if (!TOUCH) { padDeferredClick(250); }
  });
  area.addEventListener('dblclick', function () {
    if (TOUCH) { return; }
    padCancelClick();
    padDoubleClick();
  });
  area.addEventListener('wheel', function (event) {
    if (TOUCH) { return; }
    event.preventDefault();
    padQueue('s', event.deltaX, event.deltaY);
  }, { passive: false });
  document.addEventListener('pointerlockchange', function () {
    var locked = padLocked();
    area.classList.toggle('locked', locked);
    $('padCapture').textContent = locked ? 'Esc to release' : 'Capture mouse';
    if (!TOUCH) { $('padHint').textContent = locked ? 'Mouse captured · Esc to release' : hoverHint; }
  });

  // iPhone / touch: 1 finger moves, tap clicks, double tap double-clicks, 2 fingers scroll.
  var touch = null;
  function center(list) {
    var x = 0, y = 0;
    for (var i = 0; i < list.length; i++) { x += list[i].clientX; y += list[i].clientY; }
    return { x: x / list.length, y: y / list.length };
  }
  area.addEventListener('touchstart', function (event) {
    event.preventDefault();
    var point = center(event.touches);
    touch = { start: Date.now(), origin: point, last: point, fingers: event.touches.length, moved: false };
  }, { passive: false });
  area.addEventListener('touchmove', function (event) {
    event.preventDefault();
    if (!touch) { return; }
    var point = center(event.touches);
    var dx = point.x - touch.last.x;
    var dy = point.y - touch.last.y;
    touch.last = point;
    touch.fingers = Math.max(touch.fingers, event.touches.length);
    if (Math.abs(point.x - touch.origin.x) > 10 || Math.abs(point.y - touch.origin.y) > 10) { touch.moved = true; }
    if (event.touches.length >= 2) { padQueue('s', -dx * 2, -dy * 2); }
    else { padQueue('m', dx * padSpeed(), dy * padSpeed()); }
  }, { passive: false });
  area.addEventListener('touchend', function (event) {
    event.preventDefault();
    if (!touch || event.touches.length > 0) { return; }
    var tap = !touch.moved && touch.fingers === 1 && Date.now() - touch.start < 200;
    touch = null;
    if (!tap) { return; }
    var now = Date.now();
    if (now - pad.lastTap < 300) { pad.lastTap = 0; padCancelClick(); padDoubleClick(); }
    else { pad.lastTap = now; padDeferredClick(300); }
  }, { passive: false });

  window.addEventListener('pagehide', padClose);
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) { padSuspend(); } else if (pad.wanted) { padOpen(); }
  });
  setInterval(function () { padSend({ t: 'k' }); }, 20000); // keepalive for the idle timeout
  if (DESKTOP.matches) { padOpen(); }
}

// ---- Estado ------------------------------------------------------------------

function applyEnabledActions() {
  document.querySelectorAll('[data-action]').forEach(function (node) {
    node.disabled = ENABLED_ACTIONS.indexOf(node.getAttribute('data-action')) < 0;
  });
}

function render(next) {
  state = next;
  var theme = state.theme || {};
  if (theme.accent) { document.documentElement.style.setProperty('--accent', theme.accent); }
  if (theme.onAccent) { document.documentElement.style.setProperty('--on-accent', theme.onAccent); }
  var page = state.page || {};
  status(page.title ? ('On the TV: ' + page.title) : 'Connected to the TV', false);
  renderField(state.field);
  renderTabs();
  renderFavorites();
  renderHome();
}

function poll() {
  fetch('/api/state?v=' + version, { cache: 'no-store' })
    .then(function (response) { return response.json(); })
    .then(function (next) { failures = 0; version = next.v; render(next); poll(); })
    .catch(function () {
      failures++;
      status('Not connected to the TV', true);
      version = 0;
      setTimeout(poll, Math.min(5000, 1000 * failures));
    });
}

function showSection(name) {
  // Leaving the section closes any open favorite menu/editor so the list never stays frozen.
  if (favoritesBusy) { closeFavoriteEditors(); }
  // On narrow screens the trackpad socket lives only while its section is shown.
  if (!DESKTOP.matches) {
    if (name === 'trackpad') { padOpen(); } else { padClose(); }
  }
  document.querySelectorAll('#sectionBar button').forEach(function (node) {
    node.classList.toggle('active', node.getAttribute('data-section') === name);
  });
  document.querySelectorAll('.panel').forEach(function (panel) { panel.classList.toggle('active', panel.id === name); });
}

// ---- Wiring ------------------------------------------------------------------

document.querySelectorAll('#sectionBar button').forEach(function (node) {
  node.onclick = function () { showSection(node.getAttribute('data-section')); };
});
$('openHere').onclick = function () { sendOpen(false); };
$('openTab').onclick = function () { sendOpen(true); };
$('openText').onkeydown = function (event) { if (event.key === 'Enter') { sendOpen(false); } };
$('fieldSend').onclick = sendField;
$('fieldInput').onkeydown = function (event) { if (event.key === 'Enter') { sendField(); } };

$('tabNew').onclick = function () { act('tabs/new', {}, 'tabsToast', 'New tab opened'); };
$('favAddCurrent').onclick = function () { act('favorites/add', { current: true }, 'favToast', 'Added'); };
$('favAddForm').onsubmit = function (event) {
  event.preventDefault();
  act('favorites/add', { url: $('favAddURL').value, title: $('favAddTitle').value }, 'favToast', 'Added').then(function (ok) {
    if (ok) { $('favAddURL').value = ''; $('favAddTitle').value = ''; }
  });
};
$('homeUseCurrent').onclick = function () { act('home', { useCurrent: true }, 'homeToast', 'Home page updated'); };
$('homeSave').onclick = function () { act('home', { url: $('homeURL').value }, 'homeToast', 'Saved'); };
document.querySelectorAll('input[name=launch]').forEach(function (radio) {
  radio.onchange = function () { act('home', { launch: radio.value }, 'homeToast', 'Saved'); };
});

applyEnabledActions();
setupPad();

// Bookmarklet/share window: send once and close; no long-poll (see v1 review).
var params = new URLSearchParams(location.search);
if (params.get('open')) {
  history.replaceState(null, '', '/');
  status('Sending to the TV…', false);
  post('/api/open', { text: params.get('open'), newTab: params.get('tab') === 'new' }).then(function (result) {
    status(result.ok ? 'Sent to the TV' : 'Could not send (' + result.status + ')', !result.ok);
    if (result.ok) { setTimeout(function () { window.close(); }, 1200); }
  }).catch(function () { status('Not connected to the TV', true); });
} else {
  poll();
}
