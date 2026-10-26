# Nebula Remote Admin Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Nebula Remote page into a web admin panel (Write · Tabs · Favorites · Home) served from bundle files and synchronized through the existing long-poll state.

**Architecture:** A Foundation-only `BrowserFavoritesStore` becomes the single favorites API for the TV menu and the panel. `BrowserRemoteState` grows `tabs/favorites/home/theme`; `ViewController` republishes them when tabs change or `NSUserDefaults` changes. `BrowserRemoteServer` serves a whitelisted `RemotePanel/` folder reference and dispatches validated actions to one generic delegate method.

**Tech Stack:** Objective-C (ARC), tvOS 15.6+, Network.framework, Foundation; vanilla HTML/CSS/JS (no dependencies); macOS test runner `_Project/Tests/run-remote-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-10-25-remote-admin-panel-design.md` (builds on `docs/superpowers/specs/2026-10-25-remote-input-design.md`)

## Global Constraints

- No third-party dependencies; `TVOS_DEPLOYMENT_TARGET = 15.6`.
- v1 guards stay: trusted `Host`, POST only `application/json`, body ≤ 64 KB, 8 connections, 25 s long-poll; nothing on server paths uses `stringByEvaluatingJavaScriptFromString`.
- Delegate calls and `BrowserRemoteState` only on the main queue.
- Favorites persist in `NSUserDefaults["FAVORITES"]` as an array of `[url, title]` string pairs (unchanged format).
- `launch` values: `"last-session"` ↔ `launchPageMode` 0, `"home-page"` ↔ 1.
- Web URLs accepted for favorites/home: scheme `http` or `https` with a non-empty host, after trimming whitespace.
- Error bodies `{"error":"<code>"}` with codes exactly: `tab-not-found` (404), `max-tabs` (409), `favorite-changed` (409), `invalid-url` (400), `invalid-index` (400), `invalid-launch` (400), `no-current-page` (400), `invalid-request` (400). Success `{"ok":true}`.
- Panel shows titles/URLs only via `textContent`; no `confirm()`/`alert()`.
- Static routes only: `/` → `RemotePanel/index.html`, `/app.css`, `/app.js`, `/apple-touch-icon.png`; anything else `404`.
- Tests that touch defaults use `[[NSUserDefaults alloc] initWithSuiteName:@"nebula.tests.<test>"]` and remove the suite afterwards; never the standard defaults.
- Device-free verification target: tvOS Simulator `EC7DFAE5-EB56-4ABA-A60E-8E30B6272E9C` at `http://localhost:8080`:
  ```bash
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; SIM=EC7DFAE5-EB56-4ABA-A60E-8E30B6272E9C; ID=app.orbitlabs.tvbrowser
  APP="$HOME/Library/Developer/Xcode/DerivedData/Browser-cuoiltoxxnqimthedeqcgquqiram/Build/Products/Debug-appletvsimulator/Browser.app"
  cd _Project && xcodebuild -project Browser.xcodeproj -scheme Browser -destination "id=$SIM" -configuration Debug build | grep -E "error:|BUILD"
  xcrun simctl install $SIM "$APP"; xcrun simctl terminate $SIM $ID 2>/dev/null; xcrun simctl launch $SIM $ID
  ```
  POSTs need `-H 'Content-Type: application/json'`.
- Commits: no Claude attribution; no push.

## Review Focus

1. **Favorite edited on the TV while the panel shows a stale list** (index shifted) → action must answer `409 favorite-changed`, never edit/remove the wrong entry. → Task 1 `testRemoveWithStaleURLIsRejected`, Task 4 Step 4 curl.
2. **Corrupted `FAVORITES` defaults** (non-array entries, numbers, 1-element arrays from old builds) → must not crash or shift indices of valid entries. → Task 1 `testSkipsCorruptEntries`.
3. **Closing the active tab or the last tab from the panel** → TV shows the next tab / a fresh home tab and the panel list updates. → Task 3 Step 4 curl.
4. **Opening a tab/favorite when at `maximumTabCount`** → `409 max-tabs`, no alert on the TV. → Task 3 Step 4 and Task 4 Step 4.
5. **Title/URL containing HTML (`<img onerror=…>`)** → rendered as text in every panel list. → Task 2 Step 6 (favorite seeded with an HTML title, checked in Chrome: shown literally, no `xss` console message).

