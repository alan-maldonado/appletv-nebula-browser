# Nebula Remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any browser on the home network (iPhone, iPad, Mac) type URLs, open new tabs and fill the active text field in Nebula through an HTTP server embedded in the tvOS app.

**Architecture:** `BrowserRemoteServer` (Network.framework `nw_listener` on its own serial queue) parses requests with the pure-Foundation `BrowserRemoteHTTP`, keeps long-polls against a main-thread `BrowserRemoteState`, and hands actions to `ViewController` through `BrowserRemoteServerDelegate`, which reuses the existing navigation, tab and editable-field flows. The phone page is an embedded string in `BrowserRemotePage`.

**Tech Stack:** Objective-C (ARC), UIKit/tvOS 15.6+, Network.framework C API, Foundation; pure-logic tests compiled for macOS with `xcrun clang`.

**Spec:** `docs/superpowers/specs/2026-10-25-remote-input-design.md`

## Global Constraints

- Deployment target stays `TVOS_DEPLOYMENT_TARGET = 15.6`; no third-party dependencies.
- Port 8080, fallback 8081 then 8082; URL shown as `http://<hostname>:<port>`.
- Limits: body ≤ 64 KB (`413` beyond), headers ≤ 16 KB, 10 s to receive a full request, max 8 simultaneous connections, long-poll timeout 25 s.
- Errors: unknown route `404`, wrong method `405`, invalid JSON / missing keys `400`, inactive field `409 {"error":"field-not-active"}`.
- All delegate calls and `BrowserRemoteState` access on the main queue; never call `stringByEvaluatingJavaScriptFromString` from server paths.
- Server runs only while the app is active (start on `UIApplicationDidBecomeActiveNotification`, stop on `UIApplicationDidEnterBackgroundNotification`) and only if the **Nebula Remote** preference is ON (default ON).
- `BrowserRemoteHTTP` and `BrowserRemoteState` import only Foundation (so they compile in the macOS test runner).
- New `.m` files are added to `Browser.xcodeproj/project.pbxproj` with 4 entries each (PBXBuildFile, PBXFileReference, the `Browser` group, the Sources phase), mirroring `BrowserSessionStore.m`; validate with `plutil -lint`.
- Commits: no Claude attribution; Alan pushes.
- Build/install/launch on the Apple TV (used by every "verify on device" step):
  ```bash
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; DEV=8A8AC9FF-CBEE-5765-9D56-FF9194B0F29F
  APP=~/Library/Developer/Xcode/DerivedData/Browser-cuoiltoxxnqimthedeqcgquqiram/Build/Products/Debug-appletvos/Browser.app
  cd _Project && xcodebuild -project Browser.xcodeproj -scheme Browser -destination "id=$DEV" -configuration Debug build -allowProvisioningUpdates | grep -E "error:|BUILD"
  xcrun devicectl device install app --device $DEV "$APP"
  xcrun devicectl device process launch --terminate-existing --device $DEV app.orbitlabs.tvbrowser
  ```

**Deviation from spec §9:** the spec says "nuevo target de tests". This plan uses a standalone macOS test runner (`_Project/Tests/run-remote-tests.sh`) instead of an XCTest target, to avoid hand-editing a test target into the pbxproj. Same coverage; flagged for Alan's review.

## Review Focus

1. **Request split across TCP reads** (headers in one packet, body in the next) — must be reassembled, not rejected. → Task 2 `testParsesRequestSplitAcrossChunks`.
2. **Non-ASCII text** (accents, emoji, "ñ" in a search) must arrive intact, including via `?open=` percent-encoding. → Task 2 `testDecodesUTF8BodyAndPercentEncodedQuery`.
3. **Phone keeps a long-poll open while Nebula goes to background** — stopping must close it so the page shows "Sin conexión" and reconnects, not hang. → Task 3 Step 6 (`curl` long-poll then background the app).
4. **Field submitted after the TV user dismissed the keyboard** — must be `409`, never write into whatever field is focused next. → Task 5 Step 4.
5. **`open` text that is neither URL nor search-worthy** (empty / whitespace) — must be `400`, not load a blank page. → Task 2 `testOpenPayloadRejectsBlankText` (validation lives in `BrowserRemoteOpenPayloadFromJSON`).

