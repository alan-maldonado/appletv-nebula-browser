// Tests for the pure-Foundation parts of Nebula Remote. Run with Tests/run-remote-tests.sh.
#import <Foundation/Foundation.h>

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