---

### Task 1: BrowserFavoritesStore (TDD) and TV menu migration

**Files:**
- Create: `_Project/Browser/BrowserFavoritesStore.h`, `_Project/Browser/BrowserFavoritesStore.m`
- Modify: `_Project/Browser/BrowserMenuCoordinator.m` (`saveFavoritesArray:`, `presentDeleteFavoriteMenu`, `presentAddFavoritePrompt`, `presentFavoritesMenu`)
- Modify: `_Project/Tests/BrowserRemoteTests.m`, `_Project/Tests/run-remote-tests.sh` (compile the store)
- Modify: `_Project/Browser.xcodeproj/project.pbxproj` (add the `.m`, same helper as v1: entries next to `BrowserSessionStore`)

**Interfaces:**
- Produces:
  ```objc
  extern NSNotificationName const BrowserFavoritesStoreDidChangeNotification;
  typedef NS_ENUM(NSInteger, BrowserFavoritesEditResult) {
      BrowserFavoritesEditResultOK, BrowserFavoritesEditResultChanged, BrowserFavoritesEditResultInvalidIndex };
  @interface BrowserFavoritesStore : NSObject
  + (instancetype)standardStore;                         // standard defaults
  - (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
  // Valid entries only, in stored order; each @{@"url":…, @"title":…}.
  - (NSArray<NSDictionary<NSString *, NSString *> *> *)favorites;
  - (void)addURLString:(NSString *)URLString title:(nullable NSString *)title;   // blank title → URL
  - (BrowserFavoritesEditResult)updateAtIndex:(NSUInteger)index expectedURLString:(NSString *)expected
                                        title:(NSString *)title URLString:(NSString *)URLString;
  - (BrowserFavoritesEditResult)removeAtIndex:(NSUInteger)index expectedURLString:(NSString *)expected;
  - (BrowserFavoritesEditResult)moveFromIndex:(NSUInteger)index expectedURLString:(NSString *)expected toIndex:(NSUInteger)toIndex;
  @end
  ```
  Index out of range → `InvalidIndex` (for `move`, also `toIndex ≥ count`); URL at index ≠ expected → `Changed`. Every successful mutation writes the valid list back and posts the notification.

- [ ] **Step 1: Failing tests** in `BrowserRemoteTests.m` (each with its own suite, removed at the end):
  - `testReadsStoredPairs` — stored `@[@[@"https://a.com", @"A"], @[@"https://b.com", @"B"]]` → `favorites` = `@[@{url:a,title:A}, @{url:b,title:B}]`.
  - `testSkipsCorruptEntries` — stored `@[@3, @[@"https://a.com"], @[@"https://b.com", @"B"], @"x", @[@4, @"N"]]`. Non-arrays and pairs whose URL isn't a string are skipped; a 1-element `[url]` (older builds) is kept with title = URL. Assert count 2, `[0]` = `{url:"https://a.com", title:"https://a.com"}`, `[1]` = `{url:"https://b.com", title:"B"}`.
  - `testAddUsesURLWhenTitleBlank` — `addURLString:@"https://c.com" title:@"  "` → last favorite title `https://c.com`; stored defaults array last element `@[@"https://c.com", @"https://c.com"]`.
  - `testRemoveWithStaleURLIsRejected` — 2 favorites; `removeAtIndex:0 expectedURLString:@"https://b.com"` → `Changed`, count still 2; `removeAtIndex:5 …` → `InvalidIndex`; `removeAtIndex:0 expectedURLString:@"https://a.com"` → `OK`, count 1.
  - `testMoveAndUpdate` — `[a,b,c]`; `moveFromIndex:0 expectedURLString:a toIndex:2` → `[b,c,a]`; `toIndex:3` → `InvalidIndex`; `updateAtIndex:0 expectedURLString:b title:@"Bee" URLString:@"https://bee.com"` → `[0]` = `{url:bee,title:Bee}`.
  - `testMutationPostsNotification` — observer on `BrowserFavoritesStoreDidChangeNotification` with `object:` the store counts 1 after `add`.
