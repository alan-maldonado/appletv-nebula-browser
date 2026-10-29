#import "BrowserVideoPlaybackCoordinator.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserWebView.h"
#import "BrowserYouTubeExtractor.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static BOOL const kBrowserYouTubeNativeExtractionEnabled = NO;

@interface BrowserVideoPlaybackCoordinator ()

@property (nonatomic, weak) id<BrowserVideoPlaybackCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserYouTubeExtractor *youTubeExtractor;

@end

@implementation BrowserVideoPlaybackCoordinator

- (BOOL)isFullscreenVideoPlaybackEnabled {
    return self.host.browserFullscreenVideoPlaybackEnabled;
}

- (instancetype)initWithHost:(id<BrowserVideoPlaybackCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
    }
    return self;
}

- (BrowserYouTubeExtractor *)youTubeExtractor {
    if (_youTubeExtractor == nil) {
        _youTubeExtractor = [BrowserYouTubeExtractor new];
    }
    return _youTubeExtractor;
}

// A page fullscreen button was pressed (routed by the fake-fullscreen user
// script). Open our native player when the video exposes a directly playable
// URL; otherwise tell the page to fall back to CSS fullscreen.
- (void)handlePageFullscreenRequestWithInfo:(NSDictionary *)videoInfo {
    NSString *src = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : nil;
    NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : nil;
    NSTimeInterval currentTime = [videoInfo[@"time"] respondsToSelector:@selector(doubleValue)] ? [videoInfo[@"time"] doubleValue] : 0.0;

    if (![self isNativePlayableVideoURLString:src]) {
        // Blob/MSE source AVPlayer can't open: stay in the page, expanded via CSS.
        NSLog(@"[NativeVideoPlayer] page fullscreen request without playable URL (src=%@), using CSS fallback", src ?: @"");
        [self.host.browserWebView evaluateJavaScriptStringAsync:@"window.__browserApplyCssFullscreen && window.__browserApplyCssFullscreen();"];
        return;
    }

    NSURL *videoURL = [NSURL URLWithString:src];
    if (currentTime >= 30.0 && videoURL.host.length > 0) {
        // Seed the player's resume store so it continues from the page's position
        // (same key format as BrowserNativeVideoPlayerViewController).
        NSString *resumeKey = [NSString stringWithFormat:@"%@://%@%@", videoURL.scheme ?: @"", videoURL.host, videoURL.path ?: @""];
        NSMutableDictionary *positions = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"VideoResumePositions"] mutableCopy] ?: [NSMutableDictionary dictionary];
        positions[resumeKey] = @{ @"position": @(currentTime), @"date": @([NSDate date].timeIntervalSince1970) };
        [[NSUserDefaults standardUserDefaults] setObject:positions forKey:@"VideoResumePositions"];
    }

    if (title.length == 0) {
        title = self.host.browserCurrentPageTitle;
    }
    NSMutableArray<NSDictionary *> *subtitleTracks = [NSMutableArray array];
    NSArray *subtitles = [videoInfo[@"subtitles"] isKindOfClass:[NSArray class]] ? videoInfo[@"subtitles"] : @[];
    for (NSDictionary *subtitle in subtitles) {
        NSString *subtitleSource = [subtitle isKindOfClass:[NSDictionary class]] && [subtitle[@"src"] isKindOfClass:[NSString class]] ? subtitle[@"src"] : nil;
        NSURL *subtitleURL = subtitleSource.length > 0 ? [NSURL URLWithString:subtitleSource] : nil;
        if (subtitleURL.host.length == 0) {
            continue;
        }
        [subtitleTracks addObject:@{
            @"url": subtitleURL,
            @"label": [subtitle[@"label"] isKindOfClass:[NSString class]] ? subtitle[@"label"] : @"",
            @"language": [subtitle[@"language"] isKindOfClass:[NSString class]] ? subtitle[@"language"] : @"",
        }];
    }
    NSInteger subtitleIndex = [videoInfo[@"subtitleIndex"] respondsToSelector:@selector(integerValue)] ? [videoInfo[@"subtitleIndex"] integerValue] : -1;
    if (subtitleIndex >= (NSInteger)subtitleTracks.count) {
        subtitleIndex = -1;
    }

    // Explicit user request: bypasses the Full Screen Player preference.
    BrowserNativeVideoPlayerViewController *playerViewController = [self nativeVideoPlayerForURL:videoURL title:title requestHeaders:nil cookies:nil];
    [playerViewController setSubtitleTracks:subtitleTracks selectedIndex:subtitleIndex];
    [self.host browserPresentViewController:playerViewController];
}

