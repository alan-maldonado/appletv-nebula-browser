#import "BrowserNativeVideoAssetLoader.h"

#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static NSString * const kBrowserNativeVideoAssetLoaderLogPrefix = @"[NativeVideoAssetLoader]";
static NSString * const kBrowserNativeVideoHTTPProxyScheme = @"browserhttp";
static NSString * const kBrowserNativeVideoHTTPSProxyScheme = @"browserhttps";

// NSURLErrorCannotOpenResource is no longer declared in the tvOS SDK headers;
// re-declare its canonical NSURLErrorDomain value.
static NSInteger const kBrowserNativeVideoURLErrorCannotOpenResource = -1015;

// Declared here so the redirect delegate below can call it.
@interface BrowserNativeVideoAssetLoader ()
- (nullable NSURLRequest *)requestByApplyingHeadersToRedirect:(NSURLRequest *)newRequest
                                                 originalURL:(nullable NSURL *)originalURL;
@end

// NSURLSession silently drops custom headers (Referer among them) when it
// follows a redirect, and the streameast-family CDN 403s without them — so
// redirects go through here to re-apply the loader's full header set. It is a
// separate object (weakly holding the loader) because NSURLSession retains its
// delegate for its whole lifetime.
@interface BrowserNativeVideoRedirectHeaderDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, weak) BrowserNativeVideoAssetLoader *loader;
@end

@implementation BrowserNativeVideoRedirectHeaderDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)newRequest completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    (void)session;
    (void)response;
    BrowserNativeVideoAssetLoader *loader = self.loader;
    if (loader == nil || completionHandler == nil) {
        completionHandler(newRequest);
        return;
    }
    completionHandler([loader requestByApplyingHeadersToRedirect:newRequest originalURL:task.originalRequest.URL]);
}

@end

@interface BrowserNativeVideoAssetLoader () <AVAssetResourceLoaderDelegate>

@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *cookies;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t resourceLoaderQueue;
@property (nonatomic, strong) NSMapTable<AVAssetResourceLoadingRequest *, NSURLSessionDataTask *> *taskByLoadingRequest;
// Playlist log rate limit; only touched on the serial resourceLoaderQueue.
@property (nonatomic, assign) CFAbsoluteTime lastPlaylistLogTime;

@end

@implementation BrowserNativeVideoAssetLoader

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserNativeVideoAssetLoaderLogPrefix, message);
}

- (instancetype)initWithRequestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                               cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super init];
    if (self) {
        _requestHeaders = [requestHeaders copy] ?: @{};
        _cookies = [cookies copy] ?: @[];
        // LIVE HLS media playlists must be re-fetched fresh on every refresh:
        // any cached playlist response freezes the media sequence and the
        // player dies once the listed segments run out. Ephemeral config, no
        // URL cache at all, reload-ignoring-cache policy on the session.
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        configuration.URLCache = nil;
        configuration.timeoutIntervalForRequest = 20.0;
        configuration.waitsForConnectivity = YES;
        _resourceLoaderQueue = dispatch_queue_create("com.browser.nativevideo.assetloader", DISPATCH_QUEUE_SERIAL);
        BrowserNativeVideoRedirectHeaderDelegate *redirectDelegate = [BrowserNativeVideoRedirectHeaderDelegate new];
        redirectDelegate.loader = self;
        // nil delegate queue: system-managed background queue; all response
        // handling hops to resourceLoaderQueue anyway.
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:redirectDelegate delegateQueue:nil];
        _taskByLoadingRequest = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (void)dealloc {
    // The redirect delegate is a separate object, so no session -> self cycle;
    // just release the session's hold on it.
    [_session finishTasksAndInvalidate];
}

- (NSURL *)assetURLForPlaybackURL:(NSURL *)playbackURL {
    NSURLComponents *components = [NSURLComponents componentsWithURL:playbackURL resolvingAgainstBaseURL:NO];
    NSString *scheme = components.scheme.lowercaseString;
    if ([scheme isEqualToString:@"https"]) {
        components.scheme = kBrowserNativeVideoHTTPSProxyScheme;
    } else if ([scheme isEqualToString:@"http"]) {
        components.scheme = kBrowserNativeVideoHTTPProxyScheme;
    }
    return components.URL ?: playbackURL;
}

