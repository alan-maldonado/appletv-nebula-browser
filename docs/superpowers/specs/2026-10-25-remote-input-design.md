# Nebula Remote — escribir en Nebula desde el iPhone o la Mac

- **Fecha:** 2026-10-25
- **Estado:** diseño aprobado por secciones en chat; pendiente revisión de este spec
- **Enfoque elegido:** A — servidor HTTP embebido en Nebula (sin servicio externo)

## 1. Objetivo

Escribir en el Apple TV con el teclado del Siri Remote es el mayor dolor de usar un browser en la TV.
Nebula Remote permite abrir una página web desde cualquier navegador de la red de la casa (iPhone,
iPad, MacBook) y desde ahí:

1. Abrir una URL o búsqueda en la tab actual.
2. Abrirla en una tab nueva.
3. Llenar el campo de texto que está activo en la página de la TV (opcionalmente enviar el formulario).
4. "Enviar a la TV" desde el menú Compartir (Atajo de iOS/macOS) o un bookmarklet en la Mac.

**Éxito:** abrir la página (sin instalar nada), escribir, enviar, y verlo en la TV en menos de 1 s.

### Lo que dijo Alan
- Uso **solo en casa**, no para el público del repo → seguridad mínima.
- Debe funcionar también **desde una MacBook**.
- v1 = los 4 casos de arriba; enfoque A.

### Supuestos
- Solo funciona con Nebula **abierta en primer plano** (tvOS suspende apps en segundo plano).
- El iPhone/Mac están en la misma red local que el Apple TV.

## 2. Fuera de alcance (v1)

- Cola de links con la app cerrada, historial de enviados, varios Apple TV (→ requieren relay en zima, enfoque B; ver §10).
- Control remoto web (trackpad, botones de navegación, controles del player).
- Ver/gestionar tabs o favoritos desde el celular.
- Autenticación, HTTPS, emparejamiento.

## 3. Arquitectura

```
iPhone / iPad / Mac (navegador, Atajo, bookmarklet)
        │  HTTP/1.1 sobre TCP :8080 (LAN)
        ▼
Nebula (Apple TV)
  BrowserRemoteServer   NWListener + parser HTTP mínimo; entrega acciones al delegate
        │ delegate (siempre en main queue)
        ▼
  ViewController        conecta acciones con los flujos existentes
    ├─ BrowserNavigationService  requestForURLOrSearchString:
    ├─ BrowserTabCoordinator     createNewTabWithRequest:
    └─ BrowserPageActionCoordinator  campo editable activo (publica / acepta texto)
```

URL de acceso: `http://Alans-Apple-TV-4K.local:8080` (hostname Bonjour verificado con
`dns-sd -L` el 2026-10-25).

## 4. Componentes

### Nuevos
| Archivo | Responsabilidad | No sabe de |
|---|---|---|
| `BrowserRemoteServer.h/.m` | Abrir/cerrar `NWListener`, aceptar conexiones, parsear requests, enrutar, responder, mantener long-polls. Expone un protocolo `BrowserRemoteServerDelegate`. | WebKit, tabs, UI |
| `BrowserRemoteHTTP.h/.m` | Funciones puras: bytes → `BrowserRemoteRequest` (método, path, query, headers, body); respuesta → bytes. Sin red, testeable. | Sockets |
| `BrowserRemotePage.h/.m` | El HTML/CSS/JS de la página como string embebido (evita recursos en el pbxproj). | Todo lo demás |

### Cambios a código existente
| Archivo | Cambio |
|---|---|
| `ViewController.m` | Implementa `BrowserRemoteServerDelegate`; arranca/detiene el servidor con el ciclo de vida; publica estado (página y campo). |
| `BrowserPageActionCoordinator.h/.m` | Expone el campo editable activo (`id`, título, tipo, placeholder, valor inicial) y `commitRemoteText:forFieldID:submit:`. Notifica al host cuando el campo aparece/desaparece. |
| `BrowserPreferencesStore.h/.m` + Settings (`BrowserMenuCoordinator`) | Toggle **Nebula Remote** (ON por defecto) y fila que muestra la URL activa (incluye el puerto real). |
| `Info.plist` | `NSLocalNetworkUsageDescription` **solo si** el paso 1 demuestra que tvOS lo pide. |

## 5. API

Todas las respuestas JSON llevan `Content-Type: application/json; charset=utf-8`.

| Método y ruta | Entrada | Salida | Acción |
|---|---|---|---|
| `GET /` | query opcional `open=<texto>`, `tab=new` | HTML de la página | Si trae `open`, la página lo envía a `/api/open` al cargar (soporte bookmarklet). |
| `GET /api/state?v=<n>` | `v` = última versión vista (0 al inicio) | `{v, page:{title,url}, field:null\|{id,title,type,placeholder,value}}` | **Long-poll:** responde inmediato si `v` ≠ versión actual; si no, espera hasta un cambio o 25 s. |
| `POST /api/open` | `{"text": string, "newTab": bool}` | `{"ok":true}` | `requestForURLOrSearchString:` → `loadRequest:` en la tab activa o `createNewTabWithRequest:`. |
| `POST /api/field` | `{"id": string, "text": string, "submit": bool}` | `{"ok":true}` o `409` | Llena el campo activo (ver §6). |

La versión de estado (`v`) se incrementa cuando cambia el título/URL de la tab activa o cuando aparece/desaparece un campo.

## 6. Flujo del campo de texto (caso 3)