- (void)playVideoUnderCursorIfAvailable {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return;
    }

    UIViewController *presentedViewController = self.host.browserPresentedViewController;
    if (!self.host.browserIsCursorModeEnabled ||
        (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]])) {
        return;
    }

    NSURL *pageURL = self.host.browserWebView.request.URL;
    [self.host browserResolveDOMCursorPointWithCompletion:^(CGPoint point) {
        BrowserWebView *webView = self.host.browserWebView;
        [self.domInteractionService videoInfoAtDOMPoint:point webView:webView completion:^(NSDictionary *videoInfo) {
            if (kBrowserYouTubeNativeExtractionEnabled && [[self youTubeExtractor] canExtractFromPageURL:pageURL]) {
                [self playYouTubeVideoAtPageURL:pageURL fallbackVideoInfo:videoInfo];
                return;
            }

            NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
            if ([self isNativePlayableVideoURLString:videoURLString]) {
                [self presentNativeVideoPlayerOrUnsupportedAlertForVideoInfo:videoInfo];
                return;
            }

            [self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:webView completion:^(BOOL isActivationTarget) {
                if (!isActivationTarget) {
                    [self presentNativeVideoPlayerOrUnsupportedAlertForVideoInfo:videoInfo];
                    return;
                }
                [self.domInteractionService activateVideoTargetAtDOMPoint:point webView:webView timeout:1.5 completion:^(NSDictionary *activatedVideoInfo) {
                    [self presentNativeVideoPlayerOrUnsupportedAlertForVideoInfo:activatedVideoInfo.count > 0 ? activatedVideoInfo : videoInfo];
                }];
            }];
        }];
    }];
}

- (void)handleSelectPressForVideoAtDOMPoint:(CGPoint)point completion:(void (^)(BOOL handled))completion {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        completion(NO);
        return;
    }

    BrowserWebView *webView = self.host.browserWebView;
    [self.domInteractionService isVideoDismissTargetAtDOMPoint:point webView:webView completion:^(BOOL isDismissTarget) {
        if (isDismissTarget) {
            completion(NO);
            return;
        }

        [self.domInteractionService directVideoInfoAtDOMPoint:point webView:webView completion:^(NSDictionary *directVideoInfo) {
            NSString *directVideoURLString = [self nativePlayableURLStringFromVideoInfo:directVideoInfo];
            if ([self isNativePlayableVideoURLString:directVideoURLString]) {
                [self presentNativeVideoPlayerOrUnsupportedAlertForVideoInfo:directVideoInfo];
                completion(YES);
                return;
            }

            [self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:webView completion:^(BOOL isActivationTarget) {
                if (!isActivationTarget) {
                    completion(NO);
                    return;
                }
                // From here the press is a video interaction: report it handled right
                // away so the page click is skipped, and resolve the source in the background.
                completion(YES);
                [self resolveActivatedVideoAtDOMPoint:point webView:webView];
            }];
        }];
    }];
}

- (void)resolveActivatedVideoAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    [self.domInteractionService primedVideoInfoAtDOMPoint:point webView:webView completion:^(NSDictionary *primedVideoInfo) {
        void (^continueWithVideoInfo)(NSDictionary *) = ^(NSDictionary *videoInfo) {
            NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
            if ([self isNativePlayableVideoURLString:videoURLString]) {
                [self presentNativeVideoPlayerOrUnsupportedAlertForVideoInfo:videoInfo];
                return;
            }
            [self.domInteractionService activateVideoTargetAtDOMPoint:point webView:webView timeout:1.5 completion:^(NSDictionary *activatedVideoInfo) {
                [self presentNativeVideoPlayerOrUnsupportedAlertForVideoInfo:activatedVideoInfo.count > 0 ? activatedVideoInfo : videoInfo];
            }];
        };

        if (primedVideoInfo.count > 0) {
            continueWithVideoInfo(primedVideoInfo);
            return;
        }
        [self.domInteractionService videoInfoAtDOMPoint:point webView:webView completion:continueWithVideoInfo];
    }];
}

- (void)presentNativeVideoPlayerOrUnsupportedAlertForVideoInfo:(NSDictionary *)videoInfo {
    NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:videoURLString]) {
        [self presentUnsupportedNativeVideoAlertForVideoInfo:videoInfo ?: @{}];
        return;
    }

    NSURL *videoURL = [NSURL URLWithString:videoURLString];
    NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : self.host.browserCurrentPageTitle;
    [self presentNativeVideoPlayerForURL:videoURL title:title];
}