- (BOOL)attachToAsset:(id)asset {
    if (asset == nil) {
        return NO;
    }

    SEL resourceLoaderSelector = NSSelectorFromString(@"resourceLoader");
    if (![asset respondsToSelector:resourceLoaderSelector]) {
        return NO;
    }

    AVAssetResourceLoader *resourceLoader = ((id (*)(id, SEL))objc_msgSend)(asset, resourceLoaderSelector);
    [resourceLoader setDelegate:self queue:self.resourceLoaderQueue];
    return YES;
}

- (NSURL *)playbackURLFromAssetURL:(NSURL *)assetURL {
    if (assetURL == nil) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:assetURL resolvingAgainstBaseURL:NO];
    NSString *scheme = components.scheme.lowercaseString;
    if ([scheme isEqualToString:kBrowserNativeVideoHTTPSProxyScheme]) {
        components.scheme = @"https";
    } else if ([scheme isEqualToString:kBrowserNativeVideoHTTPProxyScheme]) {
        components.scheme = @"http";
    }
    return components.URL;
}

- (NSString *)cookieHeaderValue {
    return [self cookieHeaderValueForURL:nil];
}

- (BOOL)cookie:(NSHTTPCookie *)cookie matchesURL:(NSURL *)URL {
    if (cookie == nil || URL == nil) {
        return NO;
    }

    NSString *host = URL.host.lowercaseString ?: @"";
    NSString *cookieDomain = cookie.domain.lowercaseString ?: @"";
    if (host.length == 0 || cookieDomain.length == 0) {
        return NO;
    }

    if ([cookieDomain hasPrefix:@"."]) {
        cookieDomain = [cookieDomain substringFromIndex:1];
    }

    BOOL domainMatches = [host isEqualToString:cookieDomain] || [host hasSuffix:[@"." stringByAppendingString:cookieDomain]];
    if (!domainMatches) {
        return NO;
    }

    if (cookie.isSecure && ![URL.scheme.lowercaseString isEqualToString:@"https"]) {
        return NO;
    }

    NSString *cookiePath = cookie.path.length > 0 ? cookie.path : @"/";
    NSString *requestPath = URL.path.length > 0 ? URL.path : @"/";
    return [requestPath hasPrefix:cookiePath];
}

- (NSArray<NSHTTPCookie *> *)cookiesForURL:(NSURL *)URL {
    if (self.cookies.count == 0 || URL == nil) {
        return @[];
    }

    NSMutableArray<NSHTTPCookie *> *matchingCookies = [NSMutableArray array];
    for (NSHTTPCookie *cookie in self.cookies) {
        if ([self cookie:cookie matchesURL:URL]) {
            [matchingCookies addObject:cookie];
        }
    }
    return matchingCookies;
}

- (NSString *)cookieHeaderValueForURL:(NSURL *)URL {
    NSArray<NSHTTPCookie *> *cookies = URL != nil ? [self cookiesForURL:URL] : self.cookies;
    if (cookies.count == 0) {
        return nil;
    }
    NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
    return cookieHeaders[@"Cookie"];
}

// The full browser header set (UA + Referer etc.) on every derivative request:
// master, media playlists, segments and keys all go through this method. The
// dictionary is assigned wholesale (allHTTPHeaderFields) so subresources get
// the exact same headers as the presenting asset; the Range header computed
// from the loading request is merged in when present.
- (NSMutableDictionary<NSString *, NSString *> *)headerFieldsForURL:(NSURL *)URL mergingInto:(nullable NSMutableDictionary<NSString *, NSString *> *)headers {
    NSMutableDictionary<NSString *, NSString *> *merged = headers ?: [NSMutableDictionary dictionary];
    [self.requestHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        if (value.length == 0) {
            return;
        }
        // Never emit an Origin header on any media request: the signed-storage
        // hosts behind the streameast-family segment redirects 404 any request
        // bearing Origin (curl A/B on the live redirect URL).
        if ([key caseInsensitiveCompare:@"Origin"] == NSOrderedSame) {
            return;
        }
        merged[key] = value;
    }];

    NSString *cookieHeader = [self cookieHeaderValueForURL:URL];
    if (cookieHeader.length > 0) {
        merged[@"Cookie"] = cookieHeader;
    }
    return merged;
}