- [ ] **Step 2: Run** `_Project/Tests/run-remote-tests.sh` — Expected: compile error (missing `BrowserFavoritesStore.h`).
- [ ] **Step 3: Implement** `BrowserFavoritesStore.m` per the interface (add the `.m` to `run-remote-tests.sh`).
- [ ] **Step 4: Run** the suite — Expected: `20/20 passed`.
- [ ] **Step 5: Migrate `BrowserMenuCoordinator`** — all four methods use `[BrowserFavoritesStore standardStore]`; delete uses `removeAtIndex:expectedURLString:` with the URL shown; no remaining `@"FAVORITES"` literal in the file (`grep -c '"FAVORITES"' BrowserMenuCoordinator.m` → 0). Add the `.m` to the pbxproj; build for the simulator → `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit** — `git commit -m "Favorites store shared by the TV menu (TDD)"`

### Task 2: Panel as bundle files + full read-only state  ← first visible checkpoint

**Files:**
- Create: `_Project/Browser/RemotePanel/index.html`, `app.css`, `app.js`
- Delete: `_Project/Browser/BrowserRemotePage.h/.m` (and their 6 pbxproj lines)
- Modify: `_Project/Browser.xcodeproj/project.pbxproj` (folder reference `RemotePanel`: PBXFileReference `lastKnownFileType = folder; path = RemotePanel;` in the Browser group + PBXBuildFile in the `Resources` phase)
- Modify: `BrowserRemoteState.h/.m`, `BrowserRemoteServer.h/.m`, `ViewController.m`, `BrowserTabCoordinator.m`
- Test: `_Project/Tests/BrowserRemoteTests.m`

**Interfaces:**
- Consumes: `BrowserFavoritesStore` (Task 1).
- Produces:
  - `BrowserRemoteState`: `- (void)updateTabs:(NSArray<NSDictionary *> *)tabs;` (`id,title,url` strings + `active` NSNumber BOOL), `- (void)updateFavorites:(NSArray<NSDictionary *> *)favorites;`, `- (void)updateHome:(NSDictionary *)home;` (`url`, `launch`), `- (void)updateTheme:(NSDictionary *)theme;` (`accent`, `onAccent`). Each bumps `version` only when the value differs (`isEqual:`). `JSONObject` adds keys `tabs`, `favorites`, `home`, `theme`, defaulting to `@[]`, `@[]`, `@{url:"",launch:"last-session"}`, `@{accent:"#7B6CDE",onAccent:"#FFFFFF"}`.
  - `BrowserRemoteServerDelegate`: remove `remoteServerPageHTML:`. Static files are served by the server from `[NSBundle.mainBundle URLForResource:… withExtension:… subdirectory:@"RemotePanel"]` with types `text/html; charset=utf-8`, `text/css; charset=utf-8`, `application/javascript; charset=utf-8`.
  - `ViewController`: `- (void)publishRemoteState;` — rebuilds tabs (from `self.viewModel.tabs`, active = `activeTabIndex`), favorites (`standardStore`), home (`homePageURLString`, `launchPageMode`), theme (accent hex/onAccent as v1), page; calls `stateDidChange` once if the version moved. Called from `browserTabCoordinatorActiveTabDidRefresh`, `browserDidChangeTheme`, and an observer of `NSUserDefaultsDidChangeNotification` (dispatched to main).
  - `BrowserTabCoordinator switchToTabAtIndex:` calls `[self refreshActiveTabUI]` before `persistSession`.

- [ ] **Step 1: Failing test** `testStateIncludesAdminSections` — new state: `JSONObject[@"tabs"]` = `@[]`, `[@"home"][@"launch"]` = `@"last-session"`, `[@"theme"][@"accent"]` = `@"#7B6CDE"`; `updateTabs:@[@{@"id":@"t1",@"title":@"A",@"url":@"https://a.com",@"active":@YES}]` bumps v from 1 to 2, same array again stays 2; `updateFavorites:`/`updateHome:`/`updateTheme:` each bump once.
- [ ] **Step 2: Run** suite → Expected: compile error (`updateTabs:` unknown).
- [ ] **Step 3: Implement** the state additions → suite `21/21 passed`.
- [ ] **Step 4: Server + ViewController + tab switch refresh + folder reference**; delete `BrowserRemotePage`. Panel UI per spec §6 in read-only form: four sections (Escribir fully working as v1 incl. field card and `?open=`; Tabs, Favoritos, Inicio rendered from state with their buttons present but disabled until Tasks 3–5), branding/logo from v1, accent from `state.theme` applied as CSS variables, desktop two-column layout at ≥ 900 px, iPhone bottom section bar.
- [ ] **Step 5: Verify bundle + routes** (simulator):
  ```bash
  ls "$APP/RemotePanel/"                                   # index.html app.css app.js
  curl -s -o /dev/null -w '%{http_code} %{content_type}\n' localhost:8080/          # 200 text/html
  curl -s -o /dev/null -w '%{http_code} %{content_type}\n' localhost:8080/app.js    # 200 application/javascript
  curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/../Info.plist             # 404
  curl -s "localhost:8080/api/state?v=0" | python3 -m json.tool | head -40          # tabs/favorites/home/theme present
  node --check <downloaded app.js>                                                   # syntax OK
  ```
- [ ] **Step 6: Seed and look** — seed simulator favorites (including one titled `<img src=x onerror=console.log('xss')>`; never `alert`, it blocks browser automation) with `xcrun simctl spawn $SIM defaults write $ID FAVORITES '(("https://www.youtube.com","YouTube"),("https://example.com","<img src=x onerror=console.log(\"xss\")>"))'`, open 2 extra tabs via `/api/open` `newTab`, relaunch; open `http://localhost:8080` in Chrome (desktop and a 390 px wide window): 4 sections render, tabs list matches, HTML title shown literally, no `xss` and no errors in the console. **Tell Alan it's viewable.**
- [ ] **Step 7: Commit** — `git commit -m "Admin panel as bundle files with full read-only state"`