- (NSString *)nativePlayableURLStringFromVideoInfo:(NSDictionary *)videoInfo {
    NSString *primarySource = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
    if ([self isNativePlayableVideoURLString:primarySource]) {
        return primarySource;
    }

    NSArray *sources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
    for (id sourceValue in sources) {
        if (![sourceValue isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *source = (NSString *)sourceValue;
        if ([self isNativePlayableVideoURLString:source]) {
            return source;
        }
    }

    return primarySource;
}

- (BOOL)isNativePlayableVideoURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return NO;
    }

    NSString *lowercaseURLString = URLString.lowercaseString;
    if ([lowercaseURLString hasPrefix:@"blob:"] ||
        [lowercaseURLString hasPrefix:@"data:"] ||
        [lowercaseURLString hasPrefix:@"mediastream:"]) {
        return NO;
    }

    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return NO;
    }

    NSString *scheme = URL.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

- (void)presentNativeVideoPlayerForURL:(NSURL *)URL title:(NSString *)title {
    [self presentNativeVideoPlayerForURL:URL title:title requestHeaders:nil cookies:nil];
}

- (void)presentNativeVideoPlayerForURL:(NSURL *)URL
                                 title:(NSString *)title
                        requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                               cookies:(NSArray<NSHTTPCookie *> *)cookies {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return;
    }
    [self forcePresentNativeVideoPlayerForURL:URL title:title requestHeaders:requestHeaders cookies:cookies];
}

// Skips the Full Screen Player preference gate: used when the user explicitly
// asked for fullscreen (e.g. the page's own fullscreen button).
- (void)forcePresentNativeVideoPlayerForURL:(NSURL *)URL
                                      title:(NSString *)title
                             requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                                    cookies:(NSArray<NSHTTPCookie *> *)cookies {
    BrowserNativeVideoPlayerViewController *playerViewController = [self nativeVideoPlayerForURL:URL title:title requestHeaders:requestHeaders cookies:cookies];
    if (playerViewController != nil) {
        [self.host browserPresentViewController:playerViewController];
    }
}

// Pauses the page and builds the player; the caller presents it.
- (BrowserNativeVideoPlayerViewController *)nativeVideoPlayerForURL:(NSURL *)URL
                                                               title:(NSString *)title
                                                      requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                                                             cookies:(NSArray<NSHTTPCookie *> *)cookies {
    if (URL == nil) {
        return nil;
    }

    [self.host.browserWebView pauseAllMediaPlayback];

    return [[BrowserNativeVideoPlayerViewController alloc] initWithURL:URL
                                                                 title:title
                                                         requestHeaders:requestHeaders
                                                                cookies:cookies];
}

- (NSDictionary<NSString *, NSString *> *)browserHeadersForYouTubePlaybackURL:(NSURL *)playbackURL
                                                                       pageURL:(NSURL *)pageURL {
    if (playbackURL == nil || pageURL == nil) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSString *userAgent = [[NSUserDefaults standardUserDefaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        headers[@"User-Agent"] = userAgent;
    }

    headers[@"Referer"] = pageURL.absoluteString ?: @"https://www.youtube.com/";
    NSString *origin = [NSString stringWithFormat:@"%@://%@", pageURL.scheme ?: @"https", pageURL.host ?: @"www.youtube.com"];
    headers[@"Origin"] = origin;

    NSArray<NSHTTPCookie *> *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:pageURL];
    if (cookies.count > 0) {
        NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
        NSString *cookieHeader = cookieHeaders[@"Cookie"];
        if (cookieHeader.length > 0) {
            headers[@"Cookie"] = cookieHeader;
        }
    }

    return headers.count > 0 ? headers : nil;
}

- (BOOL)cookie:(NSHTTPCookie *)cookie matchesHost:(NSString *)host {
    if (cookie == nil || host.length == 0) {
        return NO;
    }

    NSString *cookieDomain = cookie.domain.lowercaseString ?: @"";
    NSString *lowercaseHost = host.lowercaseString;
    if (cookieDomain.length == 0) {
        return NO;
    }

    if ([cookieDomain hasPrefix:@"."]) {
        cookieDomain = [cookieDomain substringFromIndex:1];
    }

    return [lowercaseHost isEqualToString:cookieDomain] || [lowercaseHost hasSuffix:[@"." stringByAppendingString:cookieDomain]];
}

