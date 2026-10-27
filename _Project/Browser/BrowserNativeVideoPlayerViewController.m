#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserNativeVideoAssetLoader.h"
#import "BrowserPreferencesStore.h"

#import <AVFoundation/AVFoundation.h>

NSNotificationName const kBrowserNativeVideoPlayerDidDismissNotification = @"BrowserNativeVideoPlayerDidDismissNotification";
NSNotificationName const kBrowserTestForceSecondPresentNotification = @"BrowserTestForceSecondPresentNotification";

static NSString * const kBrowserNativeVideoPlayerLogPrefix = @"[NativeVideoPlayer]";
static NSString * const kBrowserNativePlayerInputLogPrefix = @"[InputTrace][NativePlayer]";
static NSString * const kBrowserVideoResumePositionsDefaultsKey = @"VideoResumePositions";
static NSUInteger const kBrowserVideoResumeMaxEntries = 50;
// No resume near the start (not worth it) or near the end (counts as watched).
static NSTimeInterval const kBrowserVideoResumeEdgeMargin = 30.0;
// User-confirmed failure retries allowed per player presentation.
static NSUInteger const kBrowserNativePlayerMaxFailureRetries = 2;

static NSString *BrowserNativePlayerPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserNativePlayerPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

// Plain-AVURLAsset mode (Tanghulu-style): keeps every header the current code
// already assembles except Origin, which the segment storage hosts of the
// streameast family 404 on sight (curl-proven), and empty-value entries that
// AVFoundation's option parsing has no use for.
static NSDictionary<NSString *, NSString *> *BrowserPlainPlaybackHeaderFields(NSDictionary<NSString *, NSString *> *headers) {
    NSMutableDictionary<NSString *, NSString *> *clean = [NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        if ([key caseInsensitiveCompare:@"Origin"] == NSOrderedSame) {
            return;
        }
        if (![value isKindOfClass:[NSString class]] || value.length == 0) {
            return;
        }
        clean[key] = value;
    }];
    return clean;
}

// ============================================================================
// Page-captured WebVTT subtitle overlay (kisskh & generic <track> sites).
// Rendered over the AVPlayerViewController's contentOverlayView: picks one
// captured track, shows the cue covering the playhead time (when the cues
// came as raw <track> srcs, fetches and parses the VTT/SRT first), and never
// intercepts touches.
// ============================================================================

// One parsed subtitle cue, times in seconds.
@interface BrowserSubtitleCue : NSObject
@property (nonatomic, assign) NSTimeInterval cueStart;
@property (nonatomic, assign) NSTimeInterval cueEnd;
@property (nonatomic, copy) NSString *text;
@end

@implementation BrowserSubtitleCue
@end

static NSUInteger const kBrowserSubtitleMaxCues = 3000;

// "00:01:02.500" / "01:02,500" / "62.5" -> seconds. WebVTT omits hours when
// zero and allows dot or comma decimals; SRT is always HH:MM:SS,mmm. Any
// non-numeric token (including cue-position settings, which the caller's
// token charset already excludes) is rejected.
static BOOL BrowserParseSubtitleTimestamp(NSString *rawToken, NSTimeInterval *outSeconds) {
    NSString *token = [rawToken stringByReplacingOccurrencesOfString:@"," withString:@"."];
    if (token.length == 0) {
        return NO;
    }
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3) {
        return NO;
    }
    NSTimeInterval seconds = 0.0;
    for (NSUInteger index = 0; index < parts.count; index++) {
        NSString *part = parts[index];
        BOOL isLast = index + 1 == parts.count;
        NSString *allowed = isLast ? @"0123456789." : @"0123456789";
        if (part.length == 0
            || [part rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:allowed].invertedSet].location != NSNotFound) {
            return NO;
        }
        seconds = seconds * 60.0 + part.doubleValue;
    }
    if (seconds < 0.0) {
        return NO;
    }
    if (outSeconds != NULL) {
        *outSeconds = seconds;
    }
    return YES;
}

static NSRegularExpression *BrowserSubtitleTimingRegex(void) {
    static NSRegularExpression *timingRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timingRegex = [NSRegularExpression regularExpressionWithPattern:@"([0-9][0-9:,.]*)[ \t]*-->[ \t]*([0-9][0-9:,.]*)" options:0 error:NULL];
    });
    return timingRegex;
}

static NSString *BrowserCleanSubtitleCueText(NSString *rawText) {
    static dispatch_once_t onceToken;
    static NSRegularExpression *tagRegex = nil;
    static NSRegularExpression *braceRegex = nil;
    dispatch_once(&onceToken, ^{
        tagRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:NULL];
        braceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}]*\\}" options:0 error:NULL];
    });
    NSString *cleaned = [tagRegex stringByReplacingMatchesInString:rawText options:0 range:NSMakeRange(0, rawText.length) withTemplate:@""];
    cleaned = [braceRegex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@""];
    return [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// WebVTT and SRT share one parser: the WEBVTT header is optional, NOTE /
// STYLE / REGION blocks (until their blank line) are skipped, timing lines
// accept both timestamp dialects, the remainder of a cue block is the text
// (multi-line cues joined), and the cue count is capped.
static NSArray<BrowserSubtitleCue *> *BrowserParseSubtitleText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @[];
    }
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    if ([normalized hasPrefix:@"\uFEFF"]) {
        normalized = [normalized substringFromIndex:1];
    }
    NSMutableArray<BrowserSubtitleCue *> *cues = [NSMutableArray array];
    NSMutableString *pendingText = [NSMutableString string];
    __block NSTimeInterval pendingStart = 0.0;
    __block NSTimeInterval pendingEnd = 0.0;
    BOOL inCue = NO;
    BOOL inSkipBlock = NO;
    void (^commitCue)(void) = ^{
        if (pendingStart <= pendingEnd) {
            NSString *cueText = BrowserCleanSubtitleCueText(pendingText);
            if (cueText.length > 0 && cues.count < kBrowserSubtitleMaxCues) {
                BrowserSubtitleCue *cue = [BrowserSubtitleCue new];
                cue.cueStart = pendingStart;
                cue.cueEnd = pendingEnd;
                cue.text = cueText;
                [cues addObject:cue];
            }
        }
        [pendingText setString:@""];
    };
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!inCue) {
            if ([trimmed hasPrefix:@"WEBVTT"]) {
                continue;
            }
            if ([trimmed hasPrefix:@"NOTE"] || [trimmed hasPrefix:@"STYLE"] || [trimmed hasPrefix:@"REGION"]) {
                inSkipBlock = YES;
                continue;
            }
            if (inSkipBlock) {
                if (trimmed.length == 0) {
                    inSkipBlock = NO;
                }
                continue;
            }
            NSTextCheckingResult *match = [BrowserSubtitleTimingRegex() firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
            if (match != nil && match.numberOfRanges == 3) {
                NSTimeInterval start = 0.0;
                NSTimeInterval end = 0.0;
                if (BrowserParseSubtitleTimestamp([trimmed substringWithRange:[match rangeAtIndex:1]], &start)
                    && BrowserParseSubtitleTimestamp([trimmed substringWithRange:[match rangeAtIndex:2]], &end)) {
                    inCue = YES;
                    pendingStart = start;
                    pendingEnd = end;
                    [pendingText setString:@""];
                }
            }
            // SRT sequence numbers / VTT cue ids and any other line: ignored.
            continue;
        }
        if (trimmed.length == 0) {
            commitCue();
            inCue = NO;
        } else {
            if (pendingText.length > 0) {
                [pendingText appendString:@"\n"];
            }
            [pendingText appendString:trimmed];
        }
        if (cues.count >= kBrowserSubtitleMaxCues) {
            break;
        }
    }
    if (inCue && cues.count < kBrowserSubtitleMaxCues) {
        commitCue(); // file without a trailing blank line
    }
    [cues sortUsingComparator:^NSComparisonResult(BrowserSubtitleCue *a, BrowserSubtitleCue *b) {
        return a.cueStart < b.cueStart ? NSOrderedAscending : (a.cueStart > b.cueStart ? NSOrderedDescending : NSOrderedSame);
    }];
    return cues;
}

