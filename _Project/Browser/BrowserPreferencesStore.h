#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;
+ (NSArray<NSString *> *)themeNames;
+ (NSArray<NSString *> *)searchEngineNames;

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
// How many times the "Settings is in the Quick Menu" tip has been shown while
// the top bar is hidden (capped at 3 — see ViewController).
@property (nonatomic) NSUInteger settingsHintShownCount;
// Accent theme: index into +themeNames (0 = Classic, the original look).
@property (nonatomic) NSUInteger themeIndex;
@property (nonatomic, readonly) NSString *themeName;
@property (nonatomic, readonly) UIColor *themeAccentColor;
// Search engine: index into +searchEngineNames (0 = Google). The query format
// has a single %@ placeholder for the URL-encoded terms.
@property (nonatomic) NSUInteger searchEngineIndex;
@property (nonatomic, readonly) NSString *searchEngineName;
@property (nonatomic, readonly) NSString *searchQueryURLFormat;
@property (nonatomic) BOOL scalePagesToFit;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;

- (void)ensureUserAgentConsistency;

@end

NS_ASSUME_NONNULL_END