- (NSArray<NSHTTPCookie *> *)browserCookiesForYouTubePlaybackURL:(NSURL *)playbackURL
                                                          pageURL:(NSURL *)pageURL {
    NSMutableArray<NSHTTPCookie *> *matchingCookies = [NSMutableArray array];
    NSMutableSet<NSString *> *seenCookieKeys = [NSMutableSet set];
    NSArray<NSHTTPCookie *> *allCookies = [BrowserWebView allCookies];
    NSString *pageHost = pageURL.host.lowercaseString ?: @"";
    NSString *playbackHost = playbackURL.host.lowercaseString ?: @"";

    for (NSHTTPCookie *cookie in allCookies) {
        BOOL matches = [self cookie:cookie matchesHost:pageHost] ||
            [self cookie:cookie matchesHost:playbackHost] ||
            [self cookie:cookie matchesHost:@"youtube.com"] ||
            [self cookie:cookie matchesHost:@"googlevideo.com"];
        if (!matches) {
            continue;
        }

        NSString *cookieKey = [NSString stringWithFormat:@"%@|%@|%@", cookie.domain ?: @"", cookie.path ?: @"", cookie.name ?: @""];
        if ([seenCookieKeys containsObject:cookieKey]) {
            continue;
        }
        [seenCookieKeys addObject:cookieKey];
        [matchingCookies addObject:cookie];
    }

    return matchingCookies;
}

- (void)presentUnsupportedNativeVideoAlertForVideoInfo:(NSDictionary *)videoInfo {
    NSArray *sources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
    NSString *sourceSummary = nil;
    if (sources.count > 0) {
        sourceSummary = [sources componentsJoinedByString:@"\n"];
    } else if (videoInfo.count > 0) {
        sourceSummary = @"No direct media URL was exposed by the page.";
    } else {
        sourceSummary = @"No video element was detected under the cursor.";
    }
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Native Video Unavailable"
                                                                             message:[NSString stringWithFormat:@"This page is not exposing a direct video URL that AVPlayer can open.\n\nDetected sources:\n%@", sourceSummary]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentYouTubeExtractionError:(NSError *)error fallbackVideoInfo:(NSDictionary *)videoInfo {
    NSString *message = error.localizedDescription ?: @"Could not extract a better YouTube playback URL.";
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"YouTube Extraction Failed"
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    NSString *fallbackURLString = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
    if ([self isNativePlayableVideoURLString:fallbackURLString]) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Play Current URL"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURL *fallbackURL = [NSURL URLWithString:fallbackURLString];
            NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : weakSelf.host.browserCurrentPageTitle;
            [weakSelf presentNativeVideoPlayerForURL:fallbackURL title:title];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (void)playYouTubeVideoAtPageURL:(NSURL *)pageURL fallbackVideoInfo:(NSDictionary *)videoInfo {
    __weak typeof(self) weakSelf = self;
    [[self youTubeExtractor] extractPlaybackInfoFromPageURL:pageURL webView:self.host.browserWebView completion:^(BrowserYouTubeExtractionResult *result, NSError *error) {
        if (result.playbackURL != nil) {
            NSString *title = result.title.length > 0 ? result.title : weakSelf.host.browserCurrentPageTitle;
            NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionaryWithDictionary:result.requestHeaders ?: @{}];
            NSDictionary<NSString *, NSString *> *fallbackHeaders = [weakSelf browserHeadersForYouTubePlaybackURL:result.playbackURL pageURL:pageURL];
            [fallbackHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
                if (headers[key].length == 0 && value.length > 0) {
                    headers[key] = value;
                }
            }];

            NSArray<NSHTTPCookie *> *cookies = [weakSelf browserCookiesForYouTubePlaybackURL:result.playbackURL pageURL:pageURL];
            if (cookies.count > 0) {
                NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
                NSString *cookieHeader = cookieHeaders[@"Cookie"];
                if (cookieHeader.length > 0) {
                    headers[@"Cookie"] = cookieHeader;
                }
            }

            [weakSelf presentNativeVideoPlayerForURL:result.playbackURL
                                               title:title
                                      requestHeaders:headers.count > 0 ? headers : nil
                                             cookies:cookies];
            return;
        }

        [weakSelf presentYouTubeExtractionError:error fallbackVideoInfo:videoInfo ?: @{}];
    }];
}

@end
