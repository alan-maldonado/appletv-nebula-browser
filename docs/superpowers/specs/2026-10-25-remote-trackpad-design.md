# Nebula Remote — Trackpad

- **Fecha:** 2026-10-25
- **Estado:** diseño aprobado por secciones en chat; pendiente revisión de este spec
- **Base:** `main` `0ef9b02` (Nebula Remote v1 + panel de administración)
- **Decisión:** A — WebSocket propio en el puerto 8080; mover desde el trackpad activa el modo cursor.

## 1. Objetivo

Controlar el cursor de Nebula en la TV desde el panel web: **mover, clic, scroll y doble clic**, desde la
Mac (trackpad/mouse con *pointer lock*) y desde el iPhone (arrastrar el dedo).

**Éxito:** el cursor sigue al trackpad de la Mac sin retraso perceptible (≲ 50 ms en la LAN) y clic,
doble clic y scroll se comportan como con el Siri Remote.

### Lo que dijo Alan
- Controlar el cursor desde el navegador de la Mac. Alcance v1: mover, clic, scroll, doble clic.
- Enfoque A (WebSocket en 8080) y auto-cambio a modo cursor.

### Supuestos
- También desde el iPhone con touch. Uso en casa; mismas guardas de `Host` que el resto del servidor.

## 2. Fuera de alcance
- Arrastrar/seleccionar texto, teclas sueltas (flechas, Enter, Esc), gestos de zoom.
- Mostrar en el panel una vista de lo que hay en la TV.

## 3. Arquitectura

```
Panel (Mac: pointer lock · iPhone: touch)        Nebula (Apple TV)
 área Trackpad ──acumula Δ por frame──▶  WS GET /api/trackpad (8080, guardas de Host)
 {"t":"m","dx":3,"dy":-1}  mover            BrowserRemoteServer
 {"t":"s","dx":0,"dy":40}  scroll             └ BrowserRemoteWebSocket (puro)
 {"t":"c"}                 clic                       │ delegate (main; Δ coalescidos)
 {"t":"d"}                 doble clic                 ▼
                                             ViewController → BrowserRemoteInputController
```

## 4. Componentes