### Task 3: Tab actions

**Files:** `BrowserRemoteHTTP.h/.m`, `BrowserRemoteServer.m`, `ViewController.m`, `BrowserTabCoordinator.h/.m`, `RemotePanel/app.js`, Tests.

**Interfaces:**
- Produces (pure, `BrowserRemoteHTTP`): `NSDictionary * _Nullable BrowserRemoteActionPayload(NSString *action, id _Nullable JSON, NSString * _Nullable * _Nullable outErrorCode);` — `action` is the path after `/api/` (`tabs/switch`, `tabs/close`, `tabs/new`, `favorites/add|update|remove|move|open`, `home`). Returns a normalized payload or nil with `outErrorCode` (`invalid-request`, `invalid-url`, `invalid-launch`, `invalid-index`). Also `BOOL BrowserRemoteIsWebURLString(NSString *string);`.
- Produces (delegate): `- (NSInteger)remoteServer:(BrowserRemoteServer *)server performAction:(NSString *)action payload:(NSDictionary *)payload response:(NSDictionary * _Nullable * _Nonnull)outResponse;` — returns the HTTP status; `outResponse` the JSON body. The server routes every action path above through it (POST only, after the v1 guards and `BrowserRemoteActionPayload`).
- Produces (`BrowserTabCoordinator`): `- (NSInteger)indexOfTabWithIdentifier:(NSString *)identifier;` (`NSNotFound` if absent).

- [ ] **Step 1: Failing tests** `testTabPayloads` — `tabs/switch` `{}` → nil + `invalid-request`; `{id:"t1"}` → `{id:"t1"}`; `tabs/new` `{}` → `@{}`; unknown action `tabs/explode` → nil + `invalid-request`. `testWebURLValidation` — `https://a.com` YES, ` http://a.com/x ` YES, `ftp://a.com` NO, `javascript:alert(1)` NO, `https://` NO, `` NO.
- [ ] **Step 2: Run** → compile error. **Step 3: Implement** the validators → suite passes.
- [ ] **Step 4: Implement actions** in `ViewController` (`switch`/`close` by id → `404 tab-not-found`; `new` → `409 max-tabs` when `self.viewModel.tabs.count >= BrowserViewModel.maximumTabCount`, else `createNewTabLoadingHomePage:YES`; switch/close first call `discardActiveEditableField`). Enable the Tabs section in `app.js` (row tap → switch, ✕ → close, **+ Nueva**). Verify (paste output):
  ```bash
  J='Content-Type: application/json'; S=$(curl -s "localhost:8080/api/state?v=0")
  # take a non-active tab id from $S, then:
  curl -s -w ' %{http_code}\n' -H "$J" -d '{"id":"<id>"}' localhost:8080/api/tabs/switch      # {"ok":true} 200; state active moves
  curl -s -w ' %{http_code}\n' -H "$J" -d '{"id":"nope"}' localhost:8080/api/tabs/close       # tab-not-found 404
  # close tabs until one remains, close it → state still has 1 (fresh home) tab
  # open new tabs until maximumTabCount, one more → max-tabs 409
  ```
  In Chrome: switch/close/new from the panel update the list without reload.
