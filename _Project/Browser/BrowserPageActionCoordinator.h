#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserDOMInteractionService;
@class BrowserNavigationService;
@class BrowserVideoPlaybackCoordinator;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserPageActionCoordinatorHost <NSObject>

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController;
- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request;
- (UIView *)browserPageActionCoordinatorContainerView;

@end

@interface BrowserPageActionCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;
- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END