// JS-captured cue dicts ({s, e, t} times in ms, text already tag-stripped)
// -> sorted cue models.
static NSArray<BrowserSubtitleCue *> *BrowserSubtitleCuesFromDictionaries(NSArray<NSDictionary *> *cueDictionaries) {
    if (![cueDictionaries isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<BrowserSubtitleCue *> *cues = [NSMutableArray array];
    for (id cueDictionary in cueDictionaries) {
        if (cues.count >= kBrowserSubtitleMaxCues) {
            break;
        }
        if (![cueDictionary isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id startValue = ((NSDictionary *)cueDictionary)[@"s"];
        id endValue = ((NSDictionary *)cueDictionary)[@"e"];
        id textValue = ((NSDictionary *)cueDictionary)[@"t"];
        if (![startValue respondsToSelector:@selector(doubleValue)]
            || ![endValue respondsToSelector:@selector(doubleValue)]
            || ![textValue isKindOfClass:[NSString class]]
            || [(NSString *)textValue length] == 0) {
            continue;
        }
        BrowserSubtitleCue *cue = [BrowserSubtitleCue new];
        cue.cueStart = [startValue doubleValue] / 1000.0;
        cue.cueEnd = [endValue doubleValue] / 1000.0;
        cue.text = textValue;
        [cues addObject:cue];
    }
    [cues sortUsingComparator:^NSComparisonResult(BrowserSubtitleCue *a, BrowserSubtitleCue *b) {
        return a.cueStart < b.cueStart ? NSOrderedAscending : (a.cueStart > b.cueStart ? NSOrderedDescending : NSOrderedSame);
    }];
    return cues;
}

@interface BrowserSubtitleOverlayView : UIView

// requestHeaders: the media-request header policy (UA + Referer, no Origin)
// used for raw <track> src fetches.
- (instancetype)initWithSubtitleTracks:(NSArray<NSDictionary *> *)subtitleTracks
                                player:(nullable AVPlayer *)player
                        requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders NS_DESIGNATED_INITIALIZER;
- (void)stopTimeObserving;

- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

@interface BrowserSubtitleOverlayView () <NSURLSessionDataDelegate>

@property (nonatomic, strong) UILabel *cueLabel;
@property (nonatomic, copy) NSArray<BrowserSubtitleCue *> *cues;
@property (nonatomic, copy) NSString *appliedCueText; // state guard: label only relayouts on text change
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, weak) AVPlayer *observedPlayer;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, strong) NSURLSession *fetchSession;

@end

@implementation BrowserSubtitleOverlayView

- (instancetype)initWithSubtitleTracks:(NSArray<NSDictionary *> *)subtitleTracks
                                player:(AVPlayer *)player
                        requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _requestHeaders = [requestHeaders copy] ?: @{};
        self.userInteractionEnabled = NO;

        _cueLabel = [UILabel new];
        _cueLabel.numberOfLines = 3;
        _cueLabel.font = [UIFont boldSystemFontOfSize:26.0];
        _cueLabel.textColor = UIColor.whiteColor;
        _cueLabel.textAlignment = NSTextAlignmentCenter;
        // Effectively none, but a nearly-invisible backdrop measurably improves
        // readability over bright video.
        _cueLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.004];
        _cueLabel.layer.shadowColor = UIColor.blackColor.CGColor;
        _cueLabel.layer.shadowOpacity = 1.0;
        _cueLabel.layer.shadowOffset = CGSizeMake(1.0, -1.0);
        _cueLabel.text = @"";
        [self addSubview:_cueLabel];

        // Best track: first mode == "showing", else first with cues, else first.
        NSDictionary *track = nil;
        NSDictionary *firstWithCues = nil;
        NSDictionary *firstValid = nil;
        for (id candidate in subtitleTracks) {
            if (![candidate isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            if (firstValid == nil) {
                firstValid = candidate;
            }
            NSString *mode = [candidate[@"mode"] isKindOfClass:[NSString class]] ? candidate[@"mode"] : @"";
            if ([mode isEqualToString:@"showing"]) {
                track = candidate;
                break;
            }
            NSArray *cueDictionaries = [candidate[@"cues"] isKindOfClass:[NSArray class]] ? candidate[@"cues"] : nil;
            if (firstWithCues == nil && cueDictionaries.count > 0) {
                firstWithCues = candidate;
            }
        }
        if (track == nil) {
            track = firstWithCues ?: firstValid;
        }

        NSArray *cueDictionaries = [track[@"cues"] isKindOfClass:[NSArray class]] ? track[@"cues"] : nil;
        NSString *src = [track[@"src"] isKindOfClass:[NSString class]] ? track[@"src"] : nil;
        if (cueDictionaries.count > 0) {
            _cues = BrowserSubtitleCuesFromDictionaries(cueDictionaries);
        } else if (src.length > 0) {
            _cues = @[]; // applied when the fetch lands
            [self fetchSubtitleTextFromSrc:src];
        } else {
            _cues = @[];
        }

        _observedPlayer = player;
        if (player != nil) {
            __weak typeof(self) weakSelf = self; // weak proxy: the player owns the block
            _timeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, NSEC_PER_SEC)
                                                                 queue:dispatch_get_main_queue()
                                                           usingBlock:^(CMTime time) {
                [weakSelf cueTimeChanged:CMTimeGetSeconds(time)];
            }];
        }
    }
    return self;
}

