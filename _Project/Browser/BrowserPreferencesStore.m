#import "BrowserPreferencesStore.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static NSString * const kMobileModeDefaultsKey = @"MobileMode";
static NSString * const kShowTopNavigationBarDefaultsKey = @"ShowTopNavigationBar";
static NSString * const kTextFontSizeDefaultsKey = @"TextFontSize";
static NSString * const kEnableFullscreenVideoPlaybackDefaultsKey = @"EnableFullscreenVideoPlayback";
static NSString * const kVideoHUDShowsTotalDurationDefaultsKey = @"VideoHUDShowsTotalDuration";
static NSString * const kArrowDoubleTapShortcutsEnabledDefaultsKey = @"ArrowDoubleTapShortcutsEnabled";
static NSString * const kThemeIndexDefaultsKey = @"ThemeIndex";
static NSString * const kSettingsHintShownCountDefaultsKey = @"SettingsHintShownCount";
static NSString * const kSearchEngineIndexDefaultsKey = @"SearchEngineIndex";
static NSString * const kScalePagesToFitDefaultsKey = @"ScalePagesToFit";
static NSString * const kDontShowHintsOnLaunchDefaultsKey = @"DontShowHintsOnLaunch";
static NSString * const kHomepageDefaultsKey = @"homepage";

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;

@implementation BrowserPreferencesStore

+ (NSString *)desktopUserAgent {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
}

+ (NSString *)mobileUserAgent {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
}

// Accent themes: name + color pairs. "Classic" (index 0) reproduces the original
// white-highlight look; the rest are vivid accents for focus/progress UI.
static NSArray<NSString *> *BrowserThemeNames(void) {
    return @[ @"Classic", @"Nebula", @"Ocean", @"Emerald", @"Sunset",
              @"Crimson", @"Rose", @"Sky", @"Gold", @"Lavender" ];
}

static UIColor *BrowserThemeColorAtIndex(NSUInteger index) {
    static NSArray<UIColor *> *colors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colors = @[
            [UIColor whiteColor],                                                 // Classic
            [UIColor colorWithRed:0.48 green:0.42 blue:0.87 alpha:1.0],           // Nebula  #7B6CDE
            [UIColor colorWithRed:0.04 green:0.52 blue:1.00 alpha:1.0],           // Ocean   #0A84FF
            [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1.0],           // Emerald #30D158
            [UIColor colorWithRed:1.00 green:0.62 blue:0.04 alpha:1.0],           // Sunset  #FF9F0A
            [UIColor colorWithRed:1.00 green:0.27 blue:0.23 alpha:1.0],           // Crimson #FF453A
            [UIColor colorWithRed:1.00 green:0.18 blue:0.57 alpha:1.0],           // Rose    #FF2D92
            [UIColor colorWithRed:0.39 green:0.82 blue:1.00 alpha:1.0],           // Sky     #64D2FF
            [UIColor colorWithRed:1.00 green:0.84 blue:0.04 alpha:1.0],           // Gold    #FFD60A
            [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0],           // Lavender #BF5AF2
        ];
    });
    return colors[MIN(index, colors.count - 1)];
}

+ (NSArray<NSString *> *)themeNames {
    return BrowserThemeNames();
}

// Search engines: name + query URL format (single %@ for the encoded terms).
static NSArray<NSDictionary<NSString *, NSString *> *> *BrowserSearchEngines(void) {
    return @[
        @{ @"name": @"Google",     @"format": @"https://www.google.com/search?q=%@" },
        @{ @"name": @"Bing",       @"format": @"https://www.bing.com/search?q=%@" },
        @{ @"name": @"DuckDuckGo", @"format": @"https://duckduckgo.com/?q=%@" },
        @{ @"name": @"Yahoo",      @"format": @"https://search.yahoo.com/search?p=%@" },
        @{ @"name": @"Ecosia",     @"format": @"https://www.ecosia.org/search?q=%@" },
        @{ @"name": @"Brave",      @"format": @"https://search.brave.com/search?q=%@" },
        @{ @"name": @"Startpage",  @"format": @"https://www.startpage.com/sp/search?query=%@" },
    ];
}

+ (NSArray<NSString *> *)searchEngineNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *engine in BrowserSearchEngines()) {
        [names addObject:engine[@"name"]];
    }
    return names;
}

