#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;
+ (NSArray<NSString *> *)themeNames;

@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL mobileModeEnabled;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;
// NO (default): the video HUD's right label shows remaining time (-12:34).
// YES: it shows the video's total duration instead.
@property (nonatomic) BOOL videoHUDShowsTotalDuration;
// Double-pressing the arrow keys triggers shortcuts (tabs/history/favorites/new
// tab). Defaults to YES.
@property (nonatomic) BOOL arrowDoubleTapShortcutsEnabled;
// Accent theme: index into +themeNames (0 = Classic, the original look).
@property (nonatomic) NSUInteger themeIndex;
@property (nonatomic, readonly) NSString *themeName;
@property (nonatomic, readonly) UIColor *themeAccentColor;
@property (nonatomic) BOOL scalePagesToFit;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;

- (void)ensureUserAgentConsistency;

@end

NS_ASSUME_NONNULL_END