- (void)fetchSubtitleTextFromSrc:(NSString *)src {
    NSURL *URL = [NSURL URLWithString:src];
    if (URL == nil) {
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 10.0;
    [self applyRequestHeadersToRequest:request];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 10.0;
    self.fetchSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    __weak typeof(self) weakSelf = self;
    [[self.fetchSession dataTaskWithRequest:request completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSString *text = nil; // delegate queue: parse off-main
        if (data.length > 0) {
            text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        NSArray<BrowserSubtitleCue *> *cues = BrowserParseSubtitleText(text);
        NSLog(@"[Subs] fetched src=%@ cues=%lu", URL.lastPathComponent ?: @"", (unsigned long)cues.count);
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.cues = cues; // applied by the next periodic tick
        });
        [strongSelf.fetchSession finishTasksAndInvalidate];
    }] resume];
}

// NSURLSession strips custom header fields on redirect requests: rebuild the
// followed request with the same media policy (UA + Referer, no Origin).
- (void)applyRequestHeadersToRequest:(NSMutableURLRequest *)request {
    [self.requestHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
}

- (void)URLSession:(__unused NSURLSession *)session
              task:(__unused NSURLSessionTask *)task
willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)newRequest
 completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    NSMutableURLRequest *request = [newRequest mutableCopy];
    [self applyRequestHeadersToRequest:request];
    completionHandler(request);
}

- (void)cueTimeChanged:(NSTimeInterval)time {
    if (self.cues.count == 0) {
        return;
    }
    NSString *text = [self cueTextAtTime:time];
    if (self.appliedCueText != nil && [self.appliedCueText isEqualToString:text]) {
        return; // no text change: skip the label's layout churn
    }
    self.appliedCueText = text;
    self.cueLabel.text = text;
    [self setNeedsLayout];
}

// Cues are start-sorted: binary-search the first cue starting after time, then
// walk back a few to catch a long cue still on screen.
- (NSString *)cueTextAtTime:(NSTimeInterval)time {
    NSArray<BrowserSubtitleCue *> *cues = self.cues;
    NSUInteger low = 0;
    NSUInteger high = cues.count;
    while (low < high) {
        NSUInteger mid = (low + high) / 2;
        if (cues[mid].cueStart <= time) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    NSUInteger index = low;
    NSUInteger scanned = 0;
    while (index > 0 && scanned < 8) {
        index--;
        BrowserSubtitleCue *cue = cues[index];
        if (cue.cueStart <= time && time <= cue.cueEnd) {
            return cue.text;
        }
        scanned++;
    }
    return @"";
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (width <= 0.0 || height <= 0.0) {
        return;
    }
    CGFloat labelWidth = width * 0.86;
    self.cueLabel.preferredMaxLayoutWidth = labelWidth;
    CGSize fitting = [self.cueLabel sizeThatFits:CGSizeMake(labelWidth, CGFLOAT_MAX)];
    CGFloat lineHeight = ceil(self.cueLabel.font.lineHeight);
    CGFloat labelHeight = MIN(MAX(ceil(fitting.height), lineHeight), lineHeight * (CGFloat)self.cueLabel.numberOfLines + 4.0);
    CGFloat labelY = height - height * 0.07 - labelHeight;
    self.cueLabel.frame = CGRectMake((width - labelWidth) / 2.0, labelY, labelWidth, labelHeight);
}

// The overlay is cue paint only: never steal touches/focus from the player.
- (UIView *)hitTest:(CGPoint)point withEvent:(__unused UIEvent *)event {
    (void)point;
    return nil;
}

- (void)stopTimeObserving {
    if (self.timeObserver != nil) {
        [self.observedPlayer removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
}

- (void)dealloc {
    [self stopTimeObserving];
    [_fetchSession invalidateAndCancel];
}

@end

@interface BrowserNativeVideoPlayerViewController ()

@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *requestCookies;
@property (nonatomic, copy) NSArray<NSURL *> *candidateMasterPlaylistURLs;
@property (nonatomic, strong) BrowserNativeVideoAssetLoader *assetLoader;

// Custom fast-forward scanning state (1.0 or 0.0 = normal playback, >1.0 = scanning).
// Scanning is emulated: the player is paused and the playhead advances with periodic
// seeks, so it works without having to buffer the stream at Nx speed.
@property (nonatomic, assign) float scanRate;
@property (nonatomic, strong) UILabel *scanRateLabel;
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, assign) NSTimeInterval scanTargetTime;
@property (nonatomic, assign) NSTimeInterval scanOriginTime;
@property (nonatomic, assign) BOOL scanSeekInProgress;

// Seeks are async: while one is in flight, currentTime is stale. Accumulate
// successive skips on the pending target so rapid scrubbing actually advances.
@property (nonatomic, assign) NSTimeInterval pendingSeekTarget;
@property (nonatomic, assign) BOOL hasPendingSeek;

// Scrub/skip exploration session: starts on the first seek, commits on
// play/pause (or after 5s of normal playback); Menu cancels back to its origin.
@property (nonatomic, assign) BOOL seekSessionActive;
@property (nonatomic, assign) NSTimeInterval seekSessionOriginTime;
@property (nonatomic, assign) NSTimeInterval seekSessionLastActivity;

// Our transport bar (AVKit's controls are disabled): progress + elapsed/remaining.
// Persistent while paused, auto-hides shortly after activity while playing.
@property (nonatomic, strong) UIView *positionHUDView;
@property (nonatomic, strong) UILabel *positionHUDTitleLabel;
@property (nonatomic, strong) UILabel *positionHUDLabel;
@property (nonatomic, strong) UILabel *positionHUDRemainingLabel;
@property (nonatomic, strong) UIProgressView *positionHUDBufferProgress;
@property (nonatomic, strong) UIProgressView *positionHUDProgress;
@property (nonatomic, strong) NSTimer *positionHUDHideTimer;
@property (nonatomic, strong) id periodicTimeObserver;

// Page-captured WebVTT subtitle overlay (nil when subtitleTracks is empty).
@property (nonatomic, strong) BrowserSubtitleOverlayView *subtitleOverlayView;

// Resume-where-you-left-off support.
@property (nonatomic, assign) BOOL didAttemptResume;
@property (nonatomic, assign) NSTimeInterval lastResumeSaveTimestamp;

// Load-failure retry alert state.
@property (nonatomic, assign) NSUInteger failureRetryCount;
@property (nonatomic, assign) BOOL failureAlertRechecked;
// YES while the failure alert is up (it lives above the player in the
// presentation chain, so self.presentedViewController cannot guard it).
@property (nonatomic, assign) BOOL failureAlertPresented;

- (BOOL)customTransportEnabled;

@end

@implementation BrowserNativeVideoPlayerViewController

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserNativeVideoPlayerLogPrefix, message);
}