---

### Task 1: Prototype — "Hola desde Nebula" on port 8080

Resolves the spec's top risk (local-network permission for inbound connections on tvOS 27) before anything else is built.

**Files:**
- Create: `_Project/Browser/BrowserRemoteServer.h`, `_Project/Browser/BrowserRemoteServer.m`
- Modify: `_Project/Browser.xcodeproj/project.pbxproj` (add `BrowserRemoteServer.m`)
- Modify: `_Project/Browser/ViewController.m` (property, start/stop in the existing `handleApplicationDidBecomeActive:` / `handleApplicationDidEnterBackground:`)
- Maybe modify: `_Project/Browser/Info.plist` (`NSLocalNetworkUsageDescription`, only if Step 4 shows it is required)

**Interfaces:**
- Produces: `@interface BrowserRemoteServer : NSObject` with `- (void)start;`, `- (void)stop;`, `@property (nonatomic, readonly) uint16_t port;` (0 while stopped). Task 3 extends this class; keep these names.

- [ ] **Step 1: Implement the minimal server** in `BrowserRemoteServer.m`: `nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION)`, `nw_listener_create_with_port("8080", …)`, queue `dispatch_queue_create("app.orbitlabs.tvbrowser.remote", DISPATCH_QUEUE_SERIAL)`; for each connection, read once and reply `HTTP/1.1 200 OK` with `Content-Type: text/html; charset=utf-8`, `Connection: close` and body `<h1>Hola desde Nebula</h1>`, then cancel. Log listener state changes with `NSLog(@"[Remote] …")`.
- [ ] **Step 2: Wire lifecycle** in `ViewController.m`: `self.remoteServer` created in `viewDidLoad`, `[self.remoteServer start]` in `handleApplicationDidBecomeActive:`, `[self.remoteServer stop]` in `handleApplicationDidEnterBackground:`.
- [ ] **Step 3: Add the file to the pbxproj, build, install, launch** (Global Constraints commands). Expected: `** BUILD SUCCEEDED **`, `plutil -lint` OK.
- [ ] **Step 4: Verify from the Mac**
  Run: `curl -sv --max-time 5 http://Alans-Apple-TV-4K.local:8080/`
  Expected: `< HTTP/1.1 200 OK` and `<h1>Hola desde Nebula</h1>`.
  If refused/timeout: check the TV for a permission prompt and the device log for `[Remote]`; add `NSLocalNetworkUsageDescription` = `Nebula uses your local network so your iPhone or Mac can type into the browser.` to `Info.plist`, rebuild, retry. Record which case happened in the commit message.
