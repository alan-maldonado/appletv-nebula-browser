#import <UIKit/UIKit.h>
#import "BrowserWebView.h"

@class BrowserPreferencesStore;

@protocol BrowserMenuCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, copy) NSString *browserPreviousURL;
@property (nonatomic) NSUInteger browserTextFontSize;
@property (nonatomic) BOOL browserFullscreenVideoPlaybackEnabled;
@property (nonatomic, readonly) BOOL browserTopMenuShowing;

- (void)browserPresentViewController:(UIViewController *)viewController;
- (void)browserLoadHomePage;
- (void)browserShowHints;
- (void)browserShowDonate;
- (void)browserShowTabOverview;
- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage;
- (void)browserHideTopNav;
- (void)browserShowTopNav;
- (void)browserUpdateTextFontSize;
- (void)browserDidChangeTheme;
- (void)browserCaptureSnapshotForCurrentTab;
- (void)browserRecreateActiveWebViewPreservingCurrentURL;
- (void)browserBringCursorToFront;
- (void)browserPlayVideoUnderCursorIfAvailable;

@end

@interface BrowserMenuCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (void)showAdvancedMenu;
- (void)showFavoritesMenu;
- (void)showHistoryMenu;
// Syncs the home screen icon with the current theme (call at launch and on change).
+ (void)applyAppIconForCurrentTheme;

@end
