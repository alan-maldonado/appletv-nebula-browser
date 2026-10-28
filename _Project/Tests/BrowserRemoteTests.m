// Tests for the pure-Foundation parts of Nebula Remote. Run with Tests/run-remote-tests.sh.
#import <Foundation/Foundation.h>

#import "BrowserFavoritesStore.h"
#import "BrowserRemoteHTTP.h"
#import "BrowserRemoteState.h"
#import "BrowserRemoteWebSocket.h"

static NSMutableArray<NSString *> *sFailures;

#define EXPECT(condition, ...) do { \
    if (!(condition)) { [sFailures addObject:[NSString stringWithFormat:__VA_ARGS__]]; return; } \
} while (0)

static NSData *Bytes(NSString *string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

static void testParsesSimpleGET(void) {
    BrowserRemoteRequest *request = nil;
    BrowserRemoteParseStatus status = BrowserRemoteParseRequest(Bytes(@"GET /api/state?v=3 HTTP/1.1\r\nHost: x\r\n\r\n"), &request);
    EXPECT(status == BrowserRemoteParseStatusComplete, @"status %ld", (long)status);
    EXPECT([request.method isEqualToString:@"GET"], @"method %@", request.method);
    EXPECT([request.path isEqualToString:@"/api/state"], @"path %@", request.path);
    EXPECT([request.query[@"v"] isEqualToString:@"3"], @"query %@", request.query);
}

static void testParsesRequestSplitAcrossChunks(void) {
    NSString *body = @"{\"text\":\"hola\",\"newTab\":1}";
    NSString *head = @"POST /api/open HTTP/1.1\r\nContent-Length: 26\r\n\r\n";
    BrowserRemoteRequest *request = nil;
    NSString *partial = [head stringByAppendingString:[body substringToIndex:10]];
    EXPECT(BrowserRemoteParseRequest(Bytes(partial), &request) == BrowserRemoteParseStatusIncomplete, @"partial not incomplete");
    BrowserRemoteParseStatus status = BrowserRemoteParseRequest(Bytes([head stringByAppendingString:body]), &request);
    EXPECT(status == BrowserRemoteParseStatusComplete, @"full status %ld", (long)status);
    EXPECT([[request JSONBody][@"text"] isEqualToString:@"hola"], @"body %@", [request JSONBody]);
}

static void testDecodesUTF8BodyAndPercentEncodedQuery(void) {
    NSData *body = Bytes(@"{\"text\":\"mañana 🎬\"}");
    NSMutableData *raw = [Bytes([NSString stringWithFormat:@"POST /api/open HTTP/1.1\r\nContent-Length: %lu\r\n\r\n", (unsigned long)body.length]) mutableCopy];
    [raw appendData:body];
    BrowserRemoteRequest *request = nil;
    EXPECT(BrowserRemoteParseRequest(raw, &request) == BrowserRemoteParseStatusComplete, @"body request not complete");
    EXPECT([[request JSONBody][@"text"] isEqualToString:@"mañana 🎬"], @"body text %@", [request JSONBody]);

    BrowserRemoteRequest *getRequest = nil;
    BrowserRemoteParseRequest(Bytes(@"GET /?open=ma%C3%B1ana%20%F0%9F%8E%AC&tab=new HTTP/1.1\r\n\r\n"), &getRequest);
    EXPECT([getRequest.query[@"open"] isEqualToString:@"mañana 🎬"], @"query open %@", getRequest.query);
    EXPECT([getRequest.query[@"tab"] isEqualToString:@"new"], @"query tab %@", getRequest.query);
}

static void testHeaderKeysAreLowercased(void) {
    BrowserRemoteRequest *request = nil;
    BrowserRemoteParseRequest(Bytes(@"GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n"), &request);
    EXPECT([request.headers[@"content-type"] isEqualToString:@"application/json"], @"headers %@", request.headers);
}

static void testRejectsMalformedRequestLine(void) {
    BrowserRemoteRequest *request = nil;
    EXPECT(BrowserRemoteParseRequest(Bytes(@"HELLO\r\n\r\n"), &request) == BrowserRemoteParseStatusInvalid, @"not invalid");
}

static void testRejectsOversizedBody(void) {
    BrowserRemoteRequest *request = nil;
    BrowserRemoteParseStatus status = BrowserRemoteParseRequest(Bytes(@"POST /api/open HTTP/1.1\r\nContent-Length: 65537\r\n\r\n"), &request);
    EXPECT(status == BrowserRemoteParseStatusTooLarge, @"status %ld", (long)status);
}

static void testRejectsOversizedHeaders(void) {
    NSMutableData *raw = [Bytes(@"GET / HTTP/1.1\r\nX: ") mutableCopy];
    raw.length = 16385;
    memset((char *)raw.mutableBytes + 19, 'a', 16385 - 19);
    BrowserRemoteRequest *request = nil;
    BrowserRemoteParseStatus status = BrowserRemoteParseRequest(raw, &request);
    EXPECT(status == BrowserRemoteParseStatusTooLarge, @"status %ld", (long)status);
}

static void testInvalidJSONBodyReturnsNil(void) {
    BrowserRemoteRequest *request = nil;
    BrowserRemoteParseRequest(Bytes(@"POST /api/open HTTP/1.1\r\nContent-Length: 5\r\n\r\n{nope"), &request);
    EXPECT(request != nil && [request JSONBody] == nil, @"JSON %@", [request JSONBody]);
}

static void testResponseHasLengthAndClose(void) {
    NSData *data = BrowserRemoteResponseData(404, @"text/plain", Bytes(@"no"));
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    EXPECT([text hasPrefix:@"HTTP/1.1 404 Not Found\r\n"], @"status line %@", text);
    EXPECT([text containsString:@"Content-Length: 2\r\n"], @"length %@", text);
    EXPECT([text containsString:@"Connection: close\r\n"], @"close %@", text);
}

static void testOpenPayloadRejectsBlankText(void) {
    BOOL newTab = YES;
    EXPECT(BrowserRemoteOpenPayloadFromJSON(@{@"text": @"   "}, &newTab) == nil, @"blank accepted");
    NSString *text = BrowserRemoteOpenPayloadFromJSON(@{@"text": @" apple.com ", @"newTab": @YES}, &newTab);
    EXPECT([text isEqualToString:@"apple.com"] && newTab, @"text %@ newTab %d", text, newTab);
    EXPECT(BrowserRemoteOpenPayloadFromJSON(@{@"text": @3}, &newTab) == nil, @"number accepted");
}

static void testFieldPayloadRequiresIDAndText(void) {
    EXPECT(BrowserRemoteFieldPayloadFromJSON(@{@"text": @"x"}) == nil, @"missing id accepted");
    NSDictionary *payload = BrowserRemoteFieldPayloadFromJSON(@{@"id": @"a", @"text": @""});
    EXPECT([payload[@"text"] isEqualToString:@""] && ![payload[@"submit"] boolValue], @"payload %@", payload);
}

static void testStateVersionBumpsOnlyOnChange(void) {
    BrowserRemoteState *state = [BrowserRemoteState new];
    EXPECT(state.version == 1, @"initial %lu", (unsigned long)state.version);
    [state updatePageTitle:@"Apple" URLString:@"https://apple.com"];
    [state updatePageTitle:@"Apple" URLString:@"https://apple.com"];
    EXPECT(state.version == 2, @"after page %lu", (unsigned long)state.version);
    [state updateField:@{@"id": @"f1", @"title": @"Email", @"type": @"email", @"placeholder": @"", @"value": @""}];
    EXPECT(state.version == 3, @"after field %lu", (unsigned long)state.version);
    EXPECT([[state JSONObject][@"field"][@"id"] isEqualToString:@"f1"], @"field %@", [state JSONObject]);
    [state updateField:nil];
    EXPECT(state.version == 4, @"after clear %lu", (unsigned long)state.version);
    EXPECT([state JSONObject][@"field"] == NSNull.null, @"field not null %@", [state JSONObject]);
}

static BrowserRemoteRequest *ParsedRequest(NSString *raw) {
    BrowserRemoteRequest *request = nil;
    BrowserRemoteParseRequest(Bytes(raw), &request);
    return request;
}

static void testTrustsLocalHostsOnly(void) {
    EXPECT(BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: Alans-Apple-TV-4K.local:8080\r\n\r\n")), @".local rejected");
    EXPECT(BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: 192.168.1.20:8080\r\n\r\n")), @"IPv4 rejected");
    EXPECT(BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: [fe80::1]:8080\r\n\r\n")), @"IPv6 rejected");
    EXPECT(BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: localhost:8080\r\n\r\n")), @"localhost rejected");
    EXPECT(BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: appletv.lan\r\n\r\n")), @".lan proxy host rejected");
    EXPECT(BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: appletv.lan.orbitware.app\r\n\r\n")), @"orbitware.app proxy host rejected");
    EXPECT(!BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: orbitware.app.evil.com\r\n\r\n")), @"orbitware.app lookalike accepted");
    EXPECT(!BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\nHost: evil.example.com:8080\r\n\r\n")), @"rebinding host accepted");
    EXPECT(!BrowserRemoteRequestHasTrustedHost(ParsedRequest(@"GET / HTTP/1.1\r\n\r\n")), @"missing host accepted");
}

static void testPostRequiresJSONContentType(void) {
    NSString *body = @"{\"text\":\"x\"}";
    BrowserRemoteRequest *json = ParsedRequest([NSString stringWithFormat:@"POST /api/open HTTP/1.1\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body]);
    BrowserRemoteRequest *plain = ParsedRequest([NSString stringWithFormat:@"POST /api/open HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body]);
    EXPECT(BrowserRemoteRequestHasJSONContentType(json), @"application/json rejected");
    EXPECT(!BrowserRemoteRequestHasJSONContentType(plain), @"text/plain accepted (no-cors CSRF)");
}

// A favorites store over a throwaway defaults suite, optionally pre-seeded.
static BrowserFavoritesStore *FavoritesStore(NSString *suite, NSArray *stored) {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    if (stored != nil) {
        [defaults setObject:stored forKey:@"FAVORITES"];
    }
    return [[BrowserFavoritesStore alloc] initWithDefaults:defaults];
}

static void RemoveSuite(NSString *suite) {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
}

static NSDictionary *Fav(NSString *url, NSString *title) {
    return @{@"url": url, @"title": title};
}

static void testReadsStoredPairs(void) {
    NSString *suite = @"nebula.tests.readsStoredPairs";
    BrowserFavoritesStore *store = FavoritesStore(suite, @[@[@"https://a.com", @"A"], @[@"https://b.com", @"B"]]);
    NSArray *expected = @[Fav(@"https://a.com", @"A"), Fav(@"https://b.com", @"B")];
    BOOL ok = [store.favorites isEqualToArray:expected];
    RemoveSuite(suite);
    EXPECT(ok, @"favorites %@", store.favorites);
}

static void testSkipsCorruptEntries(void) {
    NSString *suite = @"nebula.tests.skipsCorrupt";
    BrowserFavoritesStore *store = FavoritesStore(suite, @[@3, @[@"https://a.com"], @[@"https://b.com", @"B"], @"x", @[@4, @"N"]]);
    NSArray *favorites = store.favorites;
    RemoveSuite(suite);
    EXPECT(favorites.count == 2, @"count %lu %@", (unsigned long)favorites.count, favorites);
    EXPECT([favorites[0] isEqualToDictionary:Fav(@"https://a.com", @"https://a.com")], @"[0] %@", favorites[0]);
    EXPECT([favorites[1] isEqualToDictionary:Fav(@"https://b.com", @"B")], @"[1] %@", favorites[1]);
}

static void testAddUsesURLWhenTitleBlank(void) {
    NSString *suite = @"nebula.tests.addBlankTitle";
    BrowserFavoritesStore *store = FavoritesStore(suite, nil);
    [store addURLString:@"https://c.com" title:@"  "];
    NSArray *stored = [[[NSUserDefaults alloc] initWithSuiteName:suite] arrayForKey:@"FAVORITES"];
    NSDictionary *last = store.favorites.lastObject;
    RemoveSuite(suite);
    EXPECT([last[@"title"] isEqualToString:@"https://c.com"], @"title %@", last);
    EXPECT(([stored.lastObject isEqual:@[@"https://c.com", @"https://c.com"]]), @"stored %@", stored);
}

static void testRemoveWithStaleURLIsRejected(void) {
    NSString *suite = @"nebula.tests.removeStale";
    BrowserFavoritesStore *store = FavoritesStore(suite, @[@[@"https://a.com", @"A"], @[@"https://b.com", @"B"]]);
    BrowserFavoritesEditResult stale = [store removeAtIndex:0 expectedURLString:@"https://b.com"];
    NSUInteger countAfterStale = store.favorites.count;
    BrowserFavoritesEditResult outOfRange = [store removeAtIndex:5 expectedURLString:@"https://a.com"];
    BrowserFavoritesEditResult ok = [store removeAtIndex:0 expectedURLString:@"https://a.com"];
    NSUInteger countAfterOK = store.favorites.count;
    RemoveSuite(suite);
    EXPECT(stale == BrowserFavoritesEditResultChanged && countAfterStale == 2, @"stale %ld count %lu", (long)stale, (unsigned long)countAfterStale);
    EXPECT(outOfRange == BrowserFavoritesEditResultInvalidIndex, @"outOfRange %ld", (long)outOfRange);
    EXPECT(ok == BrowserFavoritesEditResultOK && countAfterOK == 1, @"ok %ld count %lu", (long)ok, (unsigned long)countAfterOK);
}

static void testMoveAndUpdate(void) {
    NSString *suite = @"nebula.tests.moveUpdate";
    BrowserFavoritesStore *store = FavoritesStore(suite, @[@[@"https://a.com", @"A"], @[@"https://b.com", @"B"], @[@"https://c.com", @"C"]]);
    BrowserFavoritesEditResult move = [store moveFromIndex:0 expectedURLString:@"https://a.com" toIndex:2];
    NSArray *order = [store.favorites valueForKey:@"url"];
    BrowserFavoritesEditResult badMove = [store moveFromIndex:0 expectedURLString:@"https://b.com" toIndex:3];
    BrowserFavoritesEditResult update = [store updateAtIndex:0 expectedURLString:@"https://b.com" title:@"Bee" URLString:@"https://bee.com"];
    NSDictionary *first = store.favorites.firstObject;
    RemoveSuite(suite);
    EXPECT((move == BrowserFavoritesEditResultOK && [order isEqualToArray:@[@"https://b.com", @"https://c.com", @"https://a.com"]]), @"move %ld order %@", (long)move, order);
    EXPECT(badMove == BrowserFavoritesEditResultInvalidIndex, @"badMove %ld", (long)badMove);
    EXPECT(update == BrowserFavoritesEditResultOK && [first isEqualToDictionary:Fav(@"https://bee.com", @"Bee")], @"update %ld first %@", (long)update, first);
}

static void testMutationPostsNotification(void) {
    NSString *suite = @"nebula.tests.notification";
    BrowserFavoritesStore *store = FavoritesStore(suite, nil);
    __block NSUInteger posts = 0;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:BrowserFavoritesStoreDidChangeNotification
                                                                    object:store
                                                                     queue:nil
                                                                usingBlock:^(__unused NSNotification *note) { posts++; }];
    [store addURLString:@"https://a.com" title:@"A"];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    RemoveSuite(suite);
    EXPECT(posts == 1, @"posts %lu", (unsigned long)posts);
}

static void testStateIncludesAdminSections(void) {
    BrowserRemoteState *state = [BrowserRemoteState new];
    NSDictionary *json = [state JSONObject];
    EXPECT([json[@"tabs"] isEqual:@[]] && [json[@"favorites"] isEqual:@[]], @"defaults %@", json);
    EXPECT([json[@"home"][@"launch"] isEqualToString:@"last-session"], @"home %@", json[@"home"]);
    EXPECT([json[@"theme"][@"accent"] isEqualToString:@"#7B6CDE"], @"theme %@", json[@"theme"]);

    NSArray *tabs = @[@{@"id": @"t1", @"title": @"A", @"url": @"https://a.com", @"active": @YES}];
    [state updateTabs:tabs];
    EXPECT(state.version == 2, @"after tabs %lu", (unsigned long)state.version);
    [state updateTabs:[tabs copy]];
    EXPECT(state.version == 2, @"same tabs bumped %lu", (unsigned long)state.version);
    [state updateFavorites:@[@{@"url": @"https://a.com", @"title": @"A"}]];
    [state updateHome:@{@"url": @"https://a.com", @"launch": @"home-page"}];
    [state updateTheme:@{@"accent": @"#0A84FF", @"onAccent": @"#FFFFFF"}];
    EXPECT(state.version == 5, @"after favorites/home/theme %lu", (unsigned long)state.version);
    EXPECT([[state JSONObject][@"tabs"][0][@"id"] isEqualToString:@"t1"], @"json tabs %@", [state JSONObject]);
}

static void testMediaOnlyBumpsOnPlayheadJumps(void) {
    BrowserRemoteState *state = [BrowserRemoteState new];
    EXPECT([state JSONObject][@"media"] == NSNull.null, @"default media %@", [state JSONObject][@"media"]);
    NSDictionary *playing = @{@"source": @"native", @"title": @"Movie", @"time": @10.0, @"duration": @100.0, @"playing": @YES, @"rate": @1.0};
    [state updateMedia:playing now:1000.0];
    EXPECT(state.version == 2, @"first media %lu", (unsigned long)state.version);

    // Playhead where playback would have put it: no bump, and the snapshot advances on its own.
    [state updateMedia:@{@"source": @"native", @"title": @"Movie", @"time": @15.4, @"duration": @100.0, @"playing": @YES, @"rate": @1.0} now:1005.0];
    EXPECT(state.version == 2, @"steady playback bumped %lu", (unsigned long)state.version);
    EXPECT([[state JSONObjectAtTime:1007.0][@"media"][@"time"] doubleValue] == 17.0, @"extrapolated %@", [state JSONObjectAtTime:1007.0][@"media"]);
    EXPECT([[state JSONObjectAtTime:2000.0][@"media"][@"time"] doubleValue] == 100.0, @"clamped %@", [state JSONObjectAtTime:2000.0][@"media"]);

    // Seek (playhead jump) and pause both publish.
    [state updateMedia:@{@"source": @"native", @"title": @"Movie", @"time": @60.0, @"duration": @100.0, @"playing": @YES, @"rate": @1.0} now:1006.0];
    EXPECT(state.version == 3, @"seek not published %lu", (unsigned long)state.version);
    [state updateMedia:@{@"source": @"native", @"title": @"Movie", @"time": @60.2, @"duration": @100.0, @"playing": @NO, @"rate": @1.0} now:1006.2];
    EXPECT(state.version == 4, @"pause not published %lu", (unsigned long)state.version);
    [state updateMedia:@{@"source": @"native", @"title": @"Movie", @"time": @60.2, @"duration": @100.0, @"playing": @NO, @"rate": @1.0, @"fullscreen": @YES} now:1006.3];
    EXPECT(state.version == 5 && [[state JSONObject][@"media"][@"fullscreen"] boolValue], @"fullscreen not published %lu", (unsigned long)state.version);
    EXPECT([[state JSONObjectAtTime:1100.0][@"media"][@"time"] doubleValue] == 60.2, @"paused time moved %@", [state JSONObjectAtTime:1100.0][@"media"]);

    // Live stream: non-finite duration becomes null.
    [state updateMedia:@{@"source": @"page", @"title": @"Live", @"time": @5.0, @"duration": @(INFINITY), @"playing": @YES, @"rate": @1.0} now:1200.0];
    EXPECT([state JSONObject][@"media"][@"duration"] == NSNull.null, @"live duration %@", [state JSONObject][@"media"]);
    [state updateMedia:nil now:1201.0];
    EXPECT([state JSONObject][@"media"] == NSNull.null && state.version == 7, @"cleared %lu", (unsigned long)state.version);
}

static void testMediaPayloads(void) {
    NSString *error = nil;
    EXPECT([BrowserRemoteActionPayload(@"media", @{@"command": @"toggle"}, &error) isEqual:@{@"command": @"toggle"}], @"toggle %@", error);
    EXPECT([BrowserRemoteActionPayload(@"media", @{@"command": @"exit-fullscreen"}, &error) isEqual:@{@"command": @"exit-fullscreen"}], @"exit-fullscreen %@", error);
    EXPECT([BrowserRemoteActionPayload(@"media", @{@"command": @"seek", @"time": @42.5}, &error) isEqual:(@{@"command": @"seek", @"time": @42.5})], @"seek %@", error);
    EXPECT([BrowserRemoteActionPayload(@"media", @{@"command": @"skip", @"delta": @-10}, &error) isEqual:(@{@"command": @"skip", @"delta": @-10.0})], @"skip %@", error);
    EXPECT(BrowserRemoteActionPayload(@"media", @{@"command": @"seek", @"time": @-1}, &error) == nil, @"negative seek accepted");
    EXPECT(BrowserRemoteActionPayload(@"media", @{@"command": @"seek", @"time": @"10"}, &error) == nil, @"string seek accepted");
    EXPECT(BrowserRemoteActionPayload(@"media", @{@"command": @"skip"}, &error) == nil, @"skip without delta accepted");
    EXPECT(BrowserRemoteActionPayload(@"media", @{@"command": @"eject"}, &error) == nil && [error isEqualToString:@"invalid-request"], @"unknown command %@", error);
}

static void testTabPayloads(void) {
    NSString *error = nil;
    EXPECT(BrowserRemoteActionPayload(@"tabs/switch", @{}, &error) == nil && [error isEqualToString:@"invalid-request"], @"switch {} %@", error);
    error = nil;
    NSDictionary *switchPayload = BrowserRemoteActionPayload(@"tabs/switch", @{@"id": @"t1"}, &error);
    EXPECT([switchPayload isEqualToDictionary:@{@"id": @"t1"}] && error == nil, @"switch %@ %@", switchPayload, error);
    NSDictionary *newPayload = BrowserRemoteActionPayload(@"tabs/new", @{}, &error);
    EXPECT([newPayload isEqualToDictionary:@{}], @"new %@", newPayload);
    error = nil;
    EXPECT(BrowserRemoteActionPayload(@"tabs/explode", @{}, &error) == nil && [error isEqualToString:@"invalid-request"], @"unknown %@", error);
}

static void testWebURLValidation(void) {
    EXPECT(BrowserRemoteIsWebURLString(@"https://a.com"), @"https rejected");
    EXPECT(BrowserRemoteIsWebURLString(@" http://a.com/x "), @"trimmed http rejected");
    EXPECT(!BrowserRemoteIsWebURLString(@"ftp://a.com"), @"ftp accepted");
    EXPECT(!BrowserRemoteIsWebURLString(@"javascript:alert(1)"), @"javascript accepted");
    EXPECT(!BrowserRemoteIsWebURLString(@"https://"), @"hostless accepted");
    EXPECT(!BrowserRemoteIsWebURLString(@""), @"empty accepted");
}

static void testFavoritePayloads(void) {
    NSString *error = nil;
    NSDictionary *add = BrowserRemoteActionPayload(@"favorites/add", @{@"url": @" https://a.com "}, &error);
    EXPECT([add[@"url"] isEqualToString:@"https://a.com"] && [add[@"title"] isEqualToString:@""], @"add %@ %@", add, error);
    NSDictionary *addCurrent = BrowserRemoteActionPayload(@"favorites/add", @{@"current": @YES}, &error);
    EXPECT([addCurrent isEqualToDictionary:@{@"current": @YES}], @"add current %@", addCurrent);
    error = nil;
    EXPECT(BrowserRemoteActionPayload(@"favorites/add", @{@"url": @"ftp://a"}, &error) == nil && [error isEqualToString:@"invalid-url"], @"add ftp %@", error);
    error = nil;
    EXPECT(BrowserRemoteActionPayload(@"favorites/update", @{@"url": @"https://a.com", @"title": @"A"}, &error) == nil && [error isEqualToString:@"invalid-request"], @"update no index %@", error);
    error = nil;
    EXPECT(BrowserRemoteActionPayload(@"favorites/update", @{@"index": @-1, @"url": @"https://a.com", @"title": @"A"}, &error) == nil && [error isEqualToString:@"invalid-index"], @"update -1 %@", error);
    error = nil;
    EXPECT(BrowserRemoteActionPayload(@"favorites/move", @{@"index": @0, @"url": @"https://a.com", @"to": @"x"}, &error) == nil && [error isEqualToString:@"invalid-request"], @"move to x %@", error);
    error = nil;
    NSDictionary *open = BrowserRemoteActionPayload(@"favorites/open", @{@"index": @0, @"url": @"https://a.com"}, &error);
    EXPECT(open != nil && ![open[@"newTab"] boolValue] && [open[@"index"] integerValue] == 0, @"open %@ %@", open, error);
    NSDictionary *remove = BrowserRemoteActionPayload(@"favorites/remove", @{@"index": @1, @"url": @"https://b.com"}, &error);
    EXPECT([remove[@"index"] integerValue] == 1 && [remove[@"url"] isEqualToString:@"https://b.com"], @"remove %@", remove);
}

static void testHomePayload(void) {
    NSString *error = nil;
    NSDictionary *launch = BrowserRemoteActionPayload(@"home", @{@"launch": @"home-page"}, &error);
    EXPECT([launch[@"launch"] isEqualToString:@"home-page"] && error == nil, @"launch %@ %@", launch, error);
    EXPECT(BrowserRemoteActionPayload(@"home", @{@"launch": @"sometimes"}, &error) == nil && [error isEqualToString:@"invalid-launch"], @"bad launch %@", error);
    error = nil;
    EXPECT(BrowserRemoteActionPayload(@"home", @{@"url": @"notaurl"}, &error) == nil && [error isEqualToString:@"invalid-url"], @"bad url %@", error);
    error = nil;
    NSDictionary *useCurrent = BrowserRemoteActionPayload(@"home", @{@"useCurrent": @YES}, &error);
    EXPECT([useCurrent isEqualToDictionary:@{@"useCurrent": @YES}], @"useCurrent %@", useCurrent);
    error = nil;
    EXPECT(BrowserRemoteActionPayload(@"home", @{}, &error) == nil && [error isEqualToString:@"invalid-request"], @"empty %@", error);
    NSDictionary *url = BrowserRemoteActionPayload(@"home", @{@"url": @" https://www.google.com "}, &error);
    EXPECT([url[@"url"] isEqualToString:@"https://www.google.com"], @"url %@", url);
    NSDictionary *favorites = BrowserRemoteActionPayload(@"home", @{@"favorites": @YES}, &error);
    EXPECT([favorites isEqualToDictionary:@{@"favorites": @YES}], @"favorites %@", favorites);
    EXPECT(BrowserRemoteActionPayload(@"home", @{@"favorites": @"yes"}, &error) == nil, @"string favorites accepted");
}

static NSData *Hex(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    for (NSString *pair in [hex componentsSeparatedByString:@" "]) {
        unsigned value = 0;
        [[NSScanner scannerWithString:pair] scanHexInt:&value];
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}

// A client frame: FIN + opcode, masked with a fixed key (finalBit NO → fragment).
static NSData *MaskedFrame(uint8_t opcode, NSData *payload, BOOL finalBit) {
    NSMutableData *frame = [NSMutableData data];
    uint8_t first = (uint8_t)((finalBit ? 0x80 : 0x00) | opcode);
    [frame appendBytes:&first length:1];
    if (payload.length < 126) {
        uint8_t length = (uint8_t)(0x80 | payload.length);
        [frame appendBytes:&length length:1];
    } else {
        uint8_t length[3] = {0x80 | 126, (uint8_t)(payload.length >> 8), (uint8_t)(payload.length & 0xff)};
        [frame appendBytes:length length:3];
    }
    uint8_t mask[4] = {0x11, 0x22, 0x33, 0x44};
    [frame appendBytes:mask length:4];
    const uint8_t *bytes = payload.bytes;
    for (NSUInteger index = 0; index < payload.length; index++) {
        uint8_t masked = bytes[index] ^ mask[index % 4];
        [frame appendBytes:&masked length:1];
    }
    return frame;
}

static void testWebSocketAcceptMatchesRFC(void) {
    NSString *accept = BrowserRemoteWebSocketAccept(@"dGhlIHNhbXBsZSBub25jZQ==");
    EXPECT([accept isEqualToString:@"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="], @"accept %@", accept);
}

static void testDetectsUpgrade(void) {
    NSString *base = @"GET /api/trackpad HTTP/1.1\r\nHost: localhost\r\nUpgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\n";
    EXPECT(BrowserRemoteRequestIsWebSocketUpgrade(ParsedRequest([base stringByAppendingString:@"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: x\r\n\r\n"])), @"valid upgrade rejected");
    EXPECT(!BrowserRemoteRequestIsWebSocketUpgrade(ParsedRequest([base stringByAppendingString:@"Sec-WebSocket-Version: 13\r\n\r\n"])), @"missing key accepted");
    EXPECT(!BrowserRemoteRequestIsWebSocketUpgrade(ParsedRequest([base stringByAppendingString:@"Sec-WebSocket-Version: 8\r\nSec-WebSocket-Key: x\r\n\r\n"])), @"version 8 accepted");
    NSString *post = [[base stringByReplacingOccurrencesOfString:@"GET" withString:@"POST"] stringByAppendingString:@"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: x\r\n\r\n"];
    EXPECT(!BrowserRemoteRequestIsWebSocketUpgrade(ParsedRequest(post)), @"POST accepted");
}

static void testDecodesRFCMaskedHello(void) {
    BrowserRemoteFrame *frame = nil;
    NSUInteger consumed = 0;
    BrowserRemoteFrameStatus status = BrowserRemoteDecodeFrame(Hex(@"81 85 37 fa 21 3d 7f 9f 4d 51 58"), &frame, &consumed);
    NSString *text = [[NSString alloc] initWithData:frame.payload encoding:NSUTF8StringEncoding];
    EXPECT(status == BrowserRemoteFrameStatusFrame && frame.opcode == 1 && [text isEqualToString:@"Hello"] && consumed == 11,
           @"status %ld opcode %d text %@ consumed %lu", (long)status, frame.opcode, text, (unsigned long)consumed);
}

static void testDecodes16BitLength(void) {
    NSMutableData *payload = [NSMutableData dataWithLength:200];
    memset(payload.mutableBytes, 'a', 200);
    BrowserRemoteFrame *frame = nil;
    NSUInteger consumed = 0;
    BrowserRemoteFrameStatus status = BrowserRemoteDecodeFrame(MaskedFrame(1, payload, YES), &frame, &consumed);
    EXPECT(status == BrowserRemoteFrameStatusFrame && [frame.payload isEqualToData:payload] && consumed == 2 + 2 + 4 + 200,
           @"status %ld length %lu consumed %lu", (long)status, (unsigned long)frame.payload.length, (unsigned long)consumed);
}

static void testIncompleteAndTwoFrames(void) {
    NSData *hello = Hex(@"81 85 37 fa 21 3d 7f 9f 4d 51 58");
    BrowserRemoteFrame *frame = nil;
    NSUInteger consumed = 0;
    EXPECT(BrowserRemoteDecodeFrame([hello subdataWithRange:NSMakeRange(0, 6)], &frame, &consumed) == BrowserRemoteFrameStatusIncomplete, @"partial not incomplete");
    NSMutableData *two = [hello mutableCopy];
    [two appendData:hello];
    EXPECT(BrowserRemoteDecodeFrame(two, &frame, &consumed) == BrowserRemoteFrameStatusFrame && consumed == 11, @"first of two consumed %lu", (unsigned long)consumed);
    NSData *rest = [two subdataWithRange:NSMakeRange(consumed, two.length - consumed)];
    BrowserRemoteFrameStatus second = BrowserRemoteDecodeFrame(rest, &frame, &consumed);
    NSString *text = [[NSString alloc] initWithData:frame.payload encoding:NSUTF8StringEncoding];
    EXPECT(second == BrowserRemoteFrameStatusFrame && [text isEqualToString:@"Hello"], @"second %ld %@", (long)second, text);
}

static void testRejectsUnmaskedBinaryFragmented(void) {
    BrowserRemoteFrame *frame = nil;
    NSUInteger consumed = 0;
    NSData *hello = [@"Hello" dataUsingEncoding:NSUTF8StringEncoding];
    EXPECT(BrowserRemoteDecodeFrame(Hex(@"81 05 48 65 6c 6c 6f"), &frame, &consumed) == BrowserRemoteFrameStatusProtocolError, @"unmasked accepted");
    EXPECT(BrowserRemoteDecodeFrame(MaskedFrame(2, hello, YES), &frame, &consumed) == BrowserRemoteFrameStatusProtocolError, @"binary accepted");
    EXPECT(BrowserRemoteDecodeFrame(MaskedFrame(1, hello, NO), &frame, &consumed) == BrowserRemoteFrameStatusProtocolError, @"fragment accepted");
    EXPECT(BrowserRemoteDecodeFrame(Hex(@"81 ff 00 00 00 00 00 00 00 05"), &frame, &consumed) == BrowserRemoteFrameStatusProtocolError, @"64-bit length accepted");
}

static void testRejectsOversizedPayload(void) {
    BrowserRemoteFrame *frame = nil;
    NSUInteger consumed = 0;
    BrowserRemoteFrameStatus status = BrowserRemoteDecodeFrame(Hex(@"81 fe 04 01 11 22 33 44"), &frame, &consumed);
    EXPECT(status == BrowserRemoteFrameStatusTooLarge, @"status %ld", (long)status);
}

static void testEncodesCloseAndPong(void) {
    EXPECT([BrowserRemoteCloseFrame(1002) isEqualToData:Hex(@"88 02 03 ea")], @"close %@", BrowserRemoteCloseFrame(1002));
    NSData *pong = BrowserRemoteEncodeFrame(10, [@"hi" dataUsingEncoding:NSUTF8StringEncoding]);
    EXPECT([pong isEqualToData:Hex(@"8a 02 68 69")], @"pong %@", pong);
}

static BrowserRemoteTrackpadKind ParseMessage(NSString *json, double *dx, double *dy) {
    return BrowserRemoteParseTrackpadMessage([json dataUsingEncoding:NSUTF8StringEncoding], dx, dy);
}

static void testParsesTrackpadMessages(void) {
    double dx = 0, dy = 0;
    EXPECT(ParseMessage(@"{\"t\":\"m\",\"dx\":3,\"dy\":-1}", &dx, &dy) == BrowserRemoteTrackpadKindMove && dx == 3 && dy == -1, @"move %f %f", dx, dy);
    EXPECT(ParseMessage(@"{\"t\":\"s\",\"dx\":0,\"dy\":40}", &dx, &dy) == BrowserRemoteTrackpadKindScroll && dy == 40, @"scroll %f", dy);
    EXPECT(ParseMessage(@"{\"t\":\"c\"}", &dx, &dy) == BrowserRemoteTrackpadKindClick, @"click");
    EXPECT(ParseMessage(@"{\"t\":\"d\"}", &dx, &dy) == BrowserRemoteTrackpadKindDoubleClick, @"double");
    EXPECT(ParseMessage(@"{\"t\":\"m\",\"dx\":9999,\"dy\":-9999}", &dx, &dy) == BrowserRemoteTrackpadKindMove && dx == 500 && dy == -500, @"clamp %f %f", dx, dy);
    EXPECT(ParseMessage(@"{\"t\":\"x\"}", &dx, &dy) == BrowserRemoteTrackpadKindNone, @"unknown type");
    EXPECT(ParseMessage(@"nope", &dx, &dy) == BrowserRemoteTrackpadKindNone, @"bad json");
    EXPECT(ParseMessage(@"{\"t\":\"m\",\"dx\":\"a\"}", &dx, &dy) == BrowserRemoteTrackpadKindNone, @"string delta");
}

static void testWebSocketOriginMustMatchHost(void) {
    NSString *base = @"GET /api/trackpad HTTP/1.1\r\nHost: alans-apple-tv-4k.local:8080\r\n";
    EXPECT(BrowserRemoteWebSocketOriginAllowed(ParsedRequest([base stringByAppendingString:@"\r\n"])), @"no Origin (native client) rejected");
    EXPECT(BrowserRemoteWebSocketOriginAllowed(ParsedRequest([base stringByAppendingString:@"Origin: http://Alans-Apple-TV-4K.local:8080\r\n\r\n"])), @"same-origin panel rejected");
    EXPECT(!BrowserRemoteWebSocketOriginAllowed(ParsedRequest([base stringByAppendingString:@"Origin: https://evil.example.com\r\n\r\n"])), @"cross-site origin accepted");
    EXPECT(!BrowserRemoteWebSocketOriginAllowed(ParsedRequest([base stringByAppendingString:@"Origin: http://alans-apple-tv-4k.local:9999\r\n\r\n"])), @"other port accepted");
    EXPECT(!BrowserRemoteWebSocketOriginAllowed(ParsedRequest([base stringByAppendingString:@"Origin: null\r\n\r\n"])), @"null origin accepted");
}

int main(void) {
    @autoreleasepool {
        sFailures = [NSMutableArray array];
        struct { const char *name; void (*run)(void); } tests[] = {
            {"testParsesSimpleGET", testParsesSimpleGET},
            {"testParsesRequestSplitAcrossChunks", testParsesRequestSplitAcrossChunks},
            {"testDecodesUTF8BodyAndPercentEncodedQuery", testDecodesUTF8BodyAndPercentEncodedQuery},
            {"testHeaderKeysAreLowercased", testHeaderKeysAreLowercased},
            {"testRejectsMalformedRequestLine", testRejectsMalformedRequestLine},
            {"testRejectsOversizedBody", testRejectsOversizedBody},
            {"testRejectsOversizedHeaders", testRejectsOversizedHeaders},
            {"testInvalidJSONBodyReturnsNil", testInvalidJSONBodyReturnsNil},
            {"testResponseHasLengthAndClose", testResponseHasLengthAndClose},
            {"testOpenPayloadRejectsBlankText", testOpenPayloadRejectsBlankText},
            {"testFieldPayloadRequiresIDAndText", testFieldPayloadRequiresIDAndText},
            {"testStateVersionBumpsOnlyOnChange", testStateVersionBumpsOnlyOnChange},
            {"testTrustsLocalHostsOnly", testTrustsLocalHostsOnly},
            {"testPostRequiresJSONContentType", testPostRequiresJSONContentType},
            {"testReadsStoredPairs", testReadsStoredPairs},
            {"testSkipsCorruptEntries", testSkipsCorruptEntries},
            {"testAddUsesURLWhenTitleBlank", testAddUsesURLWhenTitleBlank},
            {"testRemoveWithStaleURLIsRejected", testRemoveWithStaleURLIsRejected},
            {"testMoveAndUpdate", testMoveAndUpdate},
            {"testMutationPostsNotification", testMutationPostsNotification},
            {"testStateIncludesAdminSections", testStateIncludesAdminSections},
            {"testMediaOnlyBumpsOnPlayheadJumps", testMediaOnlyBumpsOnPlayheadJumps},
            {"testMediaPayloads", testMediaPayloads},
            {"testTabPayloads", testTabPayloads},
            {"testWebURLValidation", testWebURLValidation},
            {"testFavoritePayloads", testFavoritePayloads},
            {"testHomePayload", testHomePayload},
            {"testWebSocketAcceptMatchesRFC", testWebSocketAcceptMatchesRFC},
            {"testDetectsUpgrade", testDetectsUpgrade},
            {"testDecodesRFCMaskedHello", testDecodesRFCMaskedHello},
            {"testDecodes16BitLength", testDecodes16BitLength},
            {"testIncompleteAndTwoFrames", testIncompleteAndTwoFrames},
            {"testRejectsUnmaskedBinaryFragmented", testRejectsUnmaskedBinaryFragmented},
            {"testRejectsOversizedPayload", testRejectsOversizedPayload},
            {"testEncodesCloseAndPong", testEncodesCloseAndPong},
            {"testParsesTrackpadMessages", testParsesTrackpadMessages},
            {"testWebSocketOriginMustMatchHost", testWebSocketOriginMustMatchHost},
        };
        int failed = 0;
        size_t count = sizeof(tests) / sizeof(tests[0]);
        for (size_t i = 0; i < count; i++) {
            NSUInteger before = sFailures.count;
            tests[i].run();
            if (sFailures.count > before) {
                failed++;
                printf("FAIL %s: %s\n", tests[i].name, sFailures.lastObject.UTF8String);
            } else {
                printf("PASS %s\n", tests[i].name);
            }
        }
        printf("%zu/%zu passed\n", count - failed, count);
        return failed == 0 ? 0 : 1;
    }
}