- (NSString *)rangeHeaderForLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    if (dataRequest == nil) {
        return nil;
    }

    long long startOffset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset;
    if (startOffset < 0) {
        startOffset = 0;
    }

    // Keep the existing range behavior (bytes=0-1 probe, then bytes=0-).
    if (dataRequest.requestsAllDataToEndOfResource) {
        return [NSString stringWithFormat:@"bytes=%lld-", startOffset];
    }
    if (dataRequest.requestedLength > 0) {
        long long endOffset = startOffset + dataRequest.requestedLength - 1;
        return [NSString stringWithFormat:@"bytes=%lld-%lld", startOffset, endOffset];
    }
    return nil;
}

- (NSMutableURLRequest *)requestForPlaybackURL:(NSURL *)playbackURL loadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:playbackURL];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30.0;
    // Belt and braces with the session config: never let URLCache serve a
    // stale playlist (critical) or segment (harmless — TS is immutable).
    request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;

    NSMutableDictionary<NSString *, NSString *> *headers = [self headerFieldsForURL:playbackURL mergingInto:nil];
    NSString *rangeHeader = [self rangeHeaderForLoadingRequest:loadingRequest];
    if (rangeHeader.length > 0) {
        headers[@"Range"] = rangeHeader;
    }
    request.allHTTPHeaderFields = headers;
    return request;
}

// Redirect: NSURLSession strips custom headers on redirect requests, so rebuild
// them here while keeping whatever Range the system computed. Cross-host
// exception: the new stream source redirects /redirect/ segments to a signed
// storage host whose hotlink protection 404s any request carrying a Referer or
// an Origin, so when the destination host differs from the original request's
// host, drop Referer and Origin (case-insensitively) and keep every other
// header, User-Agent included. Same-host redirects keep the full header set
// untouched.
- (nullable NSURLRequest *)requestByApplyingHeadersToRedirect:(NSURLRequest *)newRequest
                                                 originalURL:(nullable NSURL *)originalURL {
    NSMutableURLRequest *redirectRequest = [newRequest mutableCopy] ?: [NSMutableURLRequest new];
    redirectRequest.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSString *existingRange = [newRequest valueForHTTPHeaderField:@"Range"];
    if (existingRange.length > 0) {
        headers[@"Range"] = existingRange;
    }
    [self headerFieldsForURL:newRequest.URL mergingInto:headers];

    NSString *fromHost = originalURL.host.lowercaseString ?: @"";
    NSString *toHost = newRequest.URL.host.lowercaseString ?: @"";
    if (fromHost.length > 0 && toHost.length > 0 && ![fromHost isEqualToString:toHost]) {
        for (NSString *key in headers.allKeys) {
            if ([key caseInsensitiveCompare:@"Referer"] == NSOrderedSame ||
                [key caseInsensitiveCompare:@"Origin"] == NSOrderedSame) {
                [headers removeObjectForKey:key];
            }
        }
        [self log:@"referer/origin stripped on redirect host=%@->%@", fromHost, toHost];
    }

    redirectRequest.allHTTPHeaderFields = headers;
    return redirectRequest;
}

- (BOOL)isPlaylistResponse:(NSHTTPURLResponse *)response data:(NSData *)data requestURL:(NSURL *)requestURL {
    NSString *contentType = [response valueForHTTPHeaderField:@"Content-Type"].lowercaseString ?: @"";
    NSString *pathExtension = requestURL.pathExtension.lowercaseString ?: @"";
    if ([contentType containsString:@"mpegurl"] || [contentType containsString:@"m3u"] || [pathExtension isEqualToString:@"m3u8"]) {
        return YES;
    }

    if (data.length >= 7) {
        NSData *prefixData = [data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)128, data.length))];
        NSString *prefixString = [[NSString alloc] initWithData:prefixData encoding:NSUTF8StringEncoding];
        if ([prefixString containsString:@"#EXTM3U"]) {
            return YES;
        }
    }
    return NO;
}

