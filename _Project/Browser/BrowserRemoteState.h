#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the phone page sees (GET /api/state). Main thread only. The version
// starts at 1 and increments only when the page or the active field changes.
@interface BrowserRemoteState : NSObject

@property (nonatomic, readonly) NSUInteger version;

- (void)updatePageTitle:(NSString *)title URLString:(NSString *)URLString;
// Keys: id, title, type, placeholder, value. nil when no field is active.
- (void)updateField:(nullable NSDictionary<NSString *, NSString *> *)field;
// {v, page:{title,url}, field: dict or NSNull}
- (NSDictionary *)JSONObject;

@end

NS_ASSUME_NONNULL_END
