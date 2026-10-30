#import "BrowserVideoPlaybackCoordinator.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserWebView.h"
#import "BrowserYouTubeExtractor.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
// Used when the user hasn't set a custom UA: playlist CDNs in the streameast
// family 403 non-browser clients, and this UA is verified to fetch their
// media playlists and segments.
static NSString * const kBrowserPlaylistFallbackUserAgent = @"Mozilla/5.0 (Apple TV; U; CPU AppleTV like Mac OS X like Mac OS X; en-us) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/605.1.15";
static BOOL const kBrowserYouTubeNativeExtractionEnabled = NO;

@interface BrowserVideoPlaybackCoordinator ()

@property (nonatomic, weak) id<BrowserVideoPlaybackCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserYouTubeExtractor *youTubeExtractor;
// YES between a force-present (which pauses the page's own media) and the
// native player's dismissal; pause bookkeeping only — the page-playback
// restore on dismissal runs regardless of this flag.
@property (nonatomic) BOOL pageMediaPausedForNativePlayer;

// Shared presentation tail. subtitleFrameKey: the probe-frame key of the
// report that selected the video; when set, page subtitles are captured
// on-demand for that frame before the player is presented. presentationHost:
// the page URL's host, forwarded to the player for subtitle cue sizing.
- (void)forcePresentNativeVideoPlayerForURL:(NSURL *)URL
                                      title:(NSString *)title
                             requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                                    cookies:(NSArray<NSHTTPCookie *> *)cookies
                  candidateMasterPlaylistURLs:(NSArray<NSURL *> *)candidateMasterPlaylistURLs
                            subtitleFrameKey:(NSString *)subtitleFrameKey
                            presentationHost:(nullable NSString *)presentationHost;

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
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleNativeVideoPlayerDidDismissNotification:)
                                                     name:kBrowserNativeVideoPlayerDidDismissNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

    // A blob:/MSE src won't open in AVPlayer; nativePlayableURLStringFromVideoInfo
    // falls back to the playlist URLs the media-engine user script captured inside
    // the page (carried on the fullscreen payload).
    NSString *playableURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:playableURLString]) {
        // Blob/MSE source AVPlayer can't open: stay in the page, expanded via CSS.
        NSLog(@"[NativeVideoPlayer] page fullscreen request without playable URL (src=%@), using CSS fallback", src ?: @"");
        [self.host.browserWebView evaluateJavaScriptStringAsync:@"window.__browserApplyCssFullscreen && window.__browserApplyCssFullscreen();"];
        return;
    }

    NSURL *videoURL = [NSURL URLWithString:playableURLString];
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
    // Explicit user request: bypasses the Full Screen Player preference.
    NSDictionary<NSString *, NSString *> *requestHeaders = nil;
    if ([self isHLSPlaylistURL:videoURL]) {
        requestHeaders = [self browserHeadersForPlaylistURL:videoURL videoInfo:videoInfo];
    }
    [self forcePresentNativeVideoPlayerForURL:videoURL title:title requestHeaders:requestHeaders cookies:nil];
}

- (BOOL)playVideoUnderCursorIfAvailable {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return YES;
    }

    UIViewController *presentedViewController = self.host.browserPresentedViewController;
    if (!self.host.browserIsCursorModeEnabled ||
        (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]])) {
        return YES;
    }

    NSURL *pageURL = self.host.browserWebView.request.URL;
    CGPoint point = self.host.browserDOMCursorPoint;
    NSDictionary *videoInfo = [self.domInteractionService videoInfoAtDOMPoint:point
                                                                       webView:self.host.browserWebView];
    if (kBrowserYouTubeNativeExtractionEnabled && [[self youTubeExtractor] canExtractFromPageURL:pageURL]) {
        [self playYouTubeVideoAtPageURL:pageURL fallbackVideoInfo:videoInfo];
        return YES;
    }

    NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:videoURLString] &&
        [self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        NSDictionary *activatedVideoInfo = [self.domInteractionService activateVideoTargetAtDOMPoint:point
                                                                                              webView:self.host.browserWebView
                                                                                              timeout:1.5];
        if (activatedVideoInfo.count > 0) {
            videoInfo = activatedVideoInfo;
            videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
        }
    }

    if (![self isNativePlayableVideoURLString:videoURLString]) {
        // Nothing playable under the cursor (typical for the cross-origin
        // player iframes): let the caller try the per-frame media probes.
        return NO;
    }

    NSURL *videoURL = [NSURL URLWithString:videoURLString];
    NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : self.host.browserCurrentPageTitle;
    [self presentNativeVideoPlayerForURL:videoURL title:title videoInfo:videoInfo];
    return YES;
}

