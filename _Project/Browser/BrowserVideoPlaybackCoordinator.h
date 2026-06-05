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
- (void)playVideoUnderCursorIfAvailable;
- (BOOL)handleSelectPressForVideoAtCursor;
- (void)handlePageFullscreenRequestWithInfo:(NSDictionary *)videoInfo;

@end

NS_ASSUME_NONNULL_END