- [ ] **Step 5: Commit** — `git commit -m "Admin panel: tab switch, close and new"`

### Task 4: Favorite actions

**Files:** `ViewController.m`, `RemotePanel/app.js` (+ css), Tests.

**Interfaces:** Consumes `BrowserRemoteActionPayload`, `BrowserFavoritesStore`, the `performAction:` delegate.

- [ ] **Step 1: Failing tests** `testFavoritePayloads` — `favorites/add` `{url:" https://a.com "}` → url trimmed, title `""`; `{current:true}` → `{current:@YES}`; `{url:"ftp://a"}` → `invalid-url`; `favorites/update` without `index` → `invalid-request`; `{index:-1,url:"https://a.com",title:"A"}` → `invalid-index`; `favorites/move` `{index:0,url:"https://a.com",to:"x"}` → `invalid-request`; `favorites/open` `{index:0,url:"https://a.com"}` → `newTab` NO.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** → suite passes.
- [ ] **Step 4: Implement actions** mapping `BrowserFavoritesEditResult` → `200` / `409 favorite-changed` / `400 invalid-index`; `add` with `current` uses the active web view URL/title (`400 no-current-page` if none); `open` loads via `requestForURLString:` (current tab or new tab with `409 max-tabs`), discarding the active field first. Panel: Abrir, menú ⋯ (Editar en línea, Abrir en tab nueva, Subir, Bajar, Borrar con "¿Borrar? Sí / No"), drag & drop on desktop, **+ Página actual**, **+ Agregar URL**; `409` shows "Cambió en la TV, actualizado". Verify with curl: add → appears in state; remove with stale url → `409 favorite-changed`; move/update round-trip; open → TV loads it; and in the TV menu (simulator `defaults read $ID FAVORITES`) the stored pairs match.
- [ ] **Step 5: Commit** — `git commit -m "Admin panel: favorites add, edit, remove, reorder, open"`

### Task 5: Home settings and live theme

**Files:** `ViewController.m`, `RemotePanel/app.js`, Tests.

- [ ] **Step 1: Failing test** `testHomePayload` — `{launch:"home-page"}` → ok; `{launch:"sometimes"}` → `invalid-launch`; `{url:"notaurl"}` → `invalid-url`; `{useCurrent:true}` → `{useCurrent:@YES}`; `{}` → `invalid-request`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** → suite passes.
- [ ] **Step 4: Implement `home` action** (sets `homePageURLString` from `url` or the current page — `400 no-current-page` if none — and `launchPageMode` from `launch`); panel Inicio section (URL field, Usar página actual, Guardar, launch radios saving on change). Theme: with the panel open in Chrome, run `xcrun simctl spawn $SIM defaults write $ID ThemeIndex -int 2` (Ocean) — the `NSUserDefaultsDidChangeNotification` path republishes and the panel accent turns `#0A84FF` without reload (state.theme). Home keys: `homepage`, `LaunchPageMode`. Verify with curl + Chrome; `defaults read` shows the new home values.
- [ ] **Step 5: Commit** — `git commit -m "Admin panel: home page settings and live theme"`

### Task 6: Final review

- [ ] Whole-branch review by a fresh reviewer (most capable model) with the spec, this plan's Review Focus and the ledger rulings; one TDD fix pass for Critical/Important; minors deferred to the final message. Update README "Nebula Remote" section with the panel sections.