// Pick the best candidate inside one media-probe report (one frame). Order:
// playlist-looking video src/currentSrc > playlist-looking captured URL >
// any AVPlayer-openable video src > any captured http(s) URL.
- (NSDictionary *)bestMediaProbeCandidateFromReport:(NSDictionary *)report {
    if (![report isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *pageURLString = [report[@"pageURL"] isKindOfClass:[NSString class]] ? report[@"pageURL"] : nil;
    NSArray *videos = [report[@"videos"] isKindOfClass:[NSArray class]] ? report[@"videos"] : @[];
    NSArray *captured = [report[@"captured"] isKindOfClass:[NSArray class]] ? report[@"captured"] : @[];

    for (id videoObject in videos) {
        if (![videoObject isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *title = [((NSDictionary *)videoObject)[@"title"] isKindOfClass:[NSString class]] ? ((NSDictionary *)videoObject)[@"title"] : @"";
        for (NSString *key in @[@"currentSrc", @"src"]) {
            id sourceValue = ((NSDictionary *)videoObject)[key];
            NSString *source = [sourceValue isKindOfClass:[NSString class]] ? sourceValue : nil;
            if ([self isNativePlayableVideoURLString:source] && [self isHLSPlaylistURL:[NSURL URLWithString:source]]) {
                return @{@"url": source, @"title": title, @"pageURL": pageURLString ?: @""};
            }
        }
    }

    for (id capturedValue in captured) {
        if (![capturedValue isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *capturedURLString = (NSString *)capturedValue;
        if ([self isNativePlayableVideoURLString:capturedURLString] && [self isHLSPlaylistURL:[NSURL URLWithString:capturedURLString]]) {
            return @{@"url": capturedURLString, @"title": @"", @"pageURL": pageURLString ?: @""};
        }
    }

    for (id videoObject in videos) {
        if (![videoObject isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *title = [((NSDictionary *)videoObject)[@"title"] isKindOfClass:[NSString class]] ? ((NSDictionary *)videoObject)[@"title"] : @"";
        for (NSString *key in @[@"currentSrc", @"src"]) {
            id sourceValue = ((NSDictionary *)videoObject)[key];
            NSString *source = [sourceValue isKindOfClass:[NSString class]] ? sourceValue : nil;
            if ([self isNativePlayableVideoURLString:source]) {
                return @{@"url": source, @"title": title, @"pageURL": pageURLString ?: @""};
            }
        }
    }

    for (id capturedValue in captured) {
        if (![capturedValue isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *capturedURLString = (NSString *)capturedValue;
        if ([self isNativePlayableVideoURLString:capturedURLString]) {
            return @{@"url": capturedURLString, @"title": @"", @"pageURL": pageURLString ?: @""};
        }
    }

    return nil;
}

// Master playlists the probes captured (load-playlist-multi family), oldest
// first so the asset loader can scan newest-last when a media playlist 403s:
// the CDN rotates hosts, and a captured master is fresher than the one the
// player was presented with.
- (NSArray<NSURL *> *)candidateMasterPlaylistURLsFromReports:(NSArray<NSDictionary *> *)reports {
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    for (NSDictionary *report in [reports reverseObjectEnumerator]) { // oldest first
        NSArray *captured = [report[@"captured"] isKindOfClass:[NSArray class]] ? report[@"captured"] : @[];
        for (id capturedValue in captured) {
            if (![capturedValue isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *capturedURLString = (NSString *)capturedValue;
            NSString *lowercaseURLString = capturedURLString.lowercaseString;
            if (![lowercaseURLString containsString:@"/playlist/"] || ![lowercaseURLString containsString:@"load-playlist"]) {
                continue;
            }
            if ([seen containsObject:capturedURLString]) {
                continue;
            }
            NSURL *URL = [NSURL URLWithString:capturedURLString];
            if (URL == nil) {
                continue;
            }
            [seen addObject:capturedURLString];
            [candidates addObject:URL];
        }
    }
    return candidates;
}

- (void)presentNativePlayerFromMediaProbes {
    // Explicit user-facing entry point (Play/Pause HOLD takeover, cursor-play
    // fallback, "Play full screen" alert, player Retry): while the native
    // player owns playback the page's probe script stops reporting, so right
    // after Menu hands playback back to the page every candidate is older
    // than the auto path's 10s window; device evidence showed the probe goes
    // silent for the whole native playback session, so even 60s was too
    // strict and a tight filter would silently fail the manual re-entry the
    // user just asked for.
    if ([self presentNativePlayerFromMediaProbesSilentlyAllowingReportAge:600.0]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Native Video Unavailable"
                                                                            message:@"Hold again after the page has loaded a video."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (BOOL)presentNativePlayerFromMediaProbesSilently {
    // Automatic path (no explicit user gesture: the embed watchdog's
    // auto-fullscreen, the forced-presentation retries): only a report from
    // within the last 10s proves the embed is playing right now, so a stale
    // one must not fire an unsolicited takeover.
    return [self presentNativePlayerFromMediaProbesSilentlyAllowingReportAge:10.0];
}

- (BOOL)presentNativePlayerFromMediaProbesSilentlyAllowingReportAge:(NSTimeInterval)age {
    NSArray<NSDictionary *> *reports = [self.host.browserWebView freshMediaProbeReportsYoungerThan:age];
    NSArray<NSURL *> *candidateMasterPlaylistURLs = [self candidateMasterPlaylistURLsFromReports:reports];
    for (NSDictionary *report in reports) { // newest first
        NSDictionary *candidate = [self bestMediaProbeCandidateFromReport:report];
        if (candidate == nil) {
            continue;
        }
        NSString *candidateURLString = candidate[@"url"];
        NSURL *videoURL = candidateURLString.length > 0 ? [NSURL URLWithString:candidateURLString] : nil;
        if (videoURL == nil) {
            continue;
        }

        NSString *title = [candidate[@"title"] isKindOfClass:[NSString class]] && [candidate[@"title"] length] > 0
            ? candidate[@"title"]
            : self.host.browserCurrentPageTitle;
        // Referer must be the reporting frame's own URL (the embed origin) —
        // the streameast-family CDNs require it for playlists and segments.
        NSString *pageURLString = [candidate[@"pageURL"] isKindOfClass:[NSString class]] ? candidate[@"pageURL"] : nil;
        NSDictionary<NSString *, NSString *> *requestHeaders = [self browserHeadersForPlaylistURL:videoURL
                                                                        videoInfo:(pageURLString.length > 0 ? @{@"pageURL": pageURLString} : @{})];
        // Subtitle capture key: this report's frame in the web view's stored
        // frame-info table (the same host+path key format BrowserWebView uses
        // to stamp probes/frameInfos). Explicit user request: bypasses the Full
        // Screen Player preference, and pauses the page's own media via the
        // force-present path; the presentation itself waits on the (watchdog-
        // capped at 1.5s) on-demand subtitle extraction for this frame.
        NSString *subtitleFrameKey = nil;
        if (pageURLString.length > 0) {
            NSURL *probePageURL = [NSURL URLWithString:pageURLString];
            subtitleFrameKey = probePageURL.host.length > 0
                ? [probePageURL.host stringByAppendingString:probePageURL.path ?: @""]
                : pageURLString;
        }
        [self forcePresentNativeVideoPlayerForURL:videoURL title:title requestHeaders:requestHeaders cookies:nil candidateMasterPlaylistURLs:candidateMasterPlaylistURLs subtitleFrameKey:subtitleFrameKey presentationHost:(pageURLString.length > 0 ? [NSURL URLWithString:pageURLString].host : nil)];
        NSLog(@"[NativeVideoPlayer] media probe presented url=%@ frame=%@", candidateURLString, pageURLString ?: @"");
        // The web view stamps each stored report with its receive time
        // (kBrowserMediaProbeTimestampKey in BrowserWebView.m, kept in the
        // returned payload). A takeover on a report the auto path would have
        // rejected is the manual re-entry this widened window exists for —
        // log its age for postmortems of the back-and-forth flow.
        NSDate *reportedAt = [report[@"_mediaProbeTimestamp"] isKindOfClass:[NSDate class]] ? report[@"_mediaProbeTimestamp"] : nil;
        if (reportedAt != nil) {
            NSTimeInterval reportAge = -[reportedAt timeIntervalSinceNow];
            if (reportAge > 10.0) {
                NSLog(@"[NativeVideoPlayer] manual takeover from aged probe (age=%.0fs)", reportAge);
            }
        }
        return YES;
    }

    return NO;
}

- (BOOL)handleSelectPressForVideoAtCursor {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return NO;
    }

    CGPoint point = self.host.browserDOMCursorPoint;
    if ([self.domInteractionService isVideoDismissTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        return NO;
    }

    NSDictionary *directVideoInfo = [self.domInteractionService directVideoInfoAtDOMPoint:point
                                                                                   webView:self.host.browserWebView];
    NSString *directVideoURLString = [self nativePlayableURLStringFromVideoInfo:directVideoInfo];
    if ([self isNativePlayableVideoURLString:directVideoURLString]) {
        NSURL *videoURL = [NSURL URLWithString:directVideoURLString];
        NSString *title = [directVideoInfo[@"title"] isKindOfClass:[NSString class]] ? directVideoInfo[@"title"] : self.host.browserCurrentPageTitle;
        [self presentNativeVideoPlayerForURL:videoURL title:title videoInfo:directVideoInfo];
        return YES;
    }

    if (![self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        return NO;
    }

    NSDictionary *videoInfo = [self.domInteractionService primedVideoInfoAtDOMPoint:point webView:self.host.browserWebView];
    if (videoInfo.count == 0) {
        videoInfo = [self.domInteractionService videoInfoAtDOMPoint:point webView:self.host.browserWebView];
    }

    NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:videoURLString]) {
        NSDictionary *activatedVideoInfo = [self.domInteractionService activateVideoTargetAtDOMPoint:point
                                                                                              webView:self.host.browserWebView
                                                                                              timeout:1.5];
        if (activatedVideoInfo.count > 0) {
            videoInfo = activatedVideoInfo;
            videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
        }
    }

    if ([self isNativePlayableVideoURLString:videoURLString]) {
        NSURL *videoURL = [NSURL URLWithString:videoURLString];
        NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : self.host.browserCurrentPageTitle;
        [self presentNativeVideoPlayerForURL:videoURL title:title videoInfo:videoInfo];
    } else {
        [self presentUnsupportedNativeVideoAlertForVideoInfo:videoInfo ?: @{}];
    }
    return YES;
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

    NSArray *capturedMedia = [videoInfo[@"capturedMedia"] isKindOfClass:[NSArray class]] ? videoInfo[@"capturedMedia"] : @[];
    for (id capturedValue in capturedMedia) {
        if (![capturedValue isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *capturedURLString = (NSString *)capturedValue;
        // A playlist URL captured from the page's own network traffic beats a
        // blob:/MSE src that AVPlayer can't open.
        if ([self isNativePlayableVideoURLString:capturedURLString]) {
            return capturedURLString;
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

// Playlist endpoints of the streameast family: an .m3u8 path or a
// /playlist/ path. Their CDN 403s media playlists and segments unless the
// request carries a browser-like User-Agent and a Referer, so every native
// player presentation of such a URL must go through browserHeadersForPlaylistURL.
- (BOOL)isHLSPlaylistURL:(NSURL *)URL {
    if (URL == nil) {
        return NO;
    }

    NSString *lowercasePath = URL.path.lowercaseString;
    if (lowercasePath.length == 0) {
        return NO;
    }

    return [lowercasePath hasSuffix:@".m3u8"] || [lowercasePath containsString:@"/playlist/"];
}

- (NSDictionary<NSString *, NSString *> *)browserHeadersForPlaylistURL:(NSURL *)playlistURL
                                                             videoInfo:(NSDictionary *)videoInfo {
    if (playlistURL == nil) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSString *userAgent = [[NSUserDefaults standardUserDefaults] stringForKey:kUserAgentDefaultsKey];
    headers[@"User-Agent"] = userAgent.length > 0 ? userAgent : kBrowserPlaylistFallbackUserAgent;

    // The embed iframe's own URL (reported by the page) is the exact Referer the
    // CDN accepts; fall back to the web view's current URL when it wasn't sent.
    NSString *pageURLString = [videoInfo[@"pageURL"] isKindOfClass:[NSString class]] ? videoInfo[@"pageURL"] : nil;
    NSURL *pageURL = pageURLString.length > 0 ? [NSURL URLWithString:pageURLString] : nil;
    if (pageURL == nil) {
        pageURL = self.host.browserWebView.request.URL;
    }
    if (pageURL.absoluteString.length > 0) {
        headers[@"Referer"] = pageURL.absoluteString;
    }

    return headers.count > 0 ? headers : nil;
}

// Native takeovers of playlist-like URLs need UA/Referer or the CDN 403s the
// media segments; other URLs keep the plain presentation path. The asset
// loader forwards these headers to every sub-request and rewrites nested
// playlists to the proxy scheme.
- (void)presentNativeVideoPlayerForURL:(NSURL *)URL title:(NSString *)title videoInfo:(NSDictionary *)videoInfo {
    NSDictionary<NSString *, NSString *> *requestHeaders = nil;
    if ([self isHLSPlaylistURL:URL]) {
        requestHeaders = [self browserHeadersForPlaylistURL:URL videoInfo:videoInfo];
    }
    [self presentNativeVideoPlayerForURL:URL title:title requestHeaders:requestHeaders cookies:nil];
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
    [self forcePresentNativeVideoPlayerForURL:URL title:title requestHeaders:requestHeaders cookies:cookies candidateMasterPlaylistURLs:nil];
}

// candidateMasterPlaylistURLs: freshest probe-captured masters of the same
// stream family, handed to the asset loader for 403/404 media-playlist retry.
- (void)forcePresentNativeVideoPlayerForURL:(NSURL *)URL
                                      title:(NSString *)title
                             requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                                    cookies:(NSArray<NSHTTPCookie *> *)cookies
                  candidateMasterPlaylistURLs:(NSArray<NSURL *> *)candidateMasterPlaylistURLs {
    [self forcePresentNativeVideoPlayerForURL:URL
                                        title:title
                               requestHeaders:requestHeaders
                                      cookies:cookies
                  candidateMasterPlaylistURLs:candidateMasterPlaylistURLs
                            subtitleFrameKey:nil
                            presentationHost:nil];
}

// subtitleFrameKey: non-nil only on the media-probe paths — the frame key of
// the probe that selected this video. The page's WebVTT subtitles are captured
// from that frame (kisskh-family sites attach <track> TextTracks the native
// takeover would otherwise lose) and the presentation waits on the completion;
// the extract's 1.5s watchdog caps the takeover delay. nil frame key / empty
// result: presented exactly as before, no overlay. presentationHost: the probe
// page URL's host, forwarded to the player so the cue overlay can size its
// font per host; nil keeps the baseline.
- (void)forcePresentNativeVideoPlayerForURL:(NSURL *)URL
                                      title:(NSString *)title
                             requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                                    cookies:(NSArray<NSHTTPCookie *> *)cookies
                  candidateMasterPlaylistURLs:(NSArray<NSURL *> *)candidateMasterPlaylistURLs
                            subtitleFrameKey:(NSString *)subtitleFrameKey
                            presentationHost:(nullable NSString *)presentationHost {
    if (URL == nil) {
        return;
    }

    [self.host.browserWebView pauseAllMediaPlayback];
    self.pageMediaPausedForNativePlayer = YES;

    BrowserNativeVideoPlayerViewController *playerViewController = [[BrowserNativeVideoPlayerViewController alloc] initWithURL:URL
                                                                                                                          title:title
                                                                                                                  requestHeaders:requestHeaders
                                                                                                                         cookies:cookies
                                                                                       candidateMasterPlaylistURLs:candidateMasterPlaylistURLs];
    // Failure-alert Retry: the player dismisses itself, then we re-present from
    // the freshest probes (stale-playlist protection lives in the asset loader).
    __weak typeof(self) weakSelf = self;
    playerViewController.onRetry = ^{
        [weakSelf presentNativePlayerFromMediaProbes];
    };
    if (subtitleFrameKey.length > 0) {
        [self.host.browserWebView extractSubtitleTracksForFrameKey:subtitleFrameKey completion:^(NSArray<NSDictionary *> *subtitleTracks) {
            // Main thread (extract contract): set before presentation; an
            // empty array keeps the player identical to the no-overlay path.
            playerViewController.subtitleTracks = subtitleTracks;
            playerViewController.subtitlePresentationHost = presentationHost;
            [weakSelf.host browserPresentViewController:playerViewController];
        }];
        return;
    }
    [self.host browserPresentViewController:playerViewController];
}

// The native player's view went away (Menu dismissal, close, ...). The
// force-present path paused the page's own media and nothing else un-pauses
// it, and on the popup ("Play full screen") path the page's media was never
// paused by the app yet the embed still ends up stalled (its live buffer dies
// while the native player owns playback), so attempt the page re-attach on
// every dismissal rather than gating on the pause flag. The short delay lets
// an immediate re-takeover (a hold on Play/Pause right after the Menu press)
// win: that re-presentation re-sets the pause flag below, and the guard for a
// presented player stops this from fighting it. Resuming the page video
// cannot retrigger auto-fullscreen — that path is driven by
// webView:didDetectPlayingEmbedVideoReport:, whose dismissal suppression
// window this same notification opens.
- (void)handleNativeVideoPlayerDidDismissNotification:(NSNotification *)notification {
    (void)notification;
    self.pageMediaPausedForNativePlayer = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.pageMediaPausedForNativePlayer) {
            // A fresh native presentation paused the page's media again: leave it paused.
            return;
        }
        if ([strongSelf.host.browserPresentedViewController isKindOfClass:[BrowserNativeVideoPlayerViewController class]]) {
            return;
        }
        [strongSelf resumeLargestVisiblePageVideo];
        NSLog(@"[NativeVideoPlayer] page playback restored after native dismissal");
    });
    // Second attempt for slow-reloading embeds: the streameast-family iframe
    // reloads its document at dismissal, and 0.75s can land before it is
    // ready to receive the live re-attach, so repeat the guarded resume once
    // more after 6s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.pageMediaPausedForNativePlayer) {
            // A fresh native presentation paused the page's media again: leave it paused.
            return;
        }
        if ([strongSelf.host.browserPresentedViewController isKindOfClass:[BrowserNativeVideoPlayerViewController class]]) {
            return;
        }
        NSLog(@"[NativeVideoPlayer] resume retry (t+6s)");
        [strongSelf resumeLargestVisiblePageVideo];
    });
}

// Find the largest visible <video> in the document the expression runs in
// (the media probes' selection convention) and RE-ATTACH it when it sits
// paused or stalled. The streameast segment edge (video-3segment_*.txt) is
// sometimes dead right at the live boundary for the first seconds after the
// hand-back, so a single reload lands on a dead window and the spinner
// persists: escalate instead — t+0 play() + live-edge seek, t+1.5s and t+4s
// a guarded reload (the live window may have advanced by then), t+9s one
// final reload. All timers are scheduled from the single initial invocation,
// every step is fully try/caught, and the ladder logs nothing from JS. The
// reloads are cheap and idempotent, so a race with a fresh native takeover
// costs at most one harmless extra reload (the ObjC dispatch_after re-checks
// and the presented-player guard cover the rest; no JS-side takeover flag).
// An element still playing healthy is left alone. Then dispatch the same
// self-contained expression directly into the recent probe frames so the
// cross-origin embed iframes the top document cannot see get it too.
// Fire-and-forget: no new UI.
- (void)resumeLargestVisiblePageVideo {
    static NSString *const kResumeLargestVideoScript =
        @"(function(){"
        "var best=null;var bestArea=-1;"
        "try{"
            "var vids=document.querySelectorAll('video');"
            "for(var i=0;i<vids.length;i++){"
                "var v=vids[i];"
                "try{"
                    "var r=v.getBoundingClientRect();"
                    "var w=r.width||0;var h=r.height||0;"
                    "if(w<2||h<2){continue;}"
                    "var area=w*h;"
                    "if(area>bestArea){bestArea=area;best=v;}"
                "}catch(e){}"
            "}"
        "}catch(e){}"
        "if(best===null){return false;}"
        "var v=best;"
        "try{"
            // Still playing with a healthy buffer: leave it alone.
            "if(!(v.paused===true||v.readyState<3)){return false;}"
            // Ladder step 1 (t+0): play and seek to the live edge; the
            // seekable range may still be empty until the playlist resolves.
            "try{"
                "var p=v.play();"
                "if(p&&p.catch){p.catch(function(){});}"
                "if(v.seekable.length){v.currentTime=v.seekable.end(v.seekable.length-1);}"
            "}catch(e){}"
            // Ladder step 2 (t+1.5s): full reload cycle when still paused or
            // without playable data. All later timers start from this single
            // initial invocation.
            "try{setTimeout(function(){"
                "try{"
                    "if(v.paused===true||v.readyState<2){"
                        "v.pause();"
                        "v.load();"
                        "var p=v.play();"
                        "if(p&&p.catch){p.catch(function(){});}"
                    "}"
                "}catch(e){}"
            "},1500);}catch(e){}"
            // Ladder step 3 (t+4s): second reload — the live window may have
            // advanced into a healthy segment by now.
            "try{setTimeout(function(){"
                "try{"
                    "if(v.paused===true||v.readyState<2){"
                        "v.load();"
                        "var p=v.play();"
                        "if(p&&p.catch){p.catch(function(){});}"
                    "}"
                "}catch(e){}"
            "},4000);}catch(e){}"
            // Ladder step 4 (t+9s): third and final reload.
            "try{setTimeout(function(){"
                "try{"
                    "v.load();"
                    "var p=v.play();"
                    "if(p&&p.catch){p.catch(function(){});}"
                "}catch(e){}"
            "},9000);}catch(e){}"
            "return true;"
        "}catch(e){}"
        "return false;"
        "})()";
    // The play target often sits in a cross-origin embed iframe (e.g.
    // gooz.aapmains.net inside streameast.cool): the same self-contained
    // expression evaluated per probe frame reaches those documents too.
    NSUInteger embedFrameCount = [self.host.browserWebView evaluateJavaScriptOnRecentProbeFrames:kResumeLargestVideoScript];
    [self.host.browserWebView evaluateJavaScriptStringAsync:kResumeLargestVideoScript completion:^(id result) {
        BOOL acted = [result isKindOfClass:[NSNumber class]] && [result boolValue];
        NSLog(@"[NativeVideoPlayer] resume dispatched to %lu embed frames (acted=top:%@)", (unsigned long)embedFrameCount, acted ? @"YES" : @"NO");
    }];
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
