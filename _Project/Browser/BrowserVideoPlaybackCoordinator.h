#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserDOMInteractionService;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserVideoPlaybackCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, readonly) BOOL browserIsCursorModeEnabled;
@property (nonatomic, readonly) CGPoint browserDOMCursorPoint;
@property (nonatomic, readonly, nullable) UIViewController *browserPresentedViewController;
@property (nonatomic, readonly, nullable) NSString *browserCurrentPageTitle;
@property (nonatomic, readonly) BOOL browserFullscreenVideoPlaybackEnabled;

- (void)browserPresentViewController:(UIViewController *)viewController;

@end

@interface BrowserVideoPlaybackCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserVideoPlaybackCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService;
// Returns YES when the cursor path handled the request (player presented, or
// intentionally suppressed by the Full Screen Player preference / modal /
// scroll-mode gates). Returns NO when the cursor found no usable video, so the
// caller can fall back to presentNativePlayerFromMediaProbes.
- (BOOL)playVideoUnderCursorIfAvailable;
- (BOOL)handleSelectPressForVideoAtCursor;
- (void)handlePageFullscreenRequestWithInfo:(NSDictionary *)videoInfo;
// Present the best video the page's frames reported through the media-probe
// channel (cross-origin iframes the main-frame DOM queries cannot see).
- (void)presentNativePlayerFromMediaProbes;
// Same presentation logic without the "Native Video Unavailable" alert: a
// frame whose only video is a blob:/MSE src with no captured playlist has
// nothing AVPlayer can open, so this silently does nothing. Used by the
// auto-fullscreen path (a user-initiated hold still gets the alert).
- (BOOL)presentNativePlayerFromMediaProbesSilently;
// Variant with an explicit report-age window for user-initiated re-entry
// (Play/Pause HOLD retries, test second-present): while the native player
// plays the page's probe script stops reporting, so the candidate may
// predate the auto path's 10s window by minutes.
- (BOOL)presentNativePlayerFromMediaProbesSilentlyAllowingReportAge:(NSTimeInterval)age;

@end

NS_ASSUME_NONNULL_END