- [ ] **Step 5: Check the system "Apple TV Keyboard"** — on the TV, click a text field in a page (e.g. google.com search) and confirm whether the iPhone shows the keyboard notification. Write the result (works / doesn't) in the commit message; it informs Task 5's manual test.
- [ ] **Step 6: Commit**
  ```bash
  git add _Project/Browser/BrowserRemoteServer.[hm] _Project/Browser/ViewController.m _Project/Browser.xcodeproj/project.pbxproj _Project/Browser/Info.plist
  git commit -m "Nebula Remote: prototype HTTP listener on :8080"
  ```

### Task 2: Pure HTTP parsing, payloads and state (TDD)

**Files:**
- Create: `_Project/Browser/BrowserRemoteHTTP.h`, `_Project/Browser/BrowserRemoteHTTP.m`
- Create: `_Project/Browser/BrowserRemoteState.h`, `_Project/Browser/BrowserRemoteState.m`
- Create: `_Project/Tests/BrowserRemoteTests.m`, `_Project/Tests/run-remote-tests.sh`
- Modify: `_Project/Browser.xcodeproj/project.pbxproj` (add both `.m`)

**Interfaces:**
- Produces (`BrowserRemoteHTTP.h`):
  - `typedef NS_ENUM(NSInteger, BrowserRemoteParseStatus) { BrowserRemoteParseStatusIncomplete, BrowserRemoteParseStatusComplete, BrowserRemoteParseStatusInvalid, BrowserRemoteParseStatusTooLarge };`
  - `@interface BrowserRemoteRequest : NSObject` — readonly `NSString *method`, `NSString *path` (no query), `NSDictionary<NSString *, NSString *> *query` (percent-decoded), `NSDictionary<NSString *, NSString *> *headers` (lowercased keys), `NSData *body`; `- (nullable id)JSONBody;`
  - `BrowserRemoteParseStatus BrowserRemoteParseRequest(NSData *buffer, BrowserRemoteRequest * _Nullable * _Nullable outRequest);` — `Complete` only when `Content-Length` bytes of body are present; `TooLarge` when headers > 16384 bytes without terminator or `Content-Length` > 65536.
  - `NSData *BrowserRemoteResponseData(NSInteger status, NSString *contentType, NSData *body);` — status line + `Content-Type`, `Content-Length`, `Connection: close`, `Cache-Control: no-store`.
  - `NSData *BrowserRemoteJSONResponseData(NSInteger status, id JSONObject);`
  - `NSString * _Nullable BrowserRemoteOpenPayloadFromJSON(id JSON, BOOL *outNewTab);` — returns trimmed `text` or nil if missing/not a string/blank; `newTab` defaults NO.
  - `NSDictionary * _Nullable BrowserRemoteFieldPayloadFromJSON(id JSON);` — keys `id`, `text` (strings, `text` may be empty), `submit` (NSNumber bool, default NO); nil if `id`/`text` missing.
- Produces (`BrowserRemoteState.h`, main-thread only):
  - `@property (nonatomic, readonly) NSUInteger version;` (starts at 1)
  - `- (void)updatePageTitle:(NSString *)title URLString:(NSString *)URLString;` — bumps version only if either changed.
  - `- (void)updateField:(nullable NSDictionary<NSString *, NSString *> *)field;` — keys `id,title,type,placeholder,value`; bumps only if changed.
  - `- (NSDictionary *)JSONObject;` → `@{@"v": @(version), @"page": @{@"title":…, @"url":…}, @"field": field ?: NSNull.null}`

- [ ] **Step 1: Write the test runner** `_Project/Tests/run-remote-tests.sh`:
  ```bash
  #!/bin/zsh
  set -e
  cd "$(dirname "$0")/.."
  OUT=$(mktemp -d)/remote-tests
  xcrun clang -fobjc-arc -framework Foundation -I Browser \
    Browser/BrowserRemoteHTTP.m Browser/BrowserRemoteState.m Tests/BrowserRemoteTests.m -o "$OUT"
  "$OUT"
  ```
  `BrowserRemoteTests.m` has a `main` that runs each `test…` function, prints `PASS name` / `FAIL name: reason`, and exits non-zero on any failure.
- [ ] **Step 2: Write the failing tests** (assertions exactly as listed):
  - `testParsesSimpleGET` — `"GET /api/state?v=3 HTTP/1.1\r\nHost: x\r\n\r\n"` → Complete, method `GET`, path `/api/state`, `query[@"v"]` = `@"3"`.
  - `testParsesRequestSplitAcrossChunks` — headers with `Content-Length: 26` but only 10 body bytes → Incomplete; full 26 bytes → Complete and `JSONBody[@"text"]` = `@"hola"` for body `{"text":"hola","newTab":1}` (26 bytes).
  - `testDecodesUTF8BodyAndPercentEncodedQuery` — body `{"text":"mañana 🎬"}` → `JSONBody[@"text"]` equals `@"mañana 🎬"`; `GET /?open=ma%C3%B1ana%20%F0%9F%8E%AC&tab=new` → `query[@"open"]` = `@"mañana 🎬"`, `query[@"tab"]` = `@"new"`.
  - `testHeaderKeysAreLowercased` — `Content-Type: application/json` → `headers[@"content-type"]`.
  - `testRejectsMalformedRequestLine` — `"HELLO\r\n\r\n"` → Invalid.
  - `testRejectsOversizedBody` — `Content-Length: 65537` → TooLarge.
  - `testRejectsOversizedHeaders` — 16385 bytes with no `\r\n\r\n` → TooLarge.
  - `testInvalidJSONBodyReturnsNil` — body `{nope` → `JSONBody` nil.
  - `testResponseHasLengthAndClose` — `BrowserRemoteResponseData(404, @"text/plain", "no")` starts with `HTTP/1.1 404 Not Found\r\n` and contains `Content-Length: 2` and `Connection: close`.
  - `testOpenPayloadRejectsBlankText` — `@{@"text": @"   "}` → nil; `@{@"text": @" apple.com ", @"newTab": @YES}` → `@"apple.com"`, newTab YES; `@{@"text": @3}` → nil.
  - `testFieldPayloadRequiresIDAndText` — missing `id` → nil; `@{@"id":@"a", @"text":@""}` → submit NO, text `@""`.
  - `testStateVersionBumpsOnlyOnChange` — new state v=1; same title/URL twice → v=2 once; `updateField:` dict → v=3, `JSONObject[@"field"][@"id"]` = its `id`; `updateField:nil` → v=4, `JSONObject[@"field"]` is `NSNull`.
- [ ] **Step 3: Run tests to verify they fail**
  Run: `_Project/Tests/run-remote-tests.sh`
  Expected: compile error (missing `BrowserRemoteHTTP.h`).
- [ ] **Step 4: Implement `BrowserRemoteHTTP.m` and `BrowserRemoteState.m`** with the signatures above. Parse by locating `\r\n\r\n` in the raw bytes (not by decoding the whole buffer as a string), header block as ASCII/UTF-8, query via `NSURLComponents` `queryItems` (handles percent-decoding).
- [ ] **Step 5: Run tests to verify they pass**
  Run: `_Project/Tests/run-remote-tests.sh`
  Expected: 12 `PASS` lines, exit 0.
- [ ] **Step 6: Add both `.m` to the pbxproj and build for the device.** Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit**
  ```bash
  git add _Project/Browser/BrowserRemoteHTTP.[hm] _Project/Browser/BrowserRemoteState.[hm] _Project/Tests _Project/Browser.xcodeproj/project.pbxproj
  git commit -m "Nebula Remote: HTTP parsing, payloads and state with tests"
  ```

### Task 3: Server routing, limits and long-poll

**Files:**
- Modify: `_Project/Browser/BrowserRemoteServer.h`, `_Project/Browser/BrowserRemoteServer.m`

**Interfaces:**
- Consumes: Task 2 (`BrowserRemoteParseRequest`, `BrowserRemoteJSONResponseData`, payload helpers, `BrowserRemoteState`).
- Produces:
  ```objc
  @protocol BrowserRemoteServerDelegate <NSObject>
  - (void)remoteServer:(BrowserRemoteServer *)server openText:(NSString *)text inNewTab:(BOOL)newTab;
  // Return NO when fieldID is not the active field (server answers 409).
  - (BOOL)remoteServer:(BrowserRemoteServer *)server submitFieldText:(NSString *)text fieldID:(NSString *)fieldID submitForm:(BOOL)submitForm;
  - (NSString *)remoteServerPageHTML:(BrowserRemoteServer *)server;
  @end
  ```
  On `BrowserRemoteServer`: `@property (nonatomic, weak) id<BrowserRemoteServerDelegate> delegate;`, `@property (nonatomic, readonly) BrowserRemoteState *state;` (main thread), `- (void)stateDidChange;` (main thread; answers waiting long-polls with the new `state.JSONObject`).

- [ ] **Step 1: Replace the prototype handler with routing**: accumulate reads until `BrowserRemoteParseRequest` returns Complete/Invalid/TooLarge (`400`/`413` then close); 10 s receive timer per connection; refuse beyond 8 open connections (close immediately). Routes: `GET /` → `remoteServerPageHTML:` (`text/html; charset=utf-8`); `GET /api/state`; `POST /api/open`; `POST /api/field`; known path + wrong method → `405`; else `404`. Delegate/state calls hop to the main queue; responses are written back on the server queue.
- [ ] **Step 2: Long-poll**: `GET /api/state?v=<n>` — on main, if `n != state.version` reply now; else park the connection (server queue list) with a 25 s timer that replies with the current state. `stateDidChange` snapshots `state.JSONObject` on main and flushes all parked connections. `stop` replies nothing, cancels all connections and the listener.
- [ ] **Step 3: Port fallback**: try `"8080"`, then `"8081"`, `"8082"` when the listener fails with `EADDRINUSE`; set `port` from `nw_listener_get_port` once `nw_listener_state_ready`.
- [ ] **Step 4: Temporary delegate in `ViewController`**: `remoteServerPageHTML:` returns `@"<h1>Nebula Remote</h1>"` (Task 6 replaces it); open/field log only. Build, install, launch.
- [ ] **Step 5: Verify routing and errors from the Mac** (paste real output):
  ```bash
  H=http://Alans-Apple-TV-4K.local:8080
  curl -s -o /dev/null -w "%{http_code}\n" $H/                      # 200
  curl -s $H/api/state?v=0                                           # {"v":1,...,"field":null}
  curl -s -o /dev/null -w "%{http_code}\n" $H/nope                   # 404
  curl -s -o /dev/null -w "%{http_code}\n" -X GET $H/api/open        # 405
  curl -s -o /dev/null -w "%{http_code}\n" -d '{nope' $H/api/open    # 400
  head -c 70000 /dev/zero | curl -s -o /dev/null -w "%{http_code}\n" --data-binary @- $H/api/open   # 413
  time curl -s "$H/api/state?v=1"                                    # returns after ~25 s
  ```
- [ ] **Step 6: Verify long-poll on background (Review Focus 3)**: start `curl -s "$H/api/state?v=1"`, press Home on the Siri Remote within 25 s. Expected: curl ends promptly with an empty reply / connection closed, not after 25 s.
- [ ] **Step 7: Commit** — `git commit -m "Nebula Remote: routing, limits and long-poll"`

### Task 4: Open URL / new tab and page state

**Files:**
- Modify: `_Project/Browser/ViewController.m`
- Modify: `_Project/Browser/BrowserTabCoordinator.h`, `_Project/Browser/BrowserTabCoordinator.m` (`refreshActiveTabUI` notifies the host)

**Interfaces:**
- Consumes: `BrowserRemoteServerDelegate`, `server.state`, `stateDidChange` (Task 3); `requestForURLOrSearchString:` (`BrowserNavigationService`), `createNewTabWithRequest:` (`BrowserTabCoordinator`), `[self.webview loadRequest:]`.
- Produces: `- (void)browserTabCoordinatorActiveTabDidRefresh;` on `BrowserTabCoordinatorHost`.

- [ ] **Step 1: Implement `remoteServer:openText:inNewTab:`** — build the request with `requestForURLOrSearchString:`; nil → ignore; `newTab` → `[self.tabCoordinator createNewTabWithRequest:]`, else `[self.webview loadRequest:]`. Dismiss nothing else; if a modal (menu/alert) is presented, still load (the page shows behind it).
- [ ] **Step 2: Publish page state** — call `[self.host browserTabCoordinatorActiveTabDidRefresh]` at the end of `refreshActiveTabUI`; in `ViewController` update `state` with `self.webview.title` and the active tab URL, then `[self.remoteServer stateDidChange]`.
- [ ] **Step 3: Build, install, launch, verify from the Mac**:
  ```bash
  curl -s -d '{"text":"apple.com"}' $H/api/open            # {"ok":true}; TV loads apple.com
  curl -s -d '{"text":"mañana 🎬","newTab":true}' $H/api/open   # new tab with a search for "mañana 🎬"
  curl -s "$H/api/state?v=0"                               # page.title / page.url of the active tab
  ```
  Expected: TV shows each result; state reflects the active tab; accented/emoji search text intact.
- [ ] **Step 4: Commit** — `git commit -m "Nebula Remote: open URL or search, new tab, page state"`

### Task 5: Fill the active text field

**Files:**
- Modify: `_Project/Browser/BrowserPageActionCoordinator.h`, `_Project/Browser/BrowserPageActionCoordinator.m`
- Modify: `_Project/Browser/ViewController.m`

**Interfaces:**
- Produces on `BrowserPageActionCoordinatorHost`: `- (void)browserPageActionCoordinatorActiveFieldDidChange:(nullable NSDictionary<NSString *, NSString *> *)field;` (keys `id,title,type,placeholder,value`; nil when gone).
- Produces on `BrowserPageActionCoordinator`: `- (BOOL)commitRemoteText:(NSString *)text forFieldID:(NSString *)fieldID submitForm:(BOOL)submitForm;`

- [ ] **Step 1: Publish the field** — in `presentEditableFieldPromptForFieldType:point:webView:` generate `NSUUID` id, keep it in `activeEditableFieldID`, call the host with `{id, title: fieldTitle, type: fieldType, placeholder, value: initialValue}`. In the existing `EditingDidEnd` handler (after commit) and wherever `activeEditableField` is cleared, set the id to nil and call the host with nil.
- [ ] **Step 2: Implement `commitRemoteText:forFieldID:submitForm:`** — return NO if `fieldID` ≠ `activeEditableFieldID` or no field; else set `activeEditableField.text = text`, `[activeEditableField resignFirstResponder]` (existing handler commits with `submitForm:NO`); if `submitForm`, then `commitEditableText:atPoint:webView:submitForm:YES` with the same point/webView (store them alongside the field). Return YES.
- [ ] **Step 3: Wire `ViewController`** — host callback → `[self.remoteServer.state updateField:]` + `stateDidChange`; delegate `remoteServer:submitFieldText:fieldID:submitForm:` → `[self.pageActionCoordinator commitRemoteText:forFieldID:submitForm:]`.
- [ ] **Step 4: Verify on device** (paste output):
  1. On the TV click google.com's search box (TV keyboard opens). `curl -s "$H/api/state?v=0"` → `field` has an `id` and `type`.
  2. `curl -s -d "{\"id\":\"<id>\",\"text\":\"nebula browser\",\"submit\":true}" $H/api/field` → `{"ok":true}`; TV keyboard closes, box filled, search submitted; state `field` back to `null`.
  3. **Review Focus 4:** click a field, press Menu on the TV to dismiss the keyboard, then POST with the old id → `409 {"error":"field-not-active"}`, nothing typed anywhere.
- [ ] **Step 5: Commit** — `git commit -m "Nebula Remote: fill the active text field"`

### Task 6: Phone/Mac page

**Files:**
- Create: `_Project/Browser/BrowserRemotePage.h`, `_Project/Browser/BrowserRemotePage.m`
- Modify: `_Project/Browser.xcodeproj/project.pbxproj`, `_Project/Browser/ViewController.m` (`remoteServerPageHTML:` returns `[BrowserRemotePage HTML]`)

**Interfaces:**
- Produces: `@interface BrowserRemotePage : NSObject` `+ (NSString *)HTML;`

- [ ] **Step 1: Write the page** (single HTML string, inline CSS/JS, no external requests), per spec §7: text box + **Abrir** / **Abrir en tab nueva** (`POST /api/open`); field card "Nebula pide: <title>" with `<input type>` from `field.type` (`password`, `email`, `number`, `url`, `search`, `tel`, else `text`), prefilled `value`, **Enviar** + checkbox **Enviar formulario** (`POST /api/field`; on `409` show "El campo ya no está activo en la TV"); status line with the TV page title, "Sin conexión" on poll failure with backoff 1→5 s; long-poll loop `GET /api/state?v=<last>`; on load, if `location.search` has `open`, POST it with `newTab = (tab === 'new')`, show "Enviado" and `history.replaceState` to `/`. Dark theme, ≥44 px tap targets, `apple-mobile-web-app-capable` + viewport meta.
- [ ] **Step 2: Add to pbxproj, build, install, launch.**
- [ ] **Step 3: Verify manually** — iPhone Safari: open URL, new tab, field flow (click a field on the TV, the card appears without reloading), "Agregar a inicio". Mac Safari/Chrome: same, plus bookmarklet `javascript:window.open('http://Alans-Apple-TV-4K.local:8080/?tab=new&open='+encodeURIComponent(location.href))` from an `https://` page → opens that page in a new TV tab. Kill Nebula → page shows "Sin conexión", relaunch → recovers.
- [ ] **Step 4: Commit** — `git commit -m "Nebula Remote: phone and Mac page"`

### Task 7: Settings toggle, URL display and docs

**Files:**
- Modify: `_Project/Browser/BrowserPreferencesStore.h/.m` (`@property (nonatomic) BOOL remoteServerEnabled;` default YES, key `RemoteServerEnabled`)
- Modify: `_Project/Browser/BrowserMenuCoordinator.m` (new `remoteServerToggleMenuItem` next to `arrowShortcutsToggleMenuItem` in the settings list)
- Modify: `_Project/Browser/ViewController.m` (respect the preference on start; react to toggle immediately)
- Modify: `README.mdown` (usage section: URL, iOS/macOS Shortcut steps, bookmarklet)

**Interfaces:**
- Consumes: `server.port` (Task 3).
- Produces: host method `- (nullable NSString *)browserRemoteServerURLString;` on the menu coordinator host (nil when stopped) used in the item's explanation.

- [ ] **Step 1: Preference + toggle** following `arrowShortcutsToggleMenuItem`: titles `Nebula Remote: On` / `Nebula Remote: Off`; explanation `Type on this TV from your iPhone or Mac.\n\nOpen <URL> in any browser on your network.` (or `Turn on to type from your iPhone or Mac.` when off). Toggling starts/stops the server right away.
- [ ] **Step 2: Hostname** — build the URL from `NSProcessInfo.processInfo.hostName`; verify on device it yields `Alans-Apple-TV-4K.local` (append `.local` if missing). If it returns something unusable, fall back to the device's IPv4 from `getifaddrs` on `en0`.
- [ ] **Step 3: README** — add "Nebula Remote" section: the URL, Shortcut recipe (Receive URLs from Share Sheet → Get Contents of URL, POST, JSON `text` = Shortcut Input, `newTab` = true → `http://<your-apple-tv>.local:8080/api/open`), the bookmarklet, and that it only works while Nebula is open.
- [ ] **Step 4: Verify on device** — Settings shows the URL with the real port; toggle Off → `curl` to `$H/` fails to connect; toggle On → 200 again. Run `_Project/Tests/run-remote-tests.sh` once more → all PASS.
- [ ] **Step 5: Commit** — `git commit -m "Nebula Remote: settings toggle, URL and docs"`
