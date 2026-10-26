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
// Nebula Remote: a page text field became active (keys id, title, type,
// placeholder, value) or nil when it is gone.
- (void)browserPageActionCoordinatorActiveFieldDidChange:(nullable NSDictionary<NSString *, NSString *> *)field;

@end

@interface BrowserPageActionCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// Resolves video handling asynchronously, then falls back to the regular page click.
- (void)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;
// Nebula Remote: fills the active field with text typed elsewhere. Returns NO when
// fieldID is no longer the active field.
- (BOOL)commitRemoteText:(NSString *)text forFieldID:(NSString *)fieldID submitForm:(BOOL)submitForm;

@end

NS_ASSUME_NONNULL_END