- (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)ensureUserAgentConsistency {
    if (self.userAgent.length > 0) {
        return;
    }
    self.userAgent = self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (NSString *)userAgent {
    NSString *userAgent = [[self defaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        return userAgent;
    }
    return self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (void)setUserAgent:(NSString *)userAgent {
    [[self defaults] setObject:userAgent ?: @"" forKey:kUserAgentDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)mobileModeEnabled {
    return [[self defaults] boolForKey:kMobileModeDefaultsKey];
}

- (void)setMobileModeEnabled:(BOOL)mobileModeEnabled {
    [[self defaults] setBool:mobileModeEnabled forKey:kMobileModeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)topNavigationBarVisible {
    NSNumber *showTopNavBar = [[self defaults] objectForKey:kShowTopNavigationBarDefaultsKey];
    return showTopNavBar ? showTopNavBar.boolValue : YES;
}

- (void)setTopNavigationBarVisible:(BOOL)topNavigationBarVisible {
    [[self defaults] setObject:@(topNavigationBarVisible) forKey:kShowTopNavigationBarDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)textFontSize {
    NSNumber *textFontSizeValue = [[self defaults] objectForKey:kTextFontSizeDefaultsKey];
    if (textFontSizeValue == nil) {
        return kDefaultTextFontSize;
    }
    NSUInteger textFontSize = textFontSizeValue.unsignedIntegerValue;
    return MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
}

- (void)setTextFontSize:(NSUInteger)textFontSize {
    textFontSize = MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
    [[self defaults] setObject:@(textFontSize) forKey:kTextFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)fullscreenVideoPlaybackEnabled {
    // Defaults to YES: videos open in the full screen player out of the box.
    id storedValue = [[self defaults] objectForKey:kEnableFullscreenVideoPlaybackDefaultsKey];
    return storedValue == nil ? YES : [storedValue boolValue];
}

- (void)setFullscreenVideoPlaybackEnabled:(BOOL)fullscreenVideoPlaybackEnabled {
    [[self defaults] setBool:fullscreenVideoPlaybackEnabled forKey:kEnableFullscreenVideoPlaybackDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)arrowDoubleTapShortcutsEnabled {
    id storedValue = [[self defaults] objectForKey:kArrowDoubleTapShortcutsEnabledDefaultsKey];
    return storedValue == nil ? YES : [storedValue boolValue];
}

- (void)setArrowDoubleTapShortcutsEnabled:(BOOL)arrowDoubleTapShortcutsEnabled {
    [[self defaults] setBool:arrowDoubleTapShortcutsEnabled forKey:kArrowDoubleTapShortcutsEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)settingsHintShownCount {
    return (NSUInteger)MAX((NSInteger)0, [[self defaults] integerForKey:kSettingsHintShownCountDefaultsKey]);
}

- (void)setSettingsHintShownCount:(NSUInteger)settingsHintShownCount {
    [[self defaults] setInteger:(NSInteger)settingsHintShownCount forKey:kSettingsHintShownCountDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)themeIndex {
    NSInteger storedIndex = [[self defaults] integerForKey:kThemeIndexDefaultsKey];
    NSUInteger themeCount = BrowserThemeNames().count;
    if (storedIndex < 0 || (NSUInteger)storedIndex >= themeCount) {
        return 0;
    }
    return (NSUInteger)storedIndex;
}

- (void)setThemeIndex:(NSUInteger)themeIndex {
    [[self defaults] setInteger:(NSInteger)(themeIndex % BrowserThemeNames().count) forKey:kThemeIndexDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)themeName {
    return BrowserThemeNames()[self.themeIndex];
}

- (UIColor *)themeAccentColor {
    return BrowserThemeColorAtIndex(self.themeIndex);
}

- (NSUInteger)searchEngineIndex {
    NSInteger storedIndex = [[self defaults] integerForKey:kSearchEngineIndexDefaultsKey];
    NSUInteger engineCount = BrowserSearchEngines().count;
    if (storedIndex < 0 || (NSUInteger)storedIndex >= engineCount) {
        return 0;
    }
    return (NSUInteger)storedIndex;
}

- (void)setSearchEngineIndex:(NSUInteger)searchEngineIndex {
    [[self defaults] setInteger:(NSInteger)(searchEngineIndex % BrowserSearchEngines().count) forKey:kSearchEngineIndexDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)searchEngineName {
    return BrowserSearchEngines()[self.searchEngineIndex][@"name"];
}

- (NSString *)searchQueryURLFormat {
    return BrowserSearchEngines()[self.searchEngineIndex][@"format"];
}

- (BOOL)videoHUDShowsTotalDuration {
    return [[self defaults] boolForKey:kVideoHUDShowsTotalDurationDefaultsKey];
}

- (void)setVideoHUDShowsTotalDuration:(BOOL)videoHUDShowsTotalDuration {
    [[self defaults] setBool:videoHUDShowsTotalDuration forKey:kVideoHUDShowsTotalDurationDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)scalePagesToFit {
    return [[self defaults] boolForKey:kScalePagesToFitDefaultsKey];
}

- (void)setScalePagesToFit:(BOOL)scalePagesToFit {
    [[self defaults] setBool:scalePagesToFit forKey:kScalePagesToFitDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dontShowHintsOnLaunch {
    return [[self defaults] boolForKey:kDontShowHintsOnLaunchDefaultsKey];
}

- (void)setDontShowHintsOnLaunch:(BOOL)dontShowHintsOnLaunch {
    [[self defaults] setBool:dontShowHintsOnLaunch forKey:kDontShowHintsOnLaunchDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)homePageURLString {
    NSString *value = [[self defaults] stringForKey:kHomepageDefaultsKey];
    return value ?: @"";
}

- (void)setHomePageURLString:(NSString *)homePageURLString {
    [[self defaults] setObject:homePageURLString ?: @"" forKey:kHomepageDefaultsKey];
    [[self defaults] synchronize];
}

@end