// Streameast-family CDNs disguise MPEG-TS segments as .txt with Content-Type
// text/plain; AVFoundation's HLS parser rejects non-video types and the item
// fails with -12881. Sniff TS sync bytes (0x47 every 188-byte packet).
- (BOOL)isMpegTransportStreamData:(NSData *)data {
    if (data.length <= 188) {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (bytes[0] != 0x47) {
        return NO;
    }
    return bytes[188] == 0x47 || (data.length > 376 && bytes[376] == 0x47);
}

- (NSString *)proxyURLStringForPlaylistEntry:(NSString *)entry baseURL:(NSURL *)baseURL {
    if (entry.length == 0) {
        return entry;
    }

    NSURL *resolvedURL = [NSURL URLWithString:entry relativeToURL:baseURL].absoluteURL;
    if (resolvedURL == nil) {
        return entry;
    }

    NSString *scheme = resolvedURL.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return entry;
    }

    return [[self assetURLForPlaybackURL:resolvedURL] absoluteString] ?: entry;
}

- (NSString *)rewrittenPlaylistLine:(NSString *)line baseURL:(NSURL *)baseURL {
    NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmedLine.length == 0) {
        return line;
    }

    if (![trimmedLine hasPrefix:@"#"]) {
        return [self proxyURLStringForPlaylistEntry:trimmedLine baseURL:baseURL];
    }

    NSError *error = nil;
    NSRegularExpression *URIExpression = [NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:&error];
    if (URIExpression == nil || error != nil) {
        return line;
    }

    NSMutableString *rewrittenLine = [line mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [URIExpression matchesInString:line options:0 range:NSMakeRange(0, line.length)];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        if (match.numberOfRanges < 2) {
            continue;
        }
        NSRange valueRange = [match rangeAtIndex:1];
        NSString *originalValue = [line substringWithRange:valueRange];
        NSString *replacementValue = [self proxyURLStringForPlaylistEntry:originalValue baseURL:baseURL];
        [rewrittenLine replaceCharactersInRange:valueRange withString:replacementValue];
    }
    return rewrittenLine;
}

- (NSData *)rewrittenPlaylistDataFromData:(NSData *)data responseURL:(NSURL *)responseURL {
    NSString *playlistString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (playlistString.length == 0) {
        return data;
    }

    NSMutableArray<NSString *> *rewrittenLines = [NSMutableArray array];
    [playlistString enumerateLinesUsingBlock:^(NSString *line, __unused BOOL *stop) {
        [rewrittenLines addObject:[self rewrittenPlaylistLine:line baseURL:responseURL]];
    }];

    NSString *rewrittenString = [rewrittenLines componentsJoinedByString:@"\n"];
    if ([playlistString hasSuffix:@"\n"]) {
        rewrittenString = [rewrittenString stringByAppendingString:@"\n"];
    }
    return [rewrittenString dataUsingEncoding:NSUTF8StringEncoding] ?: data;
}

- (void)fillContentInfoForLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                                response:(NSHTTPURLResponse *)response
                                    data:(NSData *)data
                              requestURL:(NSURL *)requestURL {
    AVAssetResourceLoadingContentInformationRequest *contentInformationRequest = loadingRequest.contentInformationRequest;
    if (contentInformationRequest == nil) {
        return;
    }

    NSString *contentType = [response valueForHTTPHeaderField:@"Content-Type"] ?: response.MIMEType;
    if ([self isPlaylistResponse:response data:data requestURL:requestURL]) {
        contentType = @"application/vnd.apple.mpegurl";
    } else if ([self isMpegTransportStreamData:data]) {
        contentType = @"video/mp2t";
    }

    if (contentType.length > 0) {
        contentInformationRequest.contentType = contentType;
    }

    long long expectedLength = response.expectedContentLength;
    if (expectedLength > 0) {
        contentInformationRequest.contentLength = expectedLength;
    } else if (data.length > 0) {
        contentInformationRequest.contentLength = (long long)data.length;
    }

    NSString *acceptRanges = [response valueForHTTPHeaderField:@"Accept-Ranges"] ?: @"";
    contentInformationRequest.byteRangeAccessSupported = [acceptRanges.lowercaseString containsString:@"bytes"] || response.statusCode == 206;
}

