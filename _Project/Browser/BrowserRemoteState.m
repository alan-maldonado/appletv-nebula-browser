#import "BrowserRemoteState.h"

@interface BrowserRemoteState ()

@property (nonatomic, readwrite) NSUInteger version;
@property (nonatomic) NSMutableDictionary<NSString *, id> *sections;

@end

@implementation BrowserRemoteState

- (instancetype)init {
    self = [super init];
    if (self) {
        _version = 1;
        _sections = [@{
            @"page": @{@"title": @"", @"url": @""},
            @"field": NSNull.null,
            @"tabs": @[],
            @"favorites": @[],
            @"home": @{@"url": @"", @"launch": @"last-session"},
            @"theme": @{@"accent": @"#7B6CDE", @"onAccent": @"#FFFFFF"},
        } mutableCopy];
    }
    return self;
}

// Stores a section and bumps the version only when its value changed.
- (void)setSection:(NSString *)key value:(id)value {
    if ([self.sections[key] isEqual:value]) {
        return;
    }
    self.sections[key] = [value copy];
    self.version += 1;
}

- (void)updatePageTitle:(NSString *)title URLString:(NSString *)URLString {
    [self setSection:@"page" value:@{@"title": title ?: @"", @"url": URLString ?: @""}];
}

- (void)updateField:(NSDictionary<NSString *, NSString *> *)field {
    [self setSection:@"field" value:field ?: NSNull.null];
}

- (void)updateTabs:(NSArray<NSDictionary *> *)tabs {
    [self setSection:@"tabs" value:tabs ?: @[]];
}

- (void)updateFavorites:(NSArray<NSDictionary *> *)favorites {
    [self setSection:@"favorites" value:favorites ?: @[]];
}

- (void)updateHome:(NSDictionary *)home {
    [self setSection:@"home" value:home];
}

- (void)updateTheme:(NSDictionary *)theme {
    [self setSection:@"theme" value:theme];
}

- (NSDictionary *)JSONObject {
    NSMutableDictionary *JSONObject = [self.sections mutableCopy];
    JSONObject[@"v"] = @(self.version);
    return JSONObject;
}

@end
