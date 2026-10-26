#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted (object: the store) after every successful mutation.
extern NSNotificationName const BrowserFavoritesStoreDidChangeNotification;

typedef NS_ENUM(NSInteger, BrowserFavoritesEditResult) {
    BrowserFavoritesEditResultOK,
    // The favorite at the index no longer has the expected URL (edited elsewhere).
    BrowserFavoritesEditResultChanged,
    BrowserFavoritesEditResultInvalidIndex,
};

// Favorites shared by the TV menu and Nebula Remote. Persists NSUserDefaults
// "FAVORITES" as an array of [url, title] string pairs (Foundation only).
@interface BrowserFavoritesStore : NSObject

+ (instancetype)standardStore;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Valid entries only, in stored order; each @{@"url": …, @"title": …}.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)favorites;

// A blank title falls back to the URL.
- (void)addURLString:(NSString *)URLString title:(nullable NSString *)title;
- (BrowserFavoritesEditResult)updateAtIndex:(NSUInteger)index
                          expectedURLString:(NSString *)expectedURLString
                                      title:(NSString *)title
                                  URLString:(NSString *)URLString;
- (BrowserFavoritesEditResult)removeAtIndex:(NSUInteger)index expectedURLString:(NSString *)expectedURLString;
- (BrowserFavoritesEditResult)moveFromIndex:(NSUInteger)index
                          expectedURLString:(NSString *)expectedURLString
                                    toIndex:(NSUInteger)toIndex;

@end

NS_ASSUME_NONNULL_END
