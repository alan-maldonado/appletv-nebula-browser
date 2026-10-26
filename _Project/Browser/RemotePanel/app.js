'use strict';
// Nebula Remote panel. All page/tab/favorite text goes through textContent, never innerHTML.

// Admin actions turned on so far; their buttons stay disabled until listed here.
var ENABLED_ACTIONS = [];

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
  'tab-not-found': 'Esa tab ya no existe en la TV',
  'max-tabs': 'La TV ya tiene el máximo de tabs',
  'favorite-changed': 'Cambió en la TV, actualizado',
  'invalid-url': 'URL inválida (usa http:// o https://)',
  'invalid-index': 'Posición inválida',
  'invalid-launch': 'Opción inválida',
  'no-current-page': 'La TV no tiene una página abierta',
  'invalid-request': 'Solicitud inválida'
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
    toast(toastId, 'Sin conexión con la TV', true);
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
      toast('openToast', newTab ? 'Abierto en tab nueva' : 'Abierto en la TV');
    } else {
      toast('openToast', 'No se pudo abrir (' + result.status + ')', true);
    }
  }).catch(function () { toast('openToast', 'Sin conexión con la TV', true); });
}

function sendField() {
  if (!field) { return; }
  post('/api/field', { id: field.id, text: $('fieldInput').value, submit: $('fieldSubmit').checked }).then(function (result) {
    if (result.ok) { toast('fieldToast', 'Enviado'); }
    else if (result.status === 409) { toast('fieldToast', 'El campo ya no está activo en la TV', true); }
    else { toast('fieldToast', 'Error (' + result.status + ')', true); }
  }).catch(function () { toast('fieldToast', 'Sin conexión con la TV', true); });
}

