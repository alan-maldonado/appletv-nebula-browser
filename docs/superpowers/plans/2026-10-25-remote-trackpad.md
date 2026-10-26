# Nebula Remote Trackpad Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Control Nebula's cursor (move, click, scroll, double click) from the web panel over a WebSocket on port 8080.

**Architecture:** A pure `BrowserRemoteWebSocket` module (handshake, frame codec, message parsing) is driven by `BrowserRemoteServer`, which upgrades `GET /api/trackpad`, coalesces deltas on its queue and calls new delegate methods on main; `BrowserRemoteInputController` gains remote move/scroll/click/double-click entry points reusing its Siri Remote logic. The panel adds a Trackpad section (pointer lock on Mac, touch on iPhone).

**Tech Stack:** Objective-C (ARC), Network.framework, Foundation + CommonCrypto (`CC_SHA1`), vanilla JS; Python 3 stdlib for the integration probe.

**Spec:** `docs/superpowers/specs/2026-10-25-remote-trackpad-design.md`

## Global Constraints

- Same port 8080 and v1 guards (trusted `Host`); WebSocket only on `GET /api/trackpad`; invalid upgrade there → `400`.
- Client frames must be masked; only `FIN=1`; opcodes text 1, close 8, ping 9, pong 10; binary 2 / continuation 0 → protocol error; payload ≤ 1024 bytes (7- or 16-bit length; 64-bit → error).
- Close codes: 1001 on `stop`, 1002 protocol error, 1009 too large.
- Messages: `{"t":"m"|"s","dx":n,"dy":n}`, `{"t":"c"}`, `{"t":"d"}`; deltas clamped to ±500; anything else ignored.
- Coalescing: at most one pending move and one pending scroll handed to main at a time; click/double click flush pending deltas first, preserving order.
- WebSocket connections: no 10 s receive timeout, count toward the 8-connection cap, closed by `stop`.
- Remote move/click turn cursor mode on if it is off; double click = fullscreen video under the cursor, nothing else (no mode toggle).
- `GET /api/cursor` → `{"x":…,"y":…,"mode":"cursor"|"scroll"}`; never part of `/api/state`.
- Panel: speed 0.5×–4×, default 2× (Mac) / 3× (touch), `localStorage` key `nebula.trackpadSpeed`; ≤ 1 message per `requestAnimationFrame`; Mac click held 250 ms and dropped if `dblclick` follows; touch tap < 200 ms and < 10 px; reconnect backoff 1→5 s.
- No sync JS bridge on these paths. No Claude attribution in commits; no push.
- Simulator `EC7DFAE5-EB56-4ABA-A60E-8E30B6272E9C` (`localhost:8080`) and Apple TV `8A8AC9FF-CBEE-5765-9D56-FF9194B0F29F` (`Alans-Apple-TV-4K.local:8080`), build/install commands as in the admin-panel plan.

## Review Focus

1. **Main thread busy while the trackpad streams** → the cursor must stop when the finger stops (no queued backlog). → Task 2 probe `burst-then-still` (cursor equal in two reads 300 ms apart right after a 600-message burst).
2. **Two clients at once (Mac + iPhone)** → both move the cursor, nothing crashes, the HTTP panel still answers. → Task 2 probe `two-clients`.
3. **App backgrounded with a WebSocket open** → client receives close 1001 promptly; panel reconnects on return. → Task 2 Step 6 (device: launch TVSettings).
4. **Click while the TV is in scroll mode** → switches to cursor mode and clicks at the cursor (like moving does). → Task 2 probe `click-in-scroll-mode` via `/api/cursor` mode.
5. **Pointer lock lost mid-drag (Esc, tab hidden, section switched)** → no stuck state; socket closes when the section hides and reopens when shown. → Task 3 Step 4 Chrome check.

---

### Task 1: BrowserRemoteWebSocket (pure, TDD)

**Files:** Create `_Project/Browser/BrowserRemoteWebSocket.h/.m`; modify `_Project/Tests/BrowserRemoteTests.m`, `_Project/Tests/run-remote-tests.sh` (add the `.m`), `_Project/Browser.xcodeproj/project.pbxproj`.