// AVPlayer consults response.HTTPHeaderFields when deciding whether a playlist
// URL is refreshable; CDN playlist responses often carry no Cache-Control at
// all, and AVAssetResourceLoader's in-memory response can be reused instead of
// re-requesting the media playlist — a live stream then freezes once the listed
// segments run out. Rebuild every playlist response as explicitly
// non-cacheable so the player treats each delivery as fresh. NSHTTPURLResponse
// is immutable and the loading request's `response` is readonly, so the
// rebuilt response travels inside an NSCachedURLResponse attached via KVC; the
// status code and the original headers (Content-Type and Content-Length among
// them) are copied over untouched and only the three cache headers are forced.
- (void)attachNoCacheResponseToLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                                     response:(NSHTTPURLResponse *)response
                                         data:(NSData *)data {
    NSURL *responseURL = response.URL ?: loadingRequest.request.URL;
    if (responseURL == nil) {
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *headerFields = [NSMutableDictionary dictionary];
    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
            headerFields[key] = value;
        }
    }];
    headerFields[@"Cache-Control"] = @"no-cache, no-store, must-revalidate";
    headerFields[@"Pragma"] = @"no-cache";
    headerFields[@"Expires"] = @"0";

    NSHTTPURLResponse *noCacheResponse = [[NSHTTPURLResponse alloc] initWithURL:responseURL
                                                                     statusCode:response.statusCode
                                                                    HTTPVersion:@"HTTP/1.1"
                                                                   headerFields:headerFields];
    if (noCacheResponse == nil) {
        return;
    }

    NSCachedURLResponse *cachedResponse = [[NSCachedURLResponse alloc] initWithResponse:noCacheResponse
                                                                                   data:data ?: [NSData data]
                                                                               userInfo:nil
                                                                          storagePolicy:NSURLCacheStorageNotAllowed];
    @try {
        [loadingRequest setValue:cachedResponse forKey:@"response"];
    } @catch (NSException *exception) {
        [self log:@"no-cache response attach failed url=%@ exception=%@",
         responseURL.absoluteString ?: @"",
         exception.reason ?: @""];
    }
}

// Live media segments must arrive complete: when Content-Range describes a
// window that stops short of the resource's last byte, the delivered body is
// truncated ("bytes <start>-<end>/<total>" with end != total - 1). YES only
// proves truncation; NO also covers missing, unknown-total or unparseable
// headers, where nothing can be claimed either way.
- (BOOL)responseIndicatesPartialContentRange:(NSHTTPURLResponse *)response {
    NSString *contentRange = [response valueForHTTPHeaderField:@"Content-Range"];
    if (contentRange.length == 0) {
        return NO;
    }

    NSRange slash = [contentRange rangeOfString:@"/"];
    if (slash.location == NSNotFound || slash.location == 0 || NSMaxRange(slash) >= contentRange.length) {
        return NO;
    }
    NSString *unitAndRange = [contentRange substringToIndex:slash.location];
    NSString *totalString = [contentRange substringFromIndex:NSMaxRange(slash)];
    NSRange dash = [unitAndRange rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location == NSNotFound || NSMaxRange(dash) >= unitAndRange.length) {
        return NO;
    }
    NSString *endString = [unitAndRange substringFromIndex:NSMaxRange(dash)];

    NSScanner *endScanner = [NSScanner scannerWithString:endString];
    long long rangeEnd = -1;
    if (![endScanner scanLongLong:&rangeEnd] || !endScanner.isAtEnd || rangeEnd < 0) {
        return NO;
    }
    NSScanner *totalScanner = [NSScanner scannerWithString:totalString];
    long long rangeTotal = -1;
    if (![totalScanner scanLongLong:&rangeTotal] || !totalScanner.isAtEnd || rangeTotal <= 0) {
        return NO;
    }
    return rangeEnd != rangeTotal - 1;
}

