# Nebula Remote — Panel de administración web (sub-proyecto 1)

- **Fecha:** 2026-10-25
- **Estado:** diseño aprobado por secciones en chat; pendiente revisión de este spec
- **Base:** Nebula Remote v1 (`docs/superpowers/specs/2026-10-25-remote-input-design.md`), en `main` desde `a0a8b85`
- **Decisiones:** A1 (página como archivos del bundle) + B1 (un solo estado sincronizado) + `BrowserFavoritesStore` compartido

## 1. Objetivo

Convertir la página de Nebula Remote (`http://<appletv>.local:8080`) en un panel para administrar Nebula
desde el iPhone o la Mac:

- **Tabs:** ver la lista en vivo, cambiar a una tab específica, cerrarla, abrir una nueva.
- **Favoritos:** agregar (URL o la página actual de la TV), editar título/URL, borrar, reordenar, abrir
  (en la tab actual o en una nueva).
- **Inicio:** URL de la página de inicio (o "usar la página actual") y modo de arranque
  (última sesión / página de inicio).
- **Escribir:** lo existente (abrir URL/búsqueda, llenar el campo activo).

**Éxito:** sin tocar el Siri Remote, desde el iPhone o la Mac se ven las tabs y se salta a una o se
cierra, se editan y reordenan favoritos y se cambia la página de inicio; todo se refleja en la TV y en
todos los paneles abiertos en < 1 s.

### Lo que dijo Alan
- Enfocarse en administración web: favoritos, cerrar tabs, abrir una tab específica, administrar la
  página de inicio ("ambas": configurar la URL/arranque **y**, en el sub-proyecto 2, una cuadrícula de
  favoritos en la TV).
- Empezar por este sub-proyecto 1.

### Supuestos
- Uso en casa; mismas guardas que v1 (`Host` local, POST solo `application/json`), sin autenticación.
- Cambios hechos en la TV (abrir/cerrar tabs, agregar/borrar favoritos) también se reflejan en el panel.

## 2. Fuera de alcance

- **Sub-proyecto 2:** cuadrícula de favoritos como página de inicio en la TV (consumirá el orden de
  `BrowserFavoritesStore`).
- Historial, otros ajustes de Settings, miniaturas de tabs, autenticación.

## 3. Arquitectura

```
Panel web (iPhone/Mac)                          Nebula (Apple TV)
 index.html + app.css + app.js   GET estáticos   BrowserRemoteServer
 (bundle: RemotePanel/)  ◀────────────────────▶   ├ rutas estáticas (lista blanca)
 Escribir · Tabs · Favoritos ·  long-poll state   ├ /api/state  (estado completo + versión)
 Inicio                         POST acciones     └ /api/… acciones ──▶ delegate (main)
                         ViewController ◀─────────────────────┘
                          ├ BrowserTabCoordinator   (cambiar/cerrar/abrir tab por id)
                          ├ BrowserFavoritesStore   (nuevo; compartido con la TV)
                          └ BrowserPreferencesStore (URL de inicio, modo de arranque)
```

## 4. Componentes

### Nuevos
| Archivo | Responsabilidad |
|---|---|
| `BrowserFavoritesStore.h/.m` | Solo Foundation. Lee/escribe `NSUserDefaults["FAVORITES"]` en el formato actual (array de `[url, título]`), tolera entradas corruptas (las ignora al leer, las conserva al escribir solo si son válidas). API: `favorites`, `addURLString:title:`, `updateAtIndex:expectedURLString:title:URLString:`, `removeAtIndex:expectedURLString:`, `moveFromIndex:expectedURLString:toIndex:`. Las mutaciones con `expectedURLString` fallan si el favorito en `index` no tiene esa URL. Publica `BrowserFavoritesStoreDidChangeNotification`. Se inicializa con un `NSUserDefaults` inyectable (tests usan `initWithSuiteName:`). |
| `_Project/Browser/RemotePanel/` (folder reference) | `index.html`, `app.css`, `app.js`. Una sola entrada en el pbxproj; agregar archivos ahí no toca el proyecto. Reemplaza `BrowserRemotePage.h/.m` (se eliminan). |