### Nuevo: `BrowserRemoteWebSocket.h/.m` (solo Foundation + CommonCrypto; TDD)
- `NSString *BrowserRemoteWebSocketAccept(NSString *key)` — base64(SHA-1(key + `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)).
- `BOOL BrowserRemoteRequestIsWebSocketUpgrade(BrowserRemoteRequest *request)` — `GET`, `Upgrade: websocket`
  (sin importar mayúsculas), `Connection` contiene `upgrade`, `Sec-WebSocket-Version: 13`, `Sec-WebSocket-Key` presente.
- `NSData *BrowserRemoteWebSocketHandshakeResponse(NSString *key)` — `101 Switching Protocols`.
- Decodificador de frames del cliente: entrada = bytes acumulados; salida = estado (`incomplete`, `frame`,
  `protocol-error`) + opcode + payload + bytes consumidos. Reglas: el cliente **debe** enmascarar; solo
  frames finales (`FIN=1`, sin fragmentación); opcodes aceptados `text (1)`, `close (8)`, `ping (9)`,
  `pong (10)`; `binary (2)` y continuación (`0`) → error; payload ≤ 1024 bytes (largo 7 bits o 16 bits;
  64 bits → error).
- Codificador de frames del servidor (sin máscara): `close` (con código) y `pong`.
- Parseo de mensajes: `{"t":"m"|"s","dx":num,"dy":num}`, `{"t":"c"}`, `{"t":"d"}` → tipo + delta;
  cualquier otro → ignorado. Deltas acotados a ±500 por mensaje.

### Cambios
| Archivo | Cambio |
|---|---|
| `BrowserRemoteServer.h/.m` | `GET /api/trackpad` con upgrade válido (tras la guarda de `Host`) → responde 101 y la conexión pasa a modo WebSocket: lectura continua, sin el timeout de 10 s, cuenta para el máximo de 8, se cierra en `stop` (frame close 1001). Upgrade inválido en esa ruta → `400`. Mover/scroll se **coalescen**: los deltas se suman en la cola del servidor y se entrega uno solo al main mientras haya uno pendiente. Close del cliente → responde close y cierra; ping → pong; error de protocolo → close 1002 (1009 si es muy grande). Nuevo `GET /api/cursor` → `{"x":…,"y":…,"mode":"cursor"|"scroll"}` (diagnóstico/pruebas; **no** forma parte del long-poll). |
| `BrowserRemoteServer.h` (delegate) | `remoteServer:trackpadMoveBy:` (CGPoint), `remoteServer:trackpadScrollBy:` (CGPoint), `remoteServerTrackpadClick:`, `remoteServerTrackpadDoubleClick:`, `remoteServerCursorState:` → NSDictionary. |
| `BrowserRemoteInputController.h/.m` | `remoteMoveCursorBy:(CGPoint)delta` (mismo clamp 0…1920 × 0…1080 y hover asíncrono que el touch del Siri Remote; si `cursorModeEnabled` es NO lo activa primero); `remoteScrollBy:(CGPoint)delta` (vía `applyManualScrollDelta:`); `remoteClick` (acción primaria inmediata, sin la espera de 0.3 s; con la vista de tabs visible selecciona la tarjeta como el Siri Remote); `remoteDoubleClick` (pantalla completa del video bajo el cursor; si no hay video, nada). |
| `ViewController.m` | Implementa el delegate llamando al input controller. |
| `RemotePanel/*` | Sección **Trackpad** (§5). |

## 5. Panel

- Área grande "Clic para controlar la TV" + slider **Velocidad** (0.5×–4×, por defecto 2× en Mac y 3× en
  touch; guardado en `localStorage` por dispositivo) + botones **Clic** y **Doble clic** + indicador de
  conexión.
- **Mac:** clic en el área → `requestPointerLock`. Con el puntero tomado: `mousemove.movementX/Y` →
  mover; `click` → clic; `dblclick` → doble clic (sin mandar los dos clics previos: el clic se envía tras
  250 ms si no llega un segundo); `wheel` → scroll. `Esc` suelta (comportamiento del navegador).
- **iPhone:** 1 dedo arrastrando → mover; toque corto (< 200 ms y < 10 px) → clic; doble toque → doble
  clic; 2 dedos → scroll. `touch-action: none` en el área.
- Envío: los deltas se acumulan y se mandan una vez por `requestAnimationFrame` (≤ 60 mensajes/s).
- El WebSocket se abre al mostrar la sección (en escritorio, al cargar el panel) y se cierra al ocultarla
  o salir; reconexión con backoff 1→5 s; indicador naranja si está desconectado.
- Escritorio: Trackpad junto a Escribir en la fila superior; iPhone: nueva entrada en la barra de secciones.

## 6. Errores y robustez
- Mensaje JSON inválido o tipo desconocido → se ignora (la conexión sigue).
- Violación de protocolo → close 1002; payload > 1024 → close 1009.
- App a segundo plano → `stop` cierra con 1001; el panel reconecta al volver.
- Nada en estas rutas usa el puente JS síncrono; el hover sigue siendo asíncrono y coalescido.

## 7. Pruebas
1. **Unitarias (runner, TDD):** accept con el ejemplo del RFC 6455 (`dGhlIHNhbXBsZSBub25jZQ==` →
   `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`); detección de upgrade; frames enmascarados de 5 y 200 bytes (largo
   16 bits); frame incompleto/en pedazos; dos frames en un mismo buffer; sin máscara → error; binario y
   fragmentado → error; 64 bits → error; codificación de close y pong; parseo de mensajes y clamp ±500.
2. **Integración (script Python con socket crudo, sin dependencias) contra simulador y Apple TV:**
   handshake 101; `m` mueve el cursor (`GET /api/cursor` cambia); `s` no rompe; ráfaga de 600 mensajes
   termina con el cursor en el borde (clamp) y sin atrasos; close limpio; frame sin máscara → close 1002.
3. **Manual (Alan):** Mac con pointer lock y iPhone con touch en el Apple TV.

## 8. Riesgos
| Riesgo | Mitigación |
|---|---|
| Implementar WebSocket a mano tiene casos borde | Lógica pura con TDD + script de integración; solo el subconjunto necesario (texto ≤ 1 KB, sin fragmentación). |
| Main thread ocupado (página pesada) → cola de movimientos atrasada | Coalescido en la cola del servidor: nunca más de un movimiento pendiente. |
| Doble clic de la Mac genera clic + clic + dblclick | El panel retiene el clic 250 ms y lo descarta si llega `dblclick`. |