// The new streameast stream source redirects each segment to a signed storage
// URL answering HTTP 206 with a Content-Range plus a malformed extra
// Cache-Control tail; the MPEG-TS body is healthy, yet AVPlayer rejects the
// 206 wrapper with CoreMediaErrorDomain -12881 seconds after delivery. For
// media segments only, rebuild the wrapper as a plain 200 the same way
// attachNoCacheResponseToLoadingRequest: travels (KVC `response` carrying an
// NSCachedURLResponse, storage disallowed): original headers minus
// Content-Range, Content-Length matching the delivered body, with
// Content-Type/Accept-Ranges copied over untouched. Body bytes are never
// modified.
- (void)attachNormalizedSegmentResponseToLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                                               response:(NSHTTPURLResponse *)response
                                                   data:(NSData *)data {
    NSURL *responseURL = response.URL ?: loadingRequest.request.URL;
    if (responseURL == nil) {
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *headerFields = [NSMutableDictionary dictionary];
    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) {
            return;
        }
        if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
            return;
        }
        headerFields[key] = value;
    }];
    headerFields[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)data.length];

    NSHTTPURLResponse *okResponse = [[NSHTTPURLResponse alloc] initWithURL:responseURL
                                                                statusCode:200
                                                               HTTPVersion:@"HTTP/1.1"
                                                              headerFields:headerFields];
    if (okResponse == nil) {
        return;
    }

    NSCachedURLResponse *cachedResponse = [[NSCachedURLResponse alloc] initWithResponse:okResponse
                                                                                   data:data ?: [NSData data]
                                                                              userInfo:nil
                                                                         storagePolicy:NSURLCacheStorageNotAllowed];
    @try {
        [loadingRequest setValue:cachedResponse forKey:@"response"];
    } @catch (NSException *exception) {
        [self log:@"normalized segment response attach failed url=%@ exception=%@",
         responseURL.absoluteString ?: @"",
         exception.reason ?: @""];
    }
}

- (NSData *)responseDataForLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest data:(NSData *)data {
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    if (dataRequest == nil || data.length == 0) {
        return data ?: [NSData data];
    }

    if (dataRequest.requestedOffset <= 0 && dataRequest.currentOffset <= 0) {
        return data;
    }

    long long startOffset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset;
    if (startOffset < 0 || startOffset >= (long long)data.length) {
        return [NSData data];
    }

    NSUInteger length = data.length - (NSUInteger)startOffset;
    if (!dataRequest.requestsAllDataToEndOfResource && dataRequest.requestedLength > 0) {
        length = MIN(length, (NSUInteger)dataRequest.requestedLength);
    }
    return [data subdataWithRange:NSMakeRange((NSUInteger)startOffset, length)];
}

// Playlist family marker of the streameast CDN layout: /playlist/<ID>/....
// Media playlists and segment hosts rotate, but the ID prefix identifies the
// stream, so a fresh master captured by the probes can stand in for a
// 403/404ing media playlist of the same family.
- (NSString *)playlistFamilyPrefixOfURL:(NSURL *)URL {
    NSString *path = URL.path;
    if (path.length == 0) {
        return nil;
    }
    NSRange marker = [path rangeOfString:@"/playlist/"];
    if (marker.location == NSNotFound) {
        return nil;
    }
    NSString *tail = [path substringFromIndex:NSMaxRange(marker)];
    NSRange nextSlash = [tail rangeOfString:@"/"];
    if (nextSlash.location == NSNotFound) {
        return nil;
    }
    NSString *streamID = [tail substringToIndex:nextSlash.location];
    if (streamID.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"/playlist/%@/", streamID];
}

