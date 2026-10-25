#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserDOMInteractionService;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserVideoPlaybackCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, readonly) BOOL browserIsCursorModeEnabled;
// Non-blocking: resolves the cursor's DOM point (needs the page's innerWidth).
- (void)browserResolveDOMCursorPointWithCompletion:(void (^)(CGPoint point))completion;
@property (nonatomic, readonly, nullable) UIViewController *browserPresentedViewController;
@property (nonatomic, readonly, nullable) NSString *browserCurrentPageTitle;
@property (nonatomic, readonly) BOOL browserFullscreenVideoPlaybackEnabled;

- (void)browserPresentViewController:(UIViewController *)viewController;

@end

@interface BrowserVideoPlaybackCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserVideoPlaybackCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService;
- (void)playVideoUnderCursorIfAvailable;
// Completion on the main queue; handled == YES means the press was a video interaction
// and the regular page click must be skipped.
- (void)handleSelectPressForVideoAtDOMPoint:(CGPoint)point completion:(void (^)(BOOL handled))completion;
- (void)handlePageFullscreenRequestWithInfo:(NSDictionary *)videoInfo;

@end

NS_ASSUME_NONNULL_END
