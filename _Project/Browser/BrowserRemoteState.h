#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the panel sees (GET /api/state). Main thread only. The version starts
// at 1 and increments only when a section actually changes.
@interface BrowserRemoteState : NSObject

@property (nonatomic, readonly) NSUInteger version;

- (void)updatePageTitle:(NSString *)title URLString:(NSString *)URLString;
// Keys: id, title, type, placeholder, value. nil when no field is active.
- (void)updateField:(nullable NSDictionary<NSString *, NSString *> *)field;
// Each tab: id, title, url (strings) and active (NSNumber BOOL).
- (void)updateTabs:(NSArray<NSDictionary *> *)tabs;
// Each favorite: url, title.
- (void)updateFavorites:(NSArray<NSDictionary *> *)favorites;
// url, launch ("last-session" | "home-page"), favorites (BOOL: Favorites as Home Page).
- (void)updateHome:(NSDictionary *)home;
// accent, onAccent (hex colors).
- (void)updateTheme:(NSDictionary *)theme;
// Now playing (native player or page <video>), or nil when nothing is loaded.
// Keys: source ("native" | "page"), title, time, duration (NSNull when unknown/live),
// playing (BOOL), rate, fullscreen (BOOL). now is NSProcessInfo.systemUptime. Bumps the version only
// when something besides the playhead changed or the playhead jumped (> 1 s off
// from where playback would have put it): the panel advances the clock itself.
- (void)updateMedia:(nullable NSDictionary *)media now:(NSTimeInterval)now;
// {v, page, field, tabs, favorites, home, theme, media}; the media time is
// advanced to now.
- (NSDictionary *)JSONObjectAtTime:(NSTimeInterval)now;
- (NSDictionary *)JSONObject;

@end

NS_ASSUME_NONNULL_END
