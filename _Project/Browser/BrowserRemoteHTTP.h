#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure HTTP/1.1 helpers for Nebula Remote (Foundation only, so they also build
// in the macOS test runner under _Project/Tests).

static const NSUInteger kBrowserRemoteMaxHeaderBytes = 16 * 1024;
static const NSUInteger kBrowserRemoteMaxBodyBytes = 64 * 1024;

typedef NS_ENUM(NSInteger, BrowserRemoteParseStatus) {
    BrowserRemoteParseStatusIncomplete,
    BrowserRemoteParseStatusComplete,
    BrowserRemoteParseStatusInvalid,
    BrowserRemoteParseStatusTooLarge,
};

@interface BrowserRemoteRequest : NSObject

@property (nonatomic, readonly) NSString *method;
// Path without the query string.
@property (nonatomic, readonly) NSString *path;
// Percent-decoded query items.
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *query;
// Header names are lowercased.
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, readonly) NSData *body;

- (nullable id)JSONBody;

@end

// Complete only once Content-Length bytes of body are present. outRequest is
// set when the request line and headers parse (also for Invalid JSON bodies).
BrowserRemoteParseStatus BrowserRemoteParseRequest(NSData *buffer, BrowserRemoteRequest * _Nullable * _Nullable outRequest);

// Status line plus Content-Type, Content-Length, Connection: close, Cache-Control: no-store.
NSData *BrowserRemoteResponseData(NSInteger status, NSString *contentType, NSData *body);
NSData *BrowserRemoteJSONResponseData(NSInteger status, id JSONObject);

// DNS-rebinding guard: Host must be a .local name, an IP literal or localhost.
BOOL BrowserRemoteRequestHasTrustedHost(BrowserRemoteRequest *request);
// CSRF guard: a cross-site page can only POST application/json after a CORS preflight,
// which the server never grants; plain no-cors posts arrive as text/plain.
BOOL BrowserRemoteRequestHasJSONContentType(BrowserRemoteRequest *request);

// /api/open body {text, newTab}: trimmed text, or nil when missing, not a string or blank.
NSString * _Nullable BrowserRemoteOpenPayloadFromJSON(id _Nullable JSON, BOOL *outNewTab);
// /api/field body {id, text, submit}: nil when id or text is missing; submit defaults NO.
NSDictionary * _Nullable BrowserRemoteFieldPayloadFromJSON(id _Nullable JSON);

NS_ASSUME_NONNULL_END
