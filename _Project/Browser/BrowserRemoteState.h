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
// url, launch ("last-session" | "home-page").
- (void)updateHome:(NSDictionary *)home;
// accent, onAccent (hex colors).
- (void)updateTheme:(NSDictionary *)theme;
// {v, page, field, tabs, favorites, home, theme}
- (NSDictionary *)JSONObject;

@end

NS_ASSUME_NONNULL_END