- (instancetype)initWithURL:(NSURL *)URL title:(NSString *)title {
    return [self initWithURL:URL title:title requestHeaders:nil cookies:nil];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies {
    return [self initWithURL:URL title:title requestHeaders:requestHeaders cookies:cookies candidateMasterPlaylistURLs:nil];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies
  candidateMasterPlaylistURLs:(NSArray<NSURL *> *)candidateMasterPlaylistURLs {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _requestCookies = [cookies copy] ?: @[];
        _candidateMasterPlaylistURLs = [candidateMasterPlaylistURLs copy] ?: @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    // AVKit's playback controls are the default (a stalled/failed stream must
    // never leave the user with zero controls); our custom transport UI
    // (FF scanning, scrub HUD) is opt-in via NativePlayerCustomTransportEnabled.
    self.showsPlaybackControls = ![self customTransportEnabled];
    AVPlayerItem *playerItem = nil;
    BOOL loaderDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"NativePlayerLoaderDisabled"];
    if (loaderDisabled) {
        // Tanghulu-style plain AVFoundation native HLS: same header/UA/cookie
        // options as the loader path (minus Origin and empty values), but no
        // resource-loader interception — the loader path fails on these streams
        // (CoreMedia -12881 rejections, Origin-poisoned cross-host redirects).
        NSMutableDictionary *assetOptions = [NSMutableDictionary dictionary];
        NSDictionary<NSString *, NSString *> *plainHeaders = BrowserPlainPlaybackHeaderFields(self.requestHeaders);
        if (plainHeaders.count > 0) {
            assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = plainHeaders;
            NSString *userAgent = self.requestHeaders[@"User-Agent"];
            if (userAgent.length > 0) {
                assetOptions[@"AVURLAssetHTTPUserAgentKey"] = userAgent;
            }
        }
        if (self.requestCookies.count > 0) {
            assetOptions[@"AVURLAssetHTTPCookiesKey"] = self.requestCookies;
        }
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.videoURL options:assetOptions];
        playerItem = [AVPlayerItem playerItemWithAsset:asset];
        [self log:@"player asset mode=plain headers=%lu cookies=%lu", (unsigned long)plainHeaders.count, (unsigned long)self.requestCookies.count];
    } else if (self.requestHeaders.count > 0 || self.requestCookies.count > 0) {
        NSMutableDictionary *assetOptions = [NSMutableDictionary dictionary];
        if (self.requestHeaders.count > 0) {
            assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = self.requestHeaders;
            NSString *userAgent = self.requestHeaders[@"User-Agent"];
            if (userAgent.length > 0) {
                assetOptions[@"AVURLAssetHTTPUserAgentKey"] = userAgent;
            }
        }
        if (self.requestCookies.count > 0) {
            assetOptions[@"AVURLAssetHTTPCookiesKey"] = self.requestCookies;
        }
        self.assetLoader = [[BrowserNativeVideoAssetLoader alloc] initWithRequestHeaders:self.requestHeaders cookies:self.requestCookies];
        self.assetLoader.fresherMasterURLs = self.candidateMasterPlaylistURLs;
        NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:self.videoURL];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
        [self.assetLoader attachToAsset:asset];
        playerItem = [AVPlayerItem playerItemWithAsset:asset];
        [self log:@"player asset mode=loader"];
        [self log:@"using request headers %@ cookies=%lu", self.requestHeaders, (unsigned long)self.requestCookies.count];
    } else {
        playerItem = [AVPlayerItem playerItemWithURL:self.videoURL];
        [self log:@"player asset mode=plain"];
    }
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    [self log:@"created player url=%@", self.videoURL.absoluteString ?: @""];

    __weak typeof(self) weakSelf = self;
    self.periodicTimeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC)
                                                                           queue:dispatch_get_main_queue()
                                                                      usingBlock:^(CMTime time) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // Periodically checkpoint the position so resume works even if the app
        // is killed mid-playback.
        NSTimeInterval uptime = [NSDate timeIntervalSinceReferenceDate];
        if (strongSelf.player.rate > 0.0 && (uptime - strongSelf.lastResumeSaveTimestamp) > 10.0) {
            strongSelf.lastResumeSaveTimestamp = uptime;
            [strongSelf saveResumePosition];
        }
        if (strongSelf.positionHUDView == nil || strongSelf.positionHUDView.hidden) {
            return;
        }
        // Seeks/scanning drive the HUD with their own (virtual) target.
        if (strongSelf.hasPendingSeek || [strongSelf isScanning]) {
            return;
        }
        [strongSelf updatePositionHUDWithTime:CMTimeGetSeconds(time)];
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemDidPlayToEndTime:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:self.player.currentItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:self.player.currentItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemNewErrorLogEntry:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:self.player.currentItem];

    // Page-captured WebVTT subtitles (kisskh-family sites attach <track>
    // TextTracks the native takeover would otherwise lose): render cues
    // time-synced over the video. Nil/empty subtitleTracks: no overlay,
    // player behavior identical.
    if (self.subtitleTracks.count > 0) {
        self.subtitleOverlayView = [[BrowserSubtitleOverlayView alloc] initWithSubtitleTracks:self.subtitleTracks
                                                                                       player:self.player
                                                                               requestHeaders:BrowserPlainPlaybackHeaderFields(self.requestHeaders)];
        self.subtitleOverlayView.frame = self.contentOverlayView.bounds;
        self.subtitleOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.contentOverlayView addSubview:self.subtitleOverlayView];
        [self log:@"subtitle overlay tracks=%lu", (unsigned long)self.subtitleTracks.count];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleFocusUpdate:)
                                                 name:UIFocusDidUpdateNotification
                                               object:nil];

    [self.player.currentItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    if (@available(tvOS 10.0, *)) {
        [self.player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                         context:NULL];
    }

    // Test-only: auto-dismiss the player after N seconds (0 = disabled) so
    // automated runs can measure the full present/dismiss lifecycle.
    NSInteger autoDismissSeconds = [[NSUserDefaults standardUserDefaults] integerForKey:@"NativePresentAutoDismissSeconds"];
    if (autoDismissSeconds > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(autoDismissSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            NSLog(@"%@ auto-dismiss firing (test)", kBrowserNativeVideoPlayerLogPrefix);
            [strongSelf dismissViewControllerAnimated:YES completion:nil];
        });
    }

    // Test-only: N seconds after the FIRST dismissal notification (0 =
    // disabled), post kBrowserTestForceSecondPresentNotification so an
    // automated run can exercise a second presentation.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDidDismissForSecondPresent:)
                                                 name:kBrowserNativeVideoPlayerDidDismissNotification
                                               object:nil];
}

// Fire-once (static, per process): the first dismissal notification schedules
// the second-present test notification; the block holds no self reference as
// the player is typically deallocated right after dismissal.
- (void)handleDidDismissForSecondPresent:(NSNotification *)notification {
    (void)notification;
    static BOOL didScheduleSecondPresent = NO;
    if (didScheduleSecondPresent) {
        return;
    }
    NSInteger secondPresentSeconds = [[NSUserDefaults standardUserDefaults] integerForKey:@"NativePresentSecondPresentSeconds"];
    if (secondPresentSeconds <= 0) {
        return;
    }
    didScheduleSecondPresent = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secondPresentSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"%@ auto-second-present firing (test)", kBrowserNativeVideoPlayerLogPrefix);
        [[NSNotificationCenter defaultCenter] postNotificationName:kBrowserTestForceSecondPresentNotification
                                                            object:nil];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSLog(@"%@ viewDidAppear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewDidAppear play"];
    [self.player play];
}

