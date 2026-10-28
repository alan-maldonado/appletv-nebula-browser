#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoPlayerViewController : AVPlayerViewController

- (instancetype)initWithURL:(NSURL *)URL title:(nullable NSString *)title;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

// Nebula Remote. Called on the main queue whenever the playhead, play state or
// visibility changes (often: every 0.5 s while playing).
@property (nonatomic, copy, nullable) void (^remoteMediaStateDidChange)(void);
// {source: "native", title, time, duration, playing, rate}, or nil when the player
// isn't on screen.
@property (nonatomic, readonly, nullable) NSDictionary *remoteMediaState;
- (void)remoteTogglePlayback;
- (void)remotePlay;
- (void)remotePause;
// Closes the player (back to the page), like Menu on the Siri Remote.
- (void)remoteClose;
- (void)remoteSeekToTime:(NSTimeInterval)time;
- (void)remoteSkipByInterval:(NSTimeInterval)delta;

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
