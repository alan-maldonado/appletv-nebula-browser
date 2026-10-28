#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserNativeVideoAssetLoader.h"
#import "BrowserPreferencesStore.h"

#import <AVFoundation/AVFoundation.h>

static NSString * const kBrowserNativeVideoPlayerLogPrefix = @"[NativeVideoPlayer]";
static NSString * const kBrowserNativePlayerInputLogPrefix = @"[InputTrace][NativePlayer]";
static NSString * const kBrowserVideoResumePositionsDefaultsKey = @"VideoResumePositions";
static NSUInteger const kBrowserVideoResumeMaxEntries = 50;
// No resume near the start (not worth it) or near the end (counts as watched).
static NSTimeInterval const kBrowserVideoResumeEdgeMargin = 30.0;

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

@interface BrowserNativeVideoPlayerViewController ()

@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *requestCookies;
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

// Resume-where-you-left-off support.
@property (nonatomic, assign) BOOL didAttemptResume;
@property (nonatomic, assign) BOOL remoteVisible;
@property (nonatomic, assign) NSTimeInterval lastResumeSaveTimestamp;

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
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _requestCookies = [cookies copy] ?: @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    // All transport input and UI is ours (FF scanning, scrub, skips, toggle, HUD);
    // AVKit's overlay would just be a second, out-of-sync progress bar.
    self.showsPlaybackControls = NO;
    AVPlayerItem *playerItem = nil;
    if (self.requestHeaders.count > 0 || self.requestCookies.count > 0) {
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
        NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:self.videoURL];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
        [self.assetLoader attachToAsset:asset];
        playerItem = [AVPlayerItem playerItemWithAsset:asset];
        [self log:@"using request headers %@ cookies=%lu", self.requestHeaders, (unsigned long)self.requestCookies.count];
    } else {
        playerItem = [AVPlayerItem playerItemWithURL:self.videoURL];
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
        [strongSelf notifyRemoteMediaStateDidChange];
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
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSLog(@"%@ viewDidAppear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewDidAppear play"];
    [self.player play];
    self.remoteVisible = YES;
    [self notifyRemoteMediaStateDidChange];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.remoteVisible = NO;
    [self notifyRemoteMediaStateDidChange];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewWillDisappear pause"];
    [self saveResumePosition];
    [self stopScanTimer];
    self.scanRate = 1.0f;
    [self.player pause];
}

- (void)dealloc {
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

#pragma mark - Nebula Remote

- (void)notifyRemoteMediaStateDidChange {
    if (self.remoteMediaStateDidChange != nil) {
        self.remoteMediaStateDidChange();
    }
}

- (NSDictionary *)remoteMediaState {
    if (!self.remoteVisible || self.player.currentItem == nil) {
        return nil;
    }
    // Same playhead the HUD shows: the pending seek or virtual scan target wins.
    NSTimeInterval time;
    if ([self isScanning]) {
        time = self.scanTargetTime;
    } else if (self.hasPendingSeek) {
        time = self.pendingSeekTarget;
    } else {
        time = CMTimeGetSeconds(self.player.currentTime);
    }
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    BOOL playing = [self isScanning];
    if (!playing) {
        if (@available(tvOS 10.0, *)) {
            playing = self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying;
        } else {
            playing = self.player.rate > 0.0f;
        }
    }
    return @{
        @"source": @"native",
        @"title": self.videoTitle ?: @"",
        @"time": @(isfinite(time) ? time : 0.0),
        @"duration": isfinite(duration) && duration > 0.0 ? @(duration) : NSNull.null,
        @"playing": @(playing),
        @"rate": @([self isScanning] ? self.scanRate : 1.0),
        @"fullscreen": @YES,
    };
}

- (void)remoteTogglePlayback {
    [self togglePlayback];
    [self notifyRemoteMediaStateDidChange];
}

- (void)remotePlay {
    if ([self isScanning] || self.player.rate == 0.0f) {
        [self togglePlayback];
    }
    [self notifyRemoteMediaStateDidChange];
}

- (void)remotePause {
    if ([self isScanning]) {
        [self applyScanRate:1.0f];
    }
    if (self.player.rate > 0.0f) {
        [self togglePlayback];
    }
    [self notifyRemoteMediaStateDidChange];
}

- (void)remoteClose {
    [self closePlayer];
}

- (void)remoteSeekToTime:(NSTimeInterval)time {
    NSTimeInterval current = [self.remoteMediaState[@"time"] doubleValue];
    [self remoteSkipByInterval:time - current];
}

- (void)remoteSkipByInterval:(NSTimeInterval)delta {
    [self skipByInterval:delta];
    // A seek from the panel is a decision, not an exploration Menu should undo.
    self.seekSessionActive = NO;
    [self notifyRemoteMediaStateDidChange];
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
    if (![self isScanning]) {
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
            [self notifyRemoteMediaStateDidChange];
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