// contentOverlayView still has zero bounds at viewDidLoad, and autoresizing a
// zero frame never grows it: keep the subtitle overlay pinned to the overlay.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.subtitleOverlayView != nil && !CGRectEqualToRect(self.subtitleOverlayView.frame, self.contentOverlayView.bounds)) {
        self.subtitleOverlayView.frame = self.contentOverlayView.bounds;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewWillDisappear pause"];
    [self.subtitleOverlayView stopTimeObserving];
    [self.subtitleOverlayView removeFromSuperview];
    self.subtitleOverlayView = nil;
    [self saveResumePosition];
    [self stopScanTimer];
    self.scanRate = 1.0f;
    [self.player pause];
    [[NSNotificationCenter defaultCenter] postNotificationName:kBrowserNativeVideoPlayerDidDismissNotification
                                                        object:self];
}

- (void)dealloc {
    [_subtitleOverlayView stopTimeObserving];
    if (self.periodicTimeObserver != nil) {
        [self.player removeTimeObserver:self.periodicTimeObserver];
    }
    [self.scanTimer invalidate];
    [self.positionHUDHideTimer invalidate];
    @try {
        [self.player.currentItem removeObserver:self forKeyPath:@"status"];
    } @catch (__unused NSException *exception) {}
    @try {
        [self.player removeObserver:self forKeyPath:@"timeControlStatus"];
    } @catch (__unused NSException *exception) {}
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)customTransportEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"NativePlayerCustomTransportEnabled"];
}

- (void)togglePlayback {
    // Any explicit play/pause commits the current scrub/skip exploration.
    self.seekSessionActive = NO;
    if ([self isScanning]) {
        // Cancel fast-forward and resume normal playback from the current position.
        [self log:@"toggle stop scanning, resume 1x"];
        [self applyScanRate:1.0f];
        return;
    }
    if (self.player.rate > 0.0) {
        [self log:@"toggle pause"];
        [self.player pause];
        // Transport bar stays visible (persistent) while paused.
        NSTimeInterval position = self.hasPendingSeek ? self.pendingSeekTarget : CMTimeGetSeconds(self.player.currentTime);
        [self showPositionHUDForTarget:position];
    } else {
        [self log:@"toggle play"];
        [self.player play];
        [self schedulePositionHUDHide];
    }
}

- (BOOL)isScanning {
    return self.scanRate > 1.0f;
}

- (BOOL)isEffectivelyPaused {
    // Paused for real (not our emulated scanning, which also pauses the player).
    return ![self isScanning] && self.player.rate == 0.0f;
}

- (void)applyScanRate:(float)rate {
    BOOL wasScanning = [self isScanning];
    self.scanRate = rate;
    [self log:@"scan rate=%0.1f", rate];
    [self updateScanRateLabel];

    if (rate > 1.0f) {
        if (!wasScanning) {
            NSTimeInterval currentTime = CMTimeGetSeconds(self.player.currentTime);
            self.scanTargetTime = isfinite(currentTime) ? currentTime : 0.0;
            // Remember where scanning began so Menu (Back) can cancel back to it.
            self.scanOriginTime = self.scanTargetTime;
            [self.player pause];
        }
        if (self.scanTimer == nil) {
            __weak typeof(self) weakSelf = self;
            self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
                [weakSelf scanTimerStep];
            }];
        }
        return;
    }

    // Scanning finished: resume normal playback from the virtual playhead.
    [self stopScanTimer];
    if (wasScanning) {
        CMTime seekTime = CMTimeMakeWithSeconds(self.scanTargetTime, NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        [self.player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.player play];
            });
        }];
    }
}

- (void)stopScanTimer {
    [self.scanTimer invalidate];
    self.scanTimer = nil;
    self.scanSeekInProgress = NO;
}

- (void)cancelScanningAndReturnToOrigin {
    if (![self isScanning]) {
        return;
    }
    [self log:@"cancel scanning"];
    [self stopScanTimer];
    self.scanRate = 1.0f;
    [self updateScanRateLabel];
    [self seekToOriginAndPlay:self.scanOriginTime];
}

- (BOOL)hasCancelableSeekSession {
    if (!self.seekSessionActive) {
        return NO;
    }
    if ([self isEffectivelyPaused]) {
        // Paused exploration stays cancelable until committed with play.
        return YES;
    }
    // While playing, the session auto-commits shortly after the last seek.
    return ([NSDate timeIntervalSinceReferenceDate] - self.seekSessionLastActivity) <= 5.0;
}

- (void)cancelSeekSessionAndReturnToOrigin {
    if (!self.seekSessionActive) {
        return;
    }
    NSTimeInterval origin = self.seekSessionOriginTime;
    self.seekSessionActive = NO;
    [self log:@"cancel seek session"];
    [self seekToOriginAndPlay:origin];
}

- (void)seekToOriginAndPlay:(NSTimeInterval)origin {
    [self log:@"return to origin=%0.3f", origin];
    self.pendingSeekTarget = origin;
    self.hasPendingSeek = YES;
    [self showPositionHUDForTarget:origin];
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:CMTimeMakeWithSeconds(origin, NSEC_PER_SEC)
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            if (finished && fabs(strongSelf.pendingSeekTarget - origin) < 0.001) {
                strongSelf.hasPendingSeek = NO;
            }
            [strongSelf.player play];
        });
    }];
}

- (void)scanTimerStep {
    if (self.player.currentItem == nil || ![self isScanning]) {
        return;
    }
    if (self.scanSeekInProgress) {
        return; // Previous seek still loading; don't queue more.
    }

    NSTimeInterval delta = self.scanRate * 0.5; // seconds advanced per 0.5s tick = Nx speed
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval target = self.scanTargetTime + delta;
    if (isfinite(duration) && duration > 0.0 && target >= duration - 1.0) {
        // Reached the end of the video: stop scanning just before it.
        self.scanTargetTime = MAX(duration - 1.0, 0.0);
        [self applyScanRate:1.0f];
        return;
    }
    self.scanTargetTime = MAX(target, 0.0);
    [self showPositionHUDForTarget:self.scanTargetTime];

    // Loose tolerance: keyframe-aligned seeks load fast; scanTargetTime keeps the
    // real position so progress never stalls on long keyframe intervals.
    self.scanSeekInProgress = YES;
    CMTime seekTime = CMTimeMakeWithSeconds(self.scanTargetTime, NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:seekTime
            toleranceBefore:kCMTimePositiveInfinity
             toleranceAfter:kCMTimePositiveInfinity
          completionHandler:^(__unused BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.scanSeekInProgress = NO;
        });
    }];
}