**Interfaces — Produces:**
```objc
typedef NS_ENUM(NSInteger, BrowserRemoteFrameStatus) {
    BrowserRemoteFrameStatusIncomplete, BrowserRemoteFrameStatusFrame,
    BrowserRemoteFrameStatusProtocolError, BrowserRemoteFrameStatusTooLarge };
@interface BrowserRemoteFrame : NSObject
@property (nonatomic, readonly) uint8_t opcode;      // 1 text, 8 close, 9 ping, 10 pong
@property (nonatomic, readonly) NSData *payload;     // unmasked
@end
NSString *BrowserRemoteWebSocketAccept(NSString *key);
BOOL BrowserRemoteRequestIsWebSocketUpgrade(BrowserRemoteRequest *request);
NSData *BrowserRemoteWebSocketHandshakeResponse(NSString *key);   // "HTTP/1.1 101 Switching Protocols" + Upgrade/Connection/Sec-WebSocket-Accept
// Decodes the first frame in buffer; *outConsumed = bytes used when status is Frame.
BrowserRemoteFrameStatus BrowserRemoteDecodeFrame(NSData *buffer, BrowserRemoteFrame * _Nullable * _Nullable outFrame, NSUInteger *outConsumed);
NSData *BrowserRemoteEncodeFrame(uint8_t opcode, NSData *payload);  // FIN, unmasked
NSData *BrowserRemoteCloseFrame(uint16_t code);                     // opcode 8, 2-byte big-endian code
typedef NS_ENUM(NSInteger, BrowserRemoteTrackpadKind) {
    BrowserRemoteTrackpadKindNone, BrowserRemoteTrackpadKindMove, BrowserRemoteTrackpadKindScroll,
    BrowserRemoteTrackpadKindClick, BrowserRemoteTrackpadKindDoubleClick };
BrowserRemoteTrackpadKind BrowserRemoteParseTrackpadMessage(NSData *payload, double *outDX, double *outDY);
```

- [ ] **Step 1: Failing tests** (helper `MaskedFrame(opcode, payload, mask)` builds client frames in the test file):
  - `testWebSocketAcceptMatchesRFC` — `BrowserRemoteWebSocketAccept(@"dGhlIHNhbXBsZSBub25jZQ==")` = `@"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="`.
  - `testDetectsUpgrade` — `GET /api/trackpad` with `Upgrade: WebSocket`, `Connection: keep-alive, Upgrade`, `Sec-WebSocket-Version: 13`, `Sec-WebSocket-Key: x` → YES; missing key → NO; version 8 → NO; `POST` → NO.
  - `testDecodesRFCMaskedHello` — bytes `81 85 37 fa 21 3d 7f 9f 4d 51 58` → Frame, opcode 1, payload `Hello`, consumed 11.
  - `testDecodes16BitLength` — masked text of 200 bytes → Frame, payload length 200, consumed 2+2+4+200.
  - `testIncompleteAndTwoFrames` — first 6 bytes of the RFC frame → Incomplete; RFC frame twice concatenated → first decode consumed 11, decoding the rest yields the second `Hello`.
  - `testRejectsUnmaskedBinaryFragmented` — unmasked `81 05 48 65 6c 6c 6f` → ProtocolError; masked opcode 2 → ProtocolError; masked text with FIN=0 (`01 …`) → ProtocolError; length byte 127 → ProtocolError.
  - `testRejectsOversizedPayload` — masked text with 16-bit length 1025 (header only) → TooLarge.
  - `testEncodesCloseAndPong` — `BrowserRemoteCloseFrame(1002)` = `88 02 03 ea`; `BrowserRemoteEncodeFrame(10, "hi")` = `8a 02 68 69`.
  - `testParsesTrackpadMessages` — `{"t":"m","dx":3,"dy":-1}` → Move, 3, -1; `{"t":"s","dx":0,"dy":40}` → Scroll; `{"t":"c"}` → Click; `{"t":"d"}` → DoubleClick; `{"t":"m","dx":9999,"dy":-9999}` → 500, -500; `{"t":"x"}`, `nope`, `{"t":"m","dx":"a"}` → None.
- [ ] **Step 2: Run** `_Project/Tests/run-remote-tests.sh` → compile error (missing header).
- [ ] **Step 3: Implement** (SHA-1 via `CC_SHA1` from `<CommonCrypto/CommonDigest.h>`; header names compared case-insensitively since keys are already lowercased).
- [ ] **Step 4: Run** → `34/34 passed`.
- [ ] **Step 5: Add to pbxproj, build for simulator, commit** — `git commit -m "Trackpad: WebSocket codec (TDD)"`

### Task 2: Server WebSocket, input controller, cursor endpoint — verified on device

**Files:** Modify `BrowserRemoteServer.h/.m`, `BrowserRemoteInputController.h/.m`, `ViewController.m`; create `_Project/Tests/trackpad_probe.py`.

**Interfaces:**
- Consumes: Task 1.
- Produces (delegate, main queue): `- (void)remoteServer:(BrowserRemoteServer *)server trackpadMoveBy:(CGPoint)delta;`, `- (void)remoteServer:(BrowserRemoteServer *)server trackpadScrollBy:(CGPoint)delta;`, `- (void)remoteServerTrackpadClick:(BrowserRemoteServer *)server;`, `- (void)remoteServerTrackpadDoubleClick:(BrowserRemoteServer *)server;`, `- (NSDictionary *)remoteServerCursorState:(BrowserRemoteServer *)server;`.
- Produces (`BrowserRemoteInputController`): `- (void)remoteMoveCursorBy:(CGPoint)delta;`, `- (void)remoteScrollBy:(CGPoint)delta;`, `- (void)remoteClick;`, `- (void)remoteDoubleClick;`. Move reuses the touch path's clamp (origin 0…1920 × 0…1080) and `requestHoverStateUpdate`; move and click enable cursor mode first when off; click → `browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:` when the overview is visible, else `browserRemoteInputControllerHandlePrimaryAction` (no 0.3 s wait); double click → `browserRemoteInputControllerFullscreenVideoAtCursorWithCompletion:` ignoring the result; scroll → `applyManualScrollDelta:`.

