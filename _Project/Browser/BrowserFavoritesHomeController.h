#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserFavoritesHomeControllerHost <NSObject>

- (BOOL)browserFavoritesHomeControllerCursorModeEnabled;
- (void)browserFavoritesHomeControllerSetCursorModeEnabled:(BOOL)enabled;
- (void)browserFavoritesHomeControllerPresentViewController:(UIViewController *)viewController;
- (UIColor *)browserFavoritesHomeControllerAccentColor;
- (void)browserFavoritesHomeControllerOpenURLString:(NSString *)URLString inNewTab:(BOOL)newTab;

@end

// "Favorites as Home Page": a grid of every favorite shown over the current tab
// (same presentation as the tab overview). Select opens in this tab, Play/Pause
// in a new one, Menu closes it.
@interface BrowserFavoritesHomeController : NSObject

@property (nonatomic, readonly, getter=isVisible) BOOL visible;

- (instancetype)initWithHost:(id<BrowserFavoritesHomeControllerHost>)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)show;
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