### Cambios
| Archivo | Cambio |
|---|---|
| `BrowserMenuCoordinator.m` | Favoritos (listar, agregar, borrar) vía `BrowserFavoritesStore`; sin acceso directo a `NSUserDefaults["FAVORITES"]`. |
| `BrowserRemoteServer.h/.m` | Rutas estáticas con lista blanca `/`→`index.html`, `/app.css`, `/app.js` (desde `RemotePanel/` del bundle, con `Content-Type` correcto) y `/apple-touch-icon.png`. Acciones nuevas (§5). El delegate recibe acciones genéricas: `remoteServer:performAction:payload:` → código HTTP + JSON. |
| `BrowserRemoteState.h/.m` | Agrega `tabs`, `favorites`, `home`, `theme` con `update…` que solo suben la versión si cambió el valor. |
| `BrowserRemoteHTTP.h/.m` | Validadores puros de los payloads nuevos. |
| `ViewController.m` | Ejecuta las acciones; publica estado cuando cambian tabs (crear, cerrar, cambiar, cargar), favoritos (notificación), inicio y tema. |
| `BrowserTabCoordinator.h/.m` | `indexOfTabWithIdentifier:`. El host debe enterarse al crear, cerrar y cambiar de tab: `closeTabAtIndex:` ya llama `refreshActiveTabUI` (verificado); crear y cambiar se verifican en la implementación y, si no pasan por ahí, se agrega la llamada a `browserTabCoordinatorActiveTabDidRefresh`. |

## 5. API

### Estado — `GET /api/state?v=<n>` (long-poll existente, ampliado)
```json
{ "v": 12,
  "page": {"title": "…", "url": "…"},
  "field": null,
  "tabs": [{"id": "UUID", "title": "Apple", "url": "https://www.apple.com/", "active": true}],
  "favorites": [{"title": "YouTube", "url": "https://youtube.com/"}],
  "home": {"url": "https://www.google.com", "launch": "last-session"},
  "theme": {"accent": "#7B6CDE", "onAccent": "#FFFFFF"} }
```
`launch` ∈ `"last-session"` (launchPageMode 0) | `"home-page"` (1).

### Acciones (POST JSON; guardas de v1)
| Endpoint | Body | Efecto | Errores |
|---|---|---|---|
| `/api/tabs/switch` | `{id}` | Cambia a esa tab | `404 tab-not-found` |
| `/api/tabs/close` | `{id}` | Cierra la tab; si era la última, se abre una nueva con la página de inicio (comportamiento actual de `closeTabAtIndex:`) | `404 tab-not-found` |
| `/api/tabs/new` | `{}` | Nueva tab con la página de inicio | `409 max-tabs` (sin mostrar la alerta en la TV) |
| `/api/favorites/add` | `{url, title?}` o `{current: true}` | Agrega la URL (o la página actual de la TV); título vacío → la URL | `400 invalid-url` (vacía o no http/https), `400 no-current-page` |
| `/api/favorites/update` | `{index, url, title, newURL?}` | Renombra y/o cambia la URL | `409 favorite-changed`, `400 invalid-url` |
| `/api/favorites/remove` | `{index, url}` | Borra | `409 favorite-changed` |
| `/api/favorites/move` | `{index, url, to}` | Reordena | `409 favorite-changed`, `400 invalid-index` |
| `/api/favorites/open` | `{index, url, newTab}` | Abre en la TV | `409 favorite-changed`, `409 max-tabs` |
| `/api/home` | `{url?, useCurrent?, launch?}` | Página de inicio y/o modo de arranque | `400 invalid-url`, `400 invalid-launch`, `400 no-current-page` |