- [ ] **Step 1: Server** — `BrowserRemoteConnection` gains `webSocket` (BOOL) and pending `moveDX/moveDY/scrollDX/scrollDY` + `moveScheduled/scrollScheduled`. In `route:`, `GET /api/trackpad`: upgrade valid → send handshake, mark `webSocket`, keep bytes after `\r\n\r\n` in the buffer, start the frame loop; invalid → `400`. Frame loop decodes all complete frames per read; text → parse → accumulate (schedule one main-queue hop when none is scheduled, reading and zeroing the accumulator inside the hop on the server queue first); click/double → flush accumulators then dispatch; ping → pong; close → close frame echo then cancel; ProtocolError → `BrowserRemoteCloseFrame(1002)`; TooLarge → 1009. Receive timeout skips `webSocket` clients. `stop` sends close 1001 to WebSocket clients before cancelling. `GET /api/cursor` → `remoteServerCursorState:` JSON.
- [ ] **Step 2: Input controller + ViewController** per Interfaces.
- [ ] **Step 3: Probe script** `_Project/Tests/trackpad_probe.py HOST[:PORT]` (stdlib `socket`, masks frames, prints PASS/FAIL per check, exit code ≠ 0 on failure). Checks:
  - `handshake` — 101 and correct `Sec-WebSocket-Accept`.
  - `move` — `/api/cursor` before; send `m` dx 100 dy 0; within 500 ms x increased by 100 (or reached the clamp).
  - `burst-then-still` — 600 × `m` dx 5; then two `/api/cursor` reads 300 ms apart are equal (no backlog) and the burst took < 3 s end to end.
  - `click-in-scroll-mode` — only when `/api/cursor` reports `scroll`: send `c` → mode becomes `cursor`. Otherwise prints SKIP.
  - `two-clients` — two sockets each send `m` dx 10; x increased by ≥ 20; `GET /` still 200.
  - `close` — client close 1000 → server echoes close.
  - `unmasked` — unmasked text frame → server close with code 1002.
- [ ] **Step 4: Run on the simulator** (build/install/launch) → all PASS (SKIP allowed for `click-in-scroll-mode`).
- [ ] **Step 5: Run on the Apple TV** (build/install/launch) → all PASS; **tell Alan the cursor can be driven by the probe already** (prototype checkpoint).
- [ ] **Step 6: Background check (device)** — open a socket, `xcrun devicectl device process launch --device $DEV com.apple.TVSettings` → probe receives close 1001 within 2 s; relaunch Nebula → `handshake` PASS again.
- [ ] **Step 7: Commit** — `git commit -m "Trackpad: WebSocket endpoint and remote cursor control"`

### Task 3: Panel Trackpad section

**Files:** `RemotePanel/index.html`, `app.css`, `app.js`.

- [ ] **Step 1: Markup + styles** — section `#trackpad` with `.pad` area (`touch-action:none`, min-height 260 px, cursor/hint text "Clic para controlar la TV" on desktop, "Arrastra para mover el cursor" on touch), speed `<input type=range min=0.5 max=4 step=0.25>`, **Clic** / **Doble clic** buttons, status line; nav entry "Trackpad"; desktop grid row `"write trackpad"`.
- [ ] **Step 2: Socket client** — `openTrackpad()` / `closeTrackpad()` (ws URL from `location.host` + `/api/trackpad`), reconnect backoff 1→5 s while the section is visible; open when the section is shown (always on desktop ≥ 900 px), close when hidden and on `pagehide`; accumulator flushed once per `requestAnimationFrame`.
- [ ] **Step 3: Input** — Mac: click on `.pad` → `requestPointerLock()`; while locked `mousemove` adds `movementX/Y × speed`; `click` held 250 ms (cancelled by `dblclick`, which sends `d`); `wheel` adds `deltaX/deltaY` to scroll; `pointerlockchange` updates the hint ("Esc para soltar"). Touch: 1 finger moves (`× speed`), tap < 200 ms and < 10 px → `c`, second tap within 300 ms → `d` (the first tap's click is held like on Mac), 2 fingers → scroll. Speed saved to `localStorage['nebula.trackpadSpeed']` (try/catch; defaults 2 / 3).
- [ ] **Step 4: Verify** — `node --check`; simulator in Chrome: section renders on desktop and narrow widths, status "Conectado"; click the pad → pointer lock hint; buttons Clic/Doble clic produce probe-visible effects (`/api/cursor` mode becomes `cursor`); switching sections closes the socket (server sees close) and coming back reconnects. Then deploy to the Apple TV and **hand to Alan** for the real Mac/iPhone feel.
- [ ] **Step 5: Commit** — `git commit -m "Trackpad: panel section with pointer lock and touch"`

### Task 4: Final review

- [ ] Fresh reviewer (most capable model) over the branch with spec, Review Focus and ledger rulings; one fix pass for Critical/Important (test first where possible); README "Nebula Remote" gains a Trackpad line.
