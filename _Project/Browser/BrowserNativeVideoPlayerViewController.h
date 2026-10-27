#import <AVKit/AVKit.h>

// Posted (object:self) when the player's view disappears (Menu dismissal,
// close, app-chrome teardown): observers mark a suppression window so an
// embed watchdog reloading the player iframe cannot immediately re-trigger
// auto-fullscreen for the same embed.
FOUNDATION_EXPORT NSNotificationName const kBrowserNativeVideoPlayerDidDismissNotification;

// Test-only: posted N seconds after the player's first dismissal (see the
// NativePresentSecondPresentSeconds launch flag); the observer re-presents the
// native player from the media probes to exercise a second presentation.
FOUNDATION_EXPORT NSNotificationName const kBrowserTestForceSecondPresentNotification;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoPlayerViewController : AVPlayerViewController

- (instancetype)initWithURL:(NSURL *)URL title:(nullable NSString *)title;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;
// Freshest master playlist URLs captured by the media probes (oldest-first);
// handed to the asset loader so a 403/404 media playlist in the same stream
// family retries against the fresher master.
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies
  candidateMasterPlaylistURLs:(nullable NSArray<NSURL *> *)candidateMasterPlaylistURLs NS_DESIGNATED_INITIALIZER;

// Invoked when the user confirms Retry on the load-failure alert; the player
// has already dismissed itself. Set by BrowserVideoPlaybackCoordinator at
// presentation time to re-present from the freshest media probes.
@property (nonatomic, copy, nullable) void (^onRetry)(void);

// WebVTT subtitle tracks captured from the page at takeover time (see
// BrowserWebView -extractSubtitleTracksForFrameKey:completion:), set by
// BrowserVideoPlaybackCoordinator before presentation. Each dict either
// carries parsed cues ({label, mode, cues:[{s,e,t}]}) or a VTT URL to fetch
// ({label, src}). Non-empty: a time-synced cue overlay renders over the
// video; nil or empty keeps the player behavior identical (no overlay).
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *subtitleTracks; // [{label, mode, cues:[{s,e,t}]} or {label, src}]

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