1. El usuario hace click en un campo en la TV. El flujo actual
   (`presentEditableFieldPromptForFieldType:point:webView:`) crea el `UITextField` oculto y abre el
   teclado de tvOS. **Además**, ahora genera un `id` (UUID) y publica `field` en el estado.
2. El long-poll del celular responde; la página muestra "Nebula pide: *<título>*" con el `type` de
   input correspondiente (`email`, `password`, `number`, `url`, `text`, …) y el valor inicial.
3. `POST /api/field` con el `id` vigente: se asigna el texto al campo oculto y se llama
   `resignFirstResponder`. Eso cierra el teclado de la TV y dispara el handler `EditingDidEnd`
   existente → `commitEditableText:atPoint:webView:submitForm:NO`. Una sola ruta de escritura.
   Si `submit` es true, después del commit se llama de nuevo con `submitForm:YES`.
4. Si el `id` no coincide con el campo activo (el usuario cerró el teclado en la TV o abrió otro
   campo) → `409 {"error":"field-not-active"}`; la página lo indica.
5. Cuando el campo desaparece por cualquier motivo, `field` vuelve a `null` y sube la versión.

## 7. Página del celular

Una sola página, sin dependencias externas, funcional en Safari iOS y navegadores de escritorio:

- Caja de texto grande + botones **Abrir** y **Abrir en tab nueva**.
- Cuando hay campo activo: tarjeta "Nebula pide: …" con el input del tipo correcto, botón **Enviar**
  y checkbox **Enviar formulario**.
- Línea de estado con el título de la página actual de la TV, y "Sin conexión" si el long-poll falla
  (reintenta con backoff 1→5 s).
- Tema oscuro, botones grandes; `<meta name="apple-mobile-web-app-capable">` para "Agregar a inicio".

### Enviar a la TV
- **Atajo (iOS y macOS):** recibe URLs del menú Compartir → "Obtener contenido de URL"
  `POST http://Alans-Apple-TV-4K.local:8080/api/open`, JSON `{text: <entrada>, newTab: true}`.
  Se documentan los pasos para crearlo (no se distribuye un archivo `.shortcut`).
- **Bookmarklet (Mac):**
  `javascript:window.open('http://Alans-Apple-TV-4K.local:8080/?tab=new&open='+encodeURIComponent(location.href))`.
  Navega en vez de usar `fetch` porque desde páginas `https://` un `fetch` a `http://` se bloquea por
  contenido mixto.

## 8. Ciclo de vida, seguridad y robustez

- **Ciclo de vida:** `ViewController` arranca el servidor en `UIApplicationDidBecomeActiveNotification`
  (si el toggle está ON) y lo detiene en `UIApplicationDidEnterBackgroundNotification`; ya observa
  ambas (`ViewController.m:366-382`). Las conexiones de long-poll pendientes se cierran al detener.
- **Puerto:** intenta 8080; si está ocupado, 8081 y 8082. Settings muestra el que quedó.
- **Seguridad (uso en casa):** sin autenticación. Mitigaciones: toggle para apagarlo, escucha solo con
  la app en primer plano, solo expone título/URL de la página actual (sin historial, cookies ni tabs).
- **Límites:** body ≤ 64 KB, headers ≤ 16 KB, 10 s para recibir la request completa, máx. 8
  conexiones simultáneas. Exceder → cerrar conexión (o `413` por tamaño).
- **Errores:** ruta desconocida `404`, método incorrecto `405`, JSON inválido o campos faltantes `400`,
  campo no activo `409`.
- **Hilos:** callbacks de `NWListener`/`NWConnection` en una queue serial propia; toda llamada al
  delegate se hace en el main queue. **Prohibido** usar la API JS síncrona
  (`stringByEvaluatingJavaScriptFromString`) desde estos callbacks (lección del crash de tvOS 27).

## 9. Pruebas

1. **Unitarias** (nuevo target de tests, solo para lógica pura): `BrowserRemoteHTTP` (requests
   completas/parciales/malformadas, límites de tamaño, query strings, respuestas) y el enrutamiento.
2. **Integración con `curl` desde la Mac contra el Apple TV real**, pegando la salida: `GET /`,
   `/api/state` (inmediato y long-poll), `/api/open` (tab actual y nueva), `/api/field` (ok y `409`),
   y errores `400/404/405/413`.
3. **Manual en la TV:** desde iPhone (página, "Agregar a inicio", Atajo) y desde la Mac (página,
   bookmarklet, Atajo de macOS). Comprobar convivencia del caso 3 con el "Teclado de Apple TV" del
   sistema en el iPhone.

## 10. Riesgos y preguntas abiertas

| Riesgo | Mitigación |
|---|---|
| tvOS 27 podría exigir permiso de red local para aceptar conexiones entrantes (no verificado). | **Paso 1 del plan:** prototipo mínimo (puerto + "Hola desde Nebula") probado con `curl` desde la Mac; agregar `NSLocalNetworkUsageDescription` si hace falta. |
| El "Teclado de Apple TV" del sistema en el iPhone podría competir con el caso 3. | Probarlo en el paso 1; documentar el comportamiento. En la Mac no existe, así que el caso 3 se mantiene. |
| El hostname `.local` cambia si se renombra el Apple TV. | Settings muestra la URL real; v2 puede anunciar un servicio Bonjour `_http._tcp` propio. |

**Evolución (v2+):** relay en zima (enfoque B) para cola de links con la app cerrada e historial; el
Atajo y la página solo cambiarían de URL. Control remoto web, estado de tabs.