- (void)updateScanRateLabel {
    if (![self isScanning] || ![self customTransportEnabled]) {
        self.scanRateLabel.hidden = YES;
        return;
    }
    if (self.scanRateLabel == nil) {
        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont monospacedDigitSystemFontOfSize:31.0 weight:UIFontWeightSemibold];
        label.textColor = [[BrowserPreferencesStore new] themeAccentColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        label.layer.cornerRadius = 8.0;
        label.layer.masksToBounds = YES;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentOverlayView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:self.contentOverlayView.topAnchor constant:60.0],
            [label.trailingAnchor constraintEqualToAnchor:self.contentOverlayView.trailingAnchor constant:-90.0],
        ]];
        self.scanRateLabel = label;
    }
    self.scanRateLabel.text = [NSString stringWithFormat:@"  » %gx  ", self.scanRate];
    self.scanRateLabel.hidden = NO;
}

- (void)handleRightArrowPress {
    if (self.player.currentItem == nil) {
        return;
    }
    // While paused, step forward instead of scanning.
    if (![self isScanning] && self.player.rate == 0.0f) {
        [self skipByInterval:10.0];
        return;
    }
    float nextRate = self.scanRate >= 16.0f ? 32.0f
                   : (self.scanRate >= 8.0f ? 16.0f
                   : (self.scanRate >= 4.0f ? 8.0f
                   : (self.scanRate >= 2.0f ? 4.0f : 2.0f)));
    [self applyScanRate:nextRate];
}

- (void)handleLeftArrowPress {
    if (self.player.currentItem == nil) {
        return;
    }
    if ([self isScanning]) {
        // Step the fast-forward speed back down; below 2x resume normal playback.
        float nextRate = self.scanRate > 16.0f ? 16.0f
                       : (self.scanRate > 8.0f ? 8.0f
                       : (self.scanRate > 4.0f ? 4.0f
                       : (self.scanRate > 2.0f ? 2.0f : 1.0f)));
        [self applyScanRate:nextRate];
        return;
    }
    [self skipByInterval:-10.0];
}

- (void)skipByInterval:(NSTimeInterval)delta {
    if (self.player.currentItem == nil) {
        return;
    }

    NSTimeInterval currentTime;
    if ([self isScanning]) {
        currentTime = self.scanTargetTime;
    } else if (self.hasPendingSeek) {
        currentTime = self.pendingSeekTarget;
    } else {
        currentTime = CMTimeGetSeconds(self.player.currentTime);
    }
    if (!isfinite(currentTime)) {
        currentTime = 0.0;
    }

    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval targetTime = currentTime + delta;
    if (isfinite(duration) && duration > 0.0) {
        targetTime = MIN(MAX(targetTime, 0.0), MAX(duration - 0.05, 0.0));
    } else {
        targetTime = MAX(targetTime, 0.0);
    }

    [self log:@"seek delta=%0.3f from=%0.3f to=%0.3f", delta, currentTime, targetTime];
    if ([self isScanning]) {
        // Keep the virtual scan playhead in sync with manual seeks (trackpad scrub).
        self.scanTargetTime = targetTime;
    } else {
        // Track the exploration session so Menu (Back) can cancel to its origin.
        if (!self.seekSessionActive) {
            self.seekSessionActive = YES;
            self.seekSessionOriginTime = currentTime;
            [self log:@"seek session origin=%0.3f", currentTime];
        }
        self.seekSessionLastActivity = [NSDate timeIntervalSinceReferenceDate];
    }
    self.pendingSeekTarget = targetTime;
    self.hasPendingSeek = YES;
    [self showPositionHUDForTarget:targetTime];
    CMTime seekTime = CMTimeMakeWithSeconds(targetTime, NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            // Only the latest seek clears the pending state; superseded seeks
            // report finished=NO and must not reset the accumulated target.
            if (finished && strongSelf != nil && fabs(strongSelf.pendingSeekTarget - targetTime) < 0.001) {
                strongSelf.hasPendingSeek = NO;
            }
        });
    }];
}

- (void)scrubByHorizontalDelta:(CGFloat)delta {
    // Approximate touch-surface horizontal movement to timeline seek.
    NSTimeInterval secondsDelta = (NSTimeInterval)delta / 8.0;
    if (fabs(secondsDelta) < 0.01) {
        return;
    }
    [self skipByInterval:secondsDelta];
}

static NSString *BrowserNativePlayerFormatTime(NSTimeInterval time) {
    if (!isfinite(time) || time < 0.0) {
        time = 0.0;
    }
    NSInteger total = (NSInteger)llround(time);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger seconds = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)seconds];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

- (void)showPositionHUDForTarget:(NSTimeInterval)target {
    // With AVKit's controls ON (the default) our overlay stays hidden; the
    // HUD code below serves only the opt-in custom-transport mode.
    if (![self customTransportEnabled]) {
        return;
    }
    if (self.positionHUDView == nil) {
        UIView *hud = [[UIView alloc] init];
        hud.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentOverlayView addSubview:hud];

        UILabel *title = [[UILabel alloc] init];
        title.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightSemibold];
        title.textColor = UIColor.whiteColor;
        title.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.8];
        title.shadowOffset = CGSizeMake(0.0, 1.0);
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        title.text = self.videoTitle;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [hud addSubview:title];

        // Buffer bar drawn under the playback progress: its own track is the visible
        // track; the bar on top has a clear track so the buffered range shows through.
        UIProgressView *buffer = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        buffer.progressTintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        buffer.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        buffer.transform = CGAffineTransformMakeScale(1.0, 3.0);
        buffer.translatesAutoresizingMaskIntoConstraints = NO;
        [hud addSubview:buffer];

        UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        progress.progressTintColor = [[BrowserPreferencesStore new] themeAccentColor];
        progress.trackTintColor = UIColor.clearColor;
        progress.transform = CGAffineTransformMakeScale(1.0, 3.0);
        progress.translatesAutoresizingMaskIntoConstraints = NO;
        [hud addSubview:progress];

        UILabel *elapsed = [[UILabel alloc] init];
        elapsed.font = [UIFont monospacedDigitSystemFontOfSize:27.0 weight:UIFontWeightSemibold];
        elapsed.textColor = UIColor.whiteColor;
        elapsed.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.8];
        elapsed.shadowOffset = CGSizeMake(0.0, 1.0);
        elapsed.translatesAutoresizingMaskIntoConstraints = NO;
        [hud addSubview:elapsed];

        UILabel *remaining = [[UILabel alloc] init];
        remaining.font = [UIFont monospacedDigitSystemFontOfSize:27.0 weight:UIFontWeightSemibold];
        remaining.textColor = UIColor.whiteColor;
        remaining.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.8];
        remaining.shadowOffset = CGSizeMake(0.0, 1.0);
        remaining.textAlignment = NSTextAlignmentRight;
        remaining.translatesAutoresizingMaskIntoConstraints = NO;
        [hud addSubview:remaining];

        [NSLayoutConstraint activateConstraints:@[
            [hud.leadingAnchor constraintEqualToAnchor:self.contentOverlayView.leadingAnchor constant:90.0],
            [hud.trailingAnchor constraintEqualToAnchor:self.contentOverlayView.trailingAnchor constant:-90.0],
            [hud.bottomAnchor constraintEqualToAnchor:self.contentOverlayView.bottomAnchor constant:-60.0],
            [title.topAnchor constraintEqualToAnchor:hud.topAnchor],
            [title.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:hud.trailingAnchor],
            [buffer.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18.0],
            [buffer.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor],
            [buffer.trailingAnchor constraintEqualToAnchor:hud.trailingAnchor],
            [progress.centerYAnchor constraintEqualToAnchor:buffer.centerYAnchor],
            [progress.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor],
            [progress.trailingAnchor constraintEqualToAnchor:hud.trailingAnchor],
            [elapsed.topAnchor constraintEqualToAnchor:buffer.bottomAnchor constant:18.0],
            [elapsed.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor],
            [elapsed.bottomAnchor constraintEqualToAnchor:hud.bottomAnchor],
            [remaining.topAnchor constraintEqualToAnchor:buffer.bottomAnchor constant:18.0],
            [remaining.trailingAnchor constraintEqualToAnchor:hud.trailingAnchor],
        ]];

        self.positionHUDView = hud;
        self.positionHUDTitleLabel = title;
        self.positionHUDLabel = elapsed;
        self.positionHUDRemainingLabel = remaining;
        self.positionHUDBufferProgress = buffer;
        self.positionHUDProgress = progress;
    }

    [self updatePositionHUDWithTime:target];
    self.positionHUDView.hidden = NO;

    [self.positionHUDHideTimer invalidate];
    self.positionHUDHideTimer = nil;
    if (![self isEffectivelyPaused]) {
        [self schedulePositionHUDHide];
    }
}