// Freshest captured master in the same /playlist/<ID>/ family as the failed
// URL (fresherMasterURLs is oldest-first, so scan newest-last); nil when the
// family is unknown or nothing matches.
- (NSURL *)fresherMasterURLMatchingFamilyOfFailedURL:(NSURL *)failedURL {
    NSString *prefix = [self playlistFamilyPrefixOfURL:failedURL];
    if (prefix.length == 0 || self.fresherMasterURLs.count == 0) {
        return nil;
    }
    for (NSURL *candidate in [self.fresherMasterURLs reverseObjectEnumerator]) {
        if (![candidate isKindOfClass:[NSURL class]]) {
            continue;
        }
        NSString *candidatePrefix = [self playlistFamilyPrefixOfURL:candidate];
        if (candidatePrefix.length == 0 || ![candidatePrefix isEqualToString:prefix]) {
            continue;
        }
        if ([candidate.absoluteString isEqualToString:failedURL.absoluteString]) {
            continue;
        }
        return candidate;
    }
    return nil;
}

// Single fetch for one loading request; on 403/404 for a playlist-family URL
// (and when no rewrite has been attempted yet) retries once against the
// freshest captured master of the same family.
- (void)startTaskForURL:(NSURL *)playbackURL
         loadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
       allowMasterRewrite:(BOOL)allowMasterRewrite {
    NSMutableURLRequest *request = [self requestForPlaybackURL:playbackURL loadingRequest:loadingRequest];
    [self log:@"requesting resource url=%@ range=%@", playbackURL.absoluteString ?: @"", [request valueForHTTPHeaderField:@"Range"] ?: @""];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        dispatch_async(strongSelf.resourceLoaderQueue, ^{
            [strongSelf.taskByLoadingRequest removeObjectForKey:loadingRequest];

            if (error != nil) {
                [strongSelf log:@"resource failed url=%@ error=%@", playbackURL.absoluteString ?: @"", error];
                [loadingRequest finishLoadingWithError:error];
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (![httpResponse isKindOfClass:[NSHTTPURLResponse class]]) {
                NSError *invalidResponseError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
                [loadingRequest finishLoadingWithError:invalidResponseError];
                return;
            }

            NSInteger statusCode = httpResponse.statusCode;
            if (statusCode < 200 || statusCode >= 300) {
                NSString *bodyPreview = data.length > 0 ? [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)160, data.length))] encoding:NSUTF8StringEncoding] : @"";
                [strongSelf log:@"status=%ld url=%@ preview=%@",
                 (long)statusCode,
                 playbackURL.absoluteString ?: @"",
                 bodyPreview ?: @""];

                // A 403/404 media playlist of a known stream family is almost
                // always a rotated/stale URL: swap in the freshest captured
                // master of the same /playlist/<ID>/ family and retry once.
                BOOL isForbiddenOrMissing = (statusCode == 403 || statusCode == 404);
                if (allowMasterRewrite && isForbiddenOrMissing) {
                    NSURL *fresherMaster = [strongSelf fresherMasterURLMatchingFamilyOfFailedURL:playbackURL];
                    if (fresherMaster != nil) {
                        [strongSelf log:@"rewriting %ld url=%@ to fresher master=%@",
                         (long)statusCode,
                         playbackURL.absoluteString ?: @"",
                         fresherMaster.absoluteString ?: @""];
                        [strongSelf startTaskForURL:fresherMaster loadingRequest:loadingRequest allowMasterRewrite:NO];
                        return;
                    }
                }

                NSError *statusError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]
                }];
                [loadingRequest finishLoadingWithError:statusError];
                return;
            }

            NSData *responseData = data ?: [NSData data];
            if ([strongSelf isPlaylistResponse:httpResponse data:responseData requestURL:playbackURL]) {
                // Live playlists refresh ~once per target duration; cap the
                // log to one line per second so the refresh stays traceable
                // without flooding the console.
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - strongSelf.lastPlaylistLogTime >= 1.0) {
                    strongSelf.lastPlaylistLogTime = now;
                    [strongSelf log:@"playlist status=%ld bytes=%lu url=%@",
                     (long)statusCode,
                     (unsigned long)responseData.length,
                     playbackURL.absoluteString ?: @""];
                }
                responseData = [strongSelf rewrittenPlaylistDataFromData:responseData responseURL:playbackURL];
                // Hand AVPlayer an explicitly non-cacheable response for this
                // playlist so it re-requests instead of reusing this response.
                // A/B: the rebuilt-response path caused AVFoundation -12881
                // rejects right after healthy segment deliveries; keep it
                // launch-arg opt-in until proven safe.
                if ([NSUserDefaults.standardUserDefaults boolForKey:@"PlaylistNoCacheResponseEnabled"]) {
                    [strongSelf attachNoCacheResponseToLoadingRequest:loadingRequest response:httpResponse data:responseData];
                }
            } else {
                // Diagnostic: first few segment responses, with leading bytes,
                // to trace -12881 rejects (TS sniff / redirect regressions).
                static NSInteger sSegmentDiagCount = 0;
                if (sSegmentDiagCount < 5) {
                    sSegmentDiagCount += 1;
                    UInt8 head[4] = {0, 0, 0, 0};
                    [responseData getBytes:head length:MIN((NSUInteger)4, responseData.length)];
                    [strongSelf log:@"segment status=%ld bytes=%lu head=%02x%02x%02x%02x ct=%@ range=%lld/%lld@%lld contentRange=%@ url=%@",
                     (long)statusCode,
                     (unsigned long)responseData.length,
                     head[0], head[1], head[2], head[3],
                     httpResponse.MIMEType ?: @"-",
                     (long long)loadingRequest.dataRequest.requestedOffset,
                     (long long)loadingRequest.dataRequest.requestedLength,
                     (long long)loadingRequest.dataRequest.currentOffset,
                     [httpResponse valueForHTTPHeaderField:@"Content-Range"] ?: @"-",
                     playbackURL.absoluteString ?: @""];
                }

                // The new stream source answers full media segments with 206 +
                // Content-Range (plus a malformed Cache-Control tail) after a
                // redirect to a signed storage URL; AVPlayer rejects that
                // wrapper with -12881 even though the TS body is valid, so
                // normalize the wrapper to 200 for complete segments. A 206
                // whose Content-Range proves a partial window is a truncated
                // body: fail with NSURLErrorCannotOpenResource so AVPlayer
                // re-requests instead of parsing it.
                if (statusCode == 206) {
                    if ([strongSelf responseIndicatesPartialContentRange:httpResponse]) {
                        [strongSelf log:@"segment 206 partial contentRange=%@ url=%@",
                         [httpResponse valueForHTTPHeaderField:@"Content-Range"] ?: @"-",
                         playbackURL.absoluteString ?: @""];
                        NSError *truncatedError = [NSError errorWithDomain:NSURLErrorDomain code:kBrowserNativeVideoURLErrorCannotOpenResource userInfo:@{
                            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Truncated 206 media segment: %@", [httpResponse valueForHTTPHeaderField:@"Content-Range"] ?: @""]
                        }];
                        [loadingRequest finishLoadingWithError:truncatedError];
                        return;
                    }
                    [strongSelf attachNormalizedSegmentResponseToLoadingRequest:loadingRequest response:httpResponse data:responseData];
                }
            }

            [strongSelf fillContentInfoForLoadingRequest:loadingRequest response:httpResponse data:responseData requestURL:playbackURL];
            NSData *dataForRequest = [strongSelf responseDataForLoadingRequest:loadingRequest data:responseData];
            if (dataForRequest.length > 0) {
                [loadingRequest.dataRequest respondWithData:dataForRequest];
            }
            [loadingRequest finishLoading];
        });
    }];

    [self.taskByLoadingRequest setObject:task forKey:loadingRequest];
    [task resume];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    __unused AVAssetResourceLoader *unusedResourceLoader = resourceLoader;
    NSURL *requestURL = loadingRequest.request.URL;
    NSURL *playbackURL = [self playbackURLFromAssetURL:requestURL];
    if (playbackURL == nil) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
        [loadingRequest finishLoadingWithError:error];
        return NO;
    }

    [self startTaskForURL:playbackURL loadingRequest:loadingRequest allowMasterRewrite:YES];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    __unused AVAssetResourceLoader *unusedResourceLoader = resourceLoader;
    NSURLSessionDataTask *task = [self.taskByLoadingRequest objectForKey:loadingRequest];
    [task cancel];
    [self.taskByLoadingRequest removeObjectForKey:loadingRequest];
}

@end