`/api/open` y `/api/field` sin cambios. Toda acción exitosa responde `{"ok":true}`; los cambios suben la
versión del estado. Cambiar/cerrar tab y abrir favorito descartan el campo activo (como `/api/open`).

## 6. Panel (UI)

- Una página; secciones **Escribir · Tabs · Favoritos · Inicio** con navegación sin recarga. iPhone: una
  columna, barra de secciones fija abajo. Mac (≥ 900 px): dos columnas (Tabs | Favoritos + Inicio) con
  Escribir arriba.
- La tarjeta "Nebula pide" (campo activo) aparece arriba en cualquier sección.
- **Tabs:** fila = título + dominio; tocar la fila cambia de tab; `✕` cierra; la activa con el acento;
  botón **+ Nueva**.
- **Favoritos:** fila con **Abrir** y menú `⋯` (Editar, Abrir en tab nueva, Subir, Bajar, Borrar). Edición
  en línea (título y URL). Borrar con confirmación en línea ("¿Borrar? Sí / No"), nunca `confirm()`.
  Reordenar: arrastrar en desktop (HTML5 drag & drop) y Subir/Bajar en todos lados. Botones
  **+ Página actual** y **+ Agregar URL**.
- **Inicio:** campo URL + **Usar página actual** + **Guardar**; radio "Al abrir Nebula: Última sesión /
  Página de inicio" (guarda al cambiar).
- Branding y logo de v1; el acento llega en `state.theme` y se aplica como variables CSS (cambia en vivo).
- Texto de títulos/URLs siempre con `textContent`. `409 favorite-changed` → aviso "Cambió en la TV,
  actualizado" y refresco; sin conexión → indicador naranja (como v1).

## 7. Errores y robustez

- Límites, hilos, ciclo de vida y guardas de v1 sin cambios. Nada del servidor usa el puente JS síncrono.
- Rutas estáticas: solo la lista blanca; cualquier otra ruta `404` (sin path traversal). Archivo faltante
  en el bundle → `404`.
- Validación de URL para favoritos/inicio: `http`/`https` con host; se recorta espacio. (El campo de inicio
  acepta lo mismo que hoy acepta Settings.)

## 8. Pruebas

1. **Unitarias (runner `_Project/Tests/run-remote-tests.sh`, TDD):** `BrowserFavoritesStore` (formato
   actual, entradas corruptas, add/update/remove/move, conflicto `index`+`url`, límites de índice,
   notificación) con `NSUserDefaults` de suite de prueba; validadores de payloads; campos nuevos de
   `BrowserRemoteState`.
2. **Integración con `curl` en el simulador (`localhost:8080`):** cada endpoint y sus errores; el
   long-poll sube de versión tras cada acción; rutas estáticas y `404`.
3. **Chrome en la Mac contra el simulador:** las 4 secciones con datos de prueba creados en el simulador.
4. **Pendiente para Alan en el Apple TV:** panel en iPhone; cambios hechos en la TV reflejados en el panel.

## 9. Orden de construcción

1. `BrowserFavoritesStore` (TDD) + migrar `BrowserMenuCoordinator`.
2. Panel como archivos del bundle con las 4 secciones en solo lectura + estado ampliado. **← primer
   punto visible en `localhost:8080`.**
3. Acciones de tabs. 4. Acciones de favoritos. 5. Acciones de inicio + tema en vivo.
6. Revisión final con revisor independiente.

## 10. Riesgos

| Riesgo | Mitigación |
|---|---|
| Folder reference no copiada al bundle o en otra ruta | Verificar `Browser.app/RemotePanel/index.html` tras el build (paso 2). |
| Ediciones simultáneas TV/panel sobre favoritos por índice | Conflicto `index`+`url` → `409` y refresco. |
| El estado crece con muchas tabs/favoritos | Tabs limitadas por `maximumTabCount`; favoritos típicamente decenas → pocos KB. |