- (void)updatePositionHUDWithTime:(NSTimeInterval)time {
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    BOOL hasDuration = isfinite(duration) && duration > 0.0;
    self.positionHUDLabel.text = BrowserNativePlayerFormatTime(time);
    if (!hasDuration) {
        self.positionHUDRemainingLabel.text = @"";
    } else if ([[BrowserPreferencesStore new] videoHUDShowsTotalDuration]) {
        self.positionHUDRemainingLabel.text = BrowserNativePlayerFormatTime(duration);
    } else {
        self.positionHUDRemainingLabel.text = [NSString stringWithFormat:@"-%@", BrowserNativePlayerFormatTime(MAX(duration - time, 0.0))];
    }
    self.positionHUDProgress.progress = hasDuration ? (float)(time / duration) : 0.0f;

    // Buffered range relevant to the current position (shows how far ahead is loaded).
    NSTimeInterval bufferedEnd = 0.0;
    for (NSValue *value in self.player.currentItem.loadedTimeRanges) {
        CMTimeRange range = value.CMTimeRangeValue;
        NSTimeInterval start = CMTimeGetSeconds(range.start);
        NSTimeInterval end = start + CMTimeGetSeconds(range.duration);
        if (start <= time + 1.0 && end > bufferedEnd) {
            bufferedEnd = end;
        }
    }
    self.positionHUDBufferProgress.progress = hasDuration ? (float)(MIN(bufferedEnd, duration) / duration) : 0.0f;
}

- (void)schedulePositionHUDHide {
    [self.positionHUDHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.positionHUDHideTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:NO block:^(__unused NSTimer *timer) {
        weakSelf.positionHUDView.hidden = YES;
    }];
}

- (void)closePlayer {
    [self log:@"close player"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Resume position

- (NSString *)resumeStorageKey {
    NSURL *url = self.videoURL;
    if (url == nil || url.host.length == 0) {
        return nil;
    }
    // Key by scheme+host+path only: signed query tokens change between visits
    // (e.g. extracted/CDN URLs) but the path identifies the same video.
    return [NSString stringWithFormat:@"%@://%@%@", url.scheme ?: @"", url.host, url.path ?: @""];
}

- (void)saveResumePosition {
    NSString *key = [self resumeStorageKey];
    if (key == nil || self.player.currentItem == nil) {
        return;
    }
    NSTimeInterval position = self.hasPendingSeek ? self.pendingSeekTarget : CMTimeGetSeconds(self.player.currentTime);
    if ([self isScanning]) {
        position = self.scanTargetTime;
    }
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    BOOL nearStart = !isfinite(position) || position < kBrowserVideoResumeEdgeMargin;
    BOOL nearEnd = isfinite(duration) && duration > 0.0 && position > duration - kBrowserVideoResumeEdgeMargin;
    if (nearStart || nearEnd) {
        [self clearResumePosition];
        return;
    }

    NSMutableDictionary *positions = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kBrowserVideoResumePositionsDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    positions[key] = @{ @"position": @(position), @"date": @([NSDate date].timeIntervalSince1970) };

    // Keep the store bounded: drop the oldest entries beyond the cap.
    if (positions.count > kBrowserVideoResumeMaxEntries) {
        NSArray *sortedKeys = [positions keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [(a[@"date"] ?: @0) compare:(b[@"date"] ?: @0)];
        }];
        NSUInteger overflow = positions.count - kBrowserVideoResumeMaxEntries;
        for (NSUInteger index = 0; index < overflow; index++) {
            [positions removeObjectForKey:sortedKeys[index]];
        }
    }

    [[NSUserDefaults standardUserDefaults] setObject:positions forKey:kBrowserVideoResumePositionsDefaultsKey];
    [self log:@"saved resume position=%0.1f key=%@", position, key];
}

- (void)clearResumePosition {
    NSString *key = [self resumeStorageKey];
    if (key == nil) {
        return;
    }
    NSMutableDictionary *positions = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kBrowserVideoResumePositionsDefaultsKey] mutableCopy];
    if (positions[key] == nil) {
        return;
    }
    [positions removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setObject:positions forKey:kBrowserVideoResumePositionsDefaultsKey];
    [self log:@"cleared resume position key=%@", key];
}

- (void)restoreResumePositionIfAvailable {
    if (self.didAttemptResume) {
        return;
    }
    self.didAttemptResume = YES;

    NSString *key = [self resumeStorageKey];
    if (key == nil) {
        return;
    }
    NSDictionary *entry = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kBrowserVideoResumePositionsDefaultsKey][key];
    NSTimeInterval position = [entry[@"position"] doubleValue];
    if (position < kBrowserVideoResumeEdgeMargin) {
        return;
    }
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    if (isfinite(duration) && duration > 0.0 && position > duration - kBrowserVideoResumeEdgeMargin) {
        return;
    }

    [self log:@"resuming at position=%0.1f key=%@", position, key];
    self.pendingSeekTarget = position;
    self.hasPendingSeek = YES;
    [self showPositionHUDForTarget:position];
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:CMTimeMakeWithSeconds(position, NSEC_PER_SEC)
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (finished && strongSelf != nil && fabs(strongSelf.pendingSeekTarget - position) < 0.001) {
                strongSelf.hasPendingSeek = NO;
            }
        });
    }];
}

