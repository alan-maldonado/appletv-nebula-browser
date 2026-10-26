// Tests for the pure-Foundation parts of Nebula Remote. Run with Tests/run-remote-tests.sh.
#import <Foundation/Foundation.h>

#import "BrowserFavoritesStore.h"
#import "BrowserRemoteHTTP.h"
#import "BrowserRemoteState.h"

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
            {"testTabPayloads", testTabPayloads},
            {"testWebURLValidation", testWebURLValidation},
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