function renderField(next) {
  if (next && (!field || field.id !== next.id)) {
    $('fieldTitle').textContent = next.title || next.placeholder || 'Texto';
    $('fieldInput').type = INPUT_TYPES.indexOf(next.type) >= 0 ? next.type : 'text';
    $('fieldInput').placeholder = next.placeholder || '';
    $('fieldInput').value = next.value || '';
    $('fieldSubmit').checked = false;
    $('fieldCard').hidden = false;
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
  if (!tabs.length) { list.appendChild(el('li', 'empty', 'No hay tabs')); return; }
  tabs.forEach(function (tab) {
    var item = el('li', tab.active ? 'active' : '');
    var main = el('div', 'main');
    main.appendChild(el('span', 'title', tab.title || domainOf(tab.url) || 'Nueva tab'));
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
  renderFavorites();
}

function openFavoriteMenu(item, index, favorite) {
  favoritesBusy = true;
  var actions = el('div', 'actions');
  var count = (state.favorites || []).length;
  actions.appendChild(button('Editar', 'secondary small', function () { openFavoriteEditor(item, index, favorite); }, 'favorites/update'));
  actions.appendChild(button('Abrir en tab nueva', 'secondary small', function () {
    act('favorites/open', favoritePayload(index, favorite, { newTab: true }), 'favToast', 'Abierto en tab nueva').then(closeFavoriteEditors);
  }, 'favorites/open'));
  var up = button('Subir', 'secondary small', function () {
    act('favorites/move', favoritePayload(index, favorite, { to: index - 1 }), 'favToast').then(closeFavoriteEditors);
  }, 'favorites/move');
  up.disabled = up.disabled || index === 0;
  actions.appendChild(up);
  var down = button('Bajar', 'secondary small', function () {
    act('favorites/move', favoritePayload(index, favorite, { to: index + 1 }), 'favToast').then(closeFavoriteEditors);
  }, 'favorites/move');
  down.disabled = down.disabled || index === count - 1;
  actions.appendChild(down);
  actions.appendChild(button('Borrar', 'secondary small', function () {
    actions.textContent = '';
    actions.appendChild(el('span', 'domain', '¿Borrar?'));
    actions.appendChild(button('Sí', 'primary small', function () {
      act('favorites/remove', favoritePayload(index, favorite), 'favToast', 'Borrado').then(closeFavoriteEditors);
    }, 'favorites/remove'));
    actions.appendChild(button('No', 'secondary small', closeFavoriteEditors));
  }, 'favorites/remove'));
  actions.appendChild(button('Cerrar', 'secondary small', closeFavoriteEditors));
  item.classList.add('editing');
  item.appendChild(actions);
}

function openFavoriteEditor(item, index, favorite) {
  favoritesBusy = true;
  item.textContent = '';
  var editor = el('div', 'editor');
  var title = el('input'); title.type = 'text'; title.value = favorite.title; title.placeholder = 'Nombre';
  var url = el('input'); url.type = 'url'; url.value = favorite.url; url.placeholder = 'https://…';
  editor.appendChild(title);
  editor.appendChild(url);
  var row = el('div', 'row');
  row.appendChild(button('Guardar', 'primary small', function () {
    act('favorites/update', favoritePayload(index, favorite, { title: title.value, newURL: url.value }), 'favToast', 'Guardado')
      .then(function (ok) { if (ok) { closeFavoriteEditors(); } });
  }, 'favorites/update'));
  row.appendChild(button('Cerrar', 'secondary small', closeFavoriteEditors));
  editor.appendChild(row);
  item.appendChild(editor);
  title.focus();
}

var dragIndex = null;

function renderFavorites() {
  if (favoritesBusy) { return; }
  var list = $('favList');
  var favorites = state.favorites || [];
  list.textContent = '';
  if (!favorites.length) { list.appendChild(el('li', 'empty', 'Sin favoritos todavía')); return; }
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
        act('favorites/move', favoritePayload(from, favorites[from], { to: index }), 'favToast');
      };
    }
    var main = el('div', 'main');
    main.appendChild(el('span', 'title', favorite.title));
    main.appendChild(el('span', 'domain', domainOf(favorite.url)));
    main.onclick = function () { act('favorites/open', favoritePayload(index, favorite, { newTab: false }), 'favToast', 'Abierto en la TV'); };
    item.appendChild(main);
    item.appendChild(button('Abrir', 'primary small', function () {
      act('favorites/open', favoritePayload(index, favorite, { newTab: false }), 'favToast', 'Abierto en la TV');
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
  status(page.title ? ('En la TV: ' + page.title) : 'Conectado a la TV', false);
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
      status('Sin conexión con la TV', true);
      version = 0;
      setTimeout(poll, Math.min(5000, 1000 * failures));
    });
}

function showSection(name) {
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

$('tabNew').onclick = function () { act('tabs/new', {}, 'tabsToast', 'Tab nueva abierta'); };
$('favAddCurrent').onclick = function () { act('favorites/add', { current: true }, 'favToast', 'Agregado'); };
$('favAddForm').onsubmit = function (event) {
  event.preventDefault();
  act('favorites/add', { url: $('favAddURL').value, title: $('favAddTitle').value }, 'favToast', 'Agregado').then(function (ok) {
    if (ok) { $('favAddURL').value = ''; $('favAddTitle').value = ''; }
  });
};
$('homeUseCurrent').onclick = function () { act('home', { useCurrent: true }, 'homeToast', 'Página de inicio actualizada'); };
$('homeSave').onclick = function () { act('home', { url: $('homeURL').value }, 'homeToast', 'Guardado'); };
document.querySelectorAll('input[name=launch]').forEach(function (radio) {
  radio.onchange = function () { act('home', { launch: radio.value }, 'homeToast', 'Guardado'); };
});

applyEnabledActions();

// Bookmarklet/share window: send once and close; no long-poll (see v1 review).
var params = new URLSearchParams(location.search);
if (params.get('open')) {
  history.replaceState(null, '', '/');
  status('Enviando a la TV…', false);
  post('/api/open', { text: params.get('open'), newTab: params.get('tab') === 'new' }).then(function (result) {
    status(result.ok ? 'Enviado a la TV' : 'No se pudo enviar (' + result.status + ')', !result.ok);
    if (result.ok) { setTimeout(function () { window.close(); }, 1200); }
  }).catch(function () { status('Sin conexión con la TV', true); });
} else {
  poll();
}