- (void)handleFocusUpdate:(NSNotification *)notification {
    // Debug instrumentation: trace where focus moves inside AVKit's transport bar
    // while the native player is presented (paused-scrub snap-back investigation).
    if (self.viewIfLoaded.window == nil) {
        return;
    }
    id<UIFocusItem> previousItem = notification.userInfo[UIFocusUpdateContextKey] ?
        ((UIFocusUpdateContext *)notification.userInfo[UIFocusUpdateContextKey]).previouslyFocusedItem : nil;
    id<UIFocusItem> nextItem = notification.userInfo[UIFocusUpdateContextKey] ?
        ((UIFocusUpdateContext *)notification.userInfo[UIFocusUpdateContextKey]).nextFocusedItem : nil;
    [self log:@"focus %@ -> %@",
     previousItem ? NSStringFromClass([(id)previousItem class]) : @"(nil)",
     nextItem ? NSStringFromClass([(id)nextItem class]) : @"(nil)"];
}

- (void)handlePlayerItemDidPlayToEndTime:(NSNotification *)notification {
    (void)notification;
    [self log:@"played to end"];
    // Watched to the end: don't offer resume next time.
    [self clearResumePosition];
}

- (void)handlePlayerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self log:@"failedToPlayToEnd error=%@", error];
    [self presentPlaybackFailureAlert];
}

// The failure alert must never be presented on the player VC itself: with
// AVKit's content overlay holding focus the alert's buttons stay selectable
// but remote presses never activate them. Walk the presentation chain from the
// app root and present on the top-most VC above the player instead.
- (UIViewController *)failureAlertPresentingViewController {
    UIViewController *rootViewController = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        rootViewController = ((UIWindowScene *)scene).keyWindow.rootViewController;
        if (rootViewController != nil) {
            break;
        }
    }
    UIViewController *presenter = rootViewController ?: self.presentingViewController ?: self;
    while (presenter.presentedViewController != nil && presenter.presentedViewController != self) {
        presenter = presenter.presentedViewController;
    }
    if (presenter == self) {
        // Never present on the player itself (see comment above).
        presenter = self.presentingViewController ?: (rootViewController ?: self);
    }
    return presenter;
}

// Item failed to load (initial status=failed or mid-playback failure): with
// AVKit controls alone the user is stuck, so offer a host-driven retry from
// the freshest probes. Capped per presentation to avoid retry loops.
- (void)presentPlaybackFailureAlert {
    if (self.viewIfLoaded.window == nil) {
        // Status KVO can fire with its initial value before presentation;
        // give it one more chance once the view is on screen.
        if (self.viewIfLoaded != nil && !self.failureAlertRechecked) {
            self.failureAlertRechecked = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf presentPlaybackFailureAlert];
            });
        }
        return;
    }
    if (self.failureAlertPresented || self.failureRetryCount >= kBrowserNativePlayerMaxFailureRetries) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Video failed to load"
                                                                            message:@"Retry?"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    self.failureAlertPresented = YES;
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alertController;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Close"
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(__unused UIAlertAction *action) {
        // Explicit dismiss (never rely on the cancel-action auto-dismiss here:
        // the alert lives above the player and its buttons only activate from
        // the remote once presented on the top-most VC). Dismiss the whole
        // player presentation, alert included.
        typeof(self) strongSelf = weakSelf;
        UIViewController *dismissFrom = strongSelf != nil ? strongSelf.presentingViewController : weakAlert.presentingViewController;
        [dismissFrom dismissViewControllerAnimated:YES completion:nil];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Retry"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.failureRetryCount += 1;
        strongSelf.failureAlertPresented = NO;
        void (^retry)(void) = strongSelf.onRetry;
        void (^performRetry)(void) = ^{
            if (retry != nil) {
                retry();
            }
        };
        // Dismiss the alert explicitly before invoking onRetry: the retry
        // re-presents a fresh player and the alert must not linger on top.
        UIViewController *dismissFrom = weakAlert.presentingViewController ?: strongSelf.presentingViewController;
        if (dismissFrom != nil && dismissFrom.presentedViewController != nil) {
            [dismissFrom dismissViewControllerAnimated:YES completion:performRetry];
        } else {
            performRetry();
        }
    }]];
    [[self failureAlertPresentingViewController] presentViewController:alertController animated:YES completion:nil];
}

- (void)handlePlayerItemNewErrorLogEntry:(NSNotification *)notification {
    AVPlayerItemErrorLog *errorLog = self.player.currentItem.errorLog;
    AVPlayerItemErrorLogEvent *lastEvent = errorLog.events.lastObject;
    [self log:@"errorLog domain=%@ status=%ld comment=%@ serverAddress=%@ playbackSessionID=%@",
     lastEvent.errorDomain ?: @"",
     (long)lastEvent.errorStatusCode,
     lastEvent.errorComment ?: @"",
     lastEvent.serverAddress ?: @"",
     lastEvent.playbackSessionID ?: @""];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == self.player.currentItem && [keyPath isEqualToString:@"status"]) {
        switch (self.player.currentItem.status) {
            case AVPlayerItemStatusUnknown:
                [self log:@"item status=unknown error=%@", self.player.currentItem.error];
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self log:@"item status=ready duration=%f likelyToKeepUp=%d bufferEmpty=%d",
                 CMTimeGetSeconds(self.player.currentItem.duration),
                 self.player.currentItem.isPlaybackLikelyToKeepUp,
                 self.player.currentItem.isPlaybackBufferEmpty];
                [self restoreResumePositionIfAvailable];
                break;
            case AVPlayerItemStatusFailed:
                [self log:@"item status=failed error=%@", self.player.currentItem.error];
                [self presentPlaybackFailureAlert];
                break;
        }
        return;
    }

    if (object == self.player && [keyPath isEqualToString:@"timeControlStatus"]) {
        if (@available(tvOS 10.0, *)) {
            NSString *status = @"unknown";
            switch (self.player.timeControlStatus) {
                case AVPlayerTimeControlStatusPaused:
                    status = @"paused";
                    break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    status = @"waiting";
                    break;
                case AVPlayerTimeControlStatusPlaying:
                    status = @"playing";
                    break;
            }
            [self log:@"timeControlStatus=%@ reason=%@", status, self.player.reasonForWaitingToPlay ?: @""];
            return;
        }
    }

    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesBegan type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesEnded type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesEnded:presses withEvent:event];
}

@end
