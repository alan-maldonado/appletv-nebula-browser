#import "BrowserFavoritesStore.h"

NSNotificationName const BrowserFavoritesStoreDidChangeNotification = @"BrowserFavoritesStoreDidChangeNotification";

static NSString * const kBrowserFavoritesDefaultsKey = @"FAVORITES";

@interface BrowserFavoritesStore ()

@property (nonatomic) NSUserDefaults *defaults;

@end

@implementation BrowserFavoritesStore

+ (instancetype)standardStore {
    static BrowserFavoritesStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[BrowserFavoritesStore alloc] initWithDefaults:[NSUserDefaults standardUserDefaults]];
    });
    return store;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (self) {
        _defaults = defaults;
    }
    return self;
}

static NSString *BrowserTrimmed(NSString *string) {
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)favorites {
    NSMutableArray *favorites = [NSMutableArray array];
    for (id entry in [self.defaults arrayForKey:kBrowserFavoritesDefaultsKey]) {
        if (![entry isKindOfClass:[NSArray class]] || [entry count] == 0 || ![entry[0] isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *URLString = entry[0];
        if (URLString.length == 0) {
            continue;
        }
        // Older builds could store [url] alone; the menus showed the URL then.
        NSString *title = [entry count] > 1 && [entry[1] isKindOfClass:[NSString class]] ? entry[1] : @"";
        [favorites addObject:@{@"url": URLString, @"title": BrowserTrimmed(title).length > 0 ? title : URLString}];
    }
    return favorites;
}

- (void)saveFavorites:(NSArray<NSDictionary<NSString *, NSString *> *> *)favorites {
    NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:favorites.count];
    for (NSDictionary *favorite in favorites) {
        [pairs addObject:@[favorite[@"url"], favorite[@"title"]]];
    }
    [self.defaults setObject:pairs forKey:kBrowserFavoritesDefaultsKey];
    [self.defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:BrowserFavoritesStoreDidChangeNotification object:self];
}

- (void)addURLString:(NSString *)URLString title:(NSString *)title {
    NSString *storedTitle = BrowserTrimmed(title ?: @"").length > 0 ? title : URLString;
    NSMutableArray *favorites = [self.favorites mutableCopy];
    [favorites addObject:@{@"url": URLString, @"title": storedTitle}];
    [self saveFavorites:favorites];
}

- (BrowserFavoritesEditResult)checkIndex:(NSUInteger)index
                        expectedURLString:(NSString *)expectedURLString
                              inFavorites:(NSArray<NSDictionary *> *)favorites {
    if (index >= favorites.count) {
        return BrowserFavoritesEditResultInvalidIndex;
    }
    return [favorites[index][@"url"] isEqualToString:expectedURLString] ? BrowserFavoritesEditResultOK : BrowserFavoritesEditResultChanged;
}

- (BrowserFavoritesEditResult)updateAtIndex:(NSUInteger)index
                          expectedURLString:(NSString *)expectedURLString
                                      title:(NSString *)title
                                  URLString:(NSString *)URLString {
    NSMutableArray *favorites = [self.favorites mutableCopy];
    BrowserFavoritesEditResult result = [self checkIndex:index expectedURLString:expectedURLString inFavorites:favorites];
    if (result != BrowserFavoritesEditResultOK) {
        return result;
    }
    favorites[index] = @{@"url": URLString, @"title": BrowserTrimmed(title).length > 0 ? title : URLString};
    [self saveFavorites:favorites];
    return BrowserFavoritesEditResultOK;
}

- (BrowserFavoritesEditResult)removeAtIndex:(NSUInteger)index expectedURLString:(NSString *)expectedURLString {
    NSMutableArray *favorites = [self.favorites mutableCopy];
    BrowserFavoritesEditResult result = [self checkIndex:index expectedURLString:expectedURLString inFavorites:favorites];
    if (result != BrowserFavoritesEditResultOK) {
        return result;
    }
    [favorites removeObjectAtIndex:index];
    [self saveFavorites:favorites];
    return BrowserFavoritesEditResultOK;
}

- (BrowserFavoritesEditResult)moveFromIndex:(NSUInteger)index
                          expectedURLString:(NSString *)expectedURLString
                                    toIndex:(NSUInteger)toIndex {
    NSMutableArray *favorites = [self.favorites mutableCopy];
    if (toIndex >= favorites.count) {
        return BrowserFavoritesEditResultInvalidIndex;
    }
    BrowserFavoritesEditResult result = [self checkIndex:index expectedURLString:expectedURLString inFavorites:favorites];
    if (result != BrowserFavoritesEditResultOK) {
        return result;
    }
    NSDictionary *favorite = favorites[index];
    [favorites removeObjectAtIndex:index];
    [favorites insertObject:favorite atIndex:toIndex];
    [self saveFavorites:favorites];
    return BrowserFavoritesEditResultOK;
}

@end
