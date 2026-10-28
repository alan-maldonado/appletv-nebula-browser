#import "BrowserRemoteState.h"

static NSTimeInterval const kBrowserRemoteMediaDriftTolerance = 1.0;

@interface BrowserRemoteState ()

@property (nonatomic, readwrite) NSUInteger version;
@property (nonatomic) NSMutableDictionary<NSString *, id> *sections;
// The media section's time was sampled at mediaTime (same clock as updateMedia:now:).
@property (nonatomic) NSTimeInterval mediaTime;

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
            @"media": NSNull.null,
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

// Where the stored playhead would be at now, clamped to the duration.
- (NSTimeInterval)mediaPlayheadAtTime:(NSTimeInterval)now {
    NSDictionary *media = self.sections[@"media"];
    NSTimeInterval time = [media[@"time"] doubleValue];
    if ([media[@"playing"] boolValue]) {
        time += MAX(0.0, now - self.mediaTime) * [media[@"rate"] doubleValue];
    }
    if ([media[@"duration"] isKindOfClass:[NSNumber class]]) {
        time = MIN(time, [media[@"duration"] doubleValue]);
    }
    return time;
}

- (void)updateMedia:(NSDictionary *)media now:(NSTimeInterval)now {
    if (media == nil) {
        [self setSection:@"media" value:NSNull.null];
        return;
    }
    NSDictionary *current = self.sections[@"media"];
    id duration = [media[@"duration"] isKindOfClass:[NSNumber class]] && isfinite([media[@"duration"] doubleValue])
        ? @(round([media[@"duration"] doubleValue] * 10.0) / 10.0)
        : NSNull.null;
    NSDictionary *next = @{
        @"source": media[@"source"] ?: @"",
        @"title": media[@"title"] ?: @"",
        @"time": @(round(MAX(0.0, [media[@"time"] doubleValue]) * 10.0) / 10.0),
        @"duration": duration,
        @"playing": @([media[@"playing"] boolValue]),
        @"rate": @([media[@"rate"] doubleValue] > 0.0 ? [media[@"rate"] doubleValue] : 1.0),
        @"fullscreen": @([media[@"fullscreen"] boolValue]),
    };
    if ([current isKindOfClass:[NSDictionary class]]) {
        BOOL sameShape = YES;
        for (NSString *key in @[@"source", @"title", @"playing", @"rate", @"fullscreen"]) {
            sameShape = sameShape && [current[key] isEqual:next[key]];
        }
        BOOL sameDuration = [current[@"duration"] isKindOfClass:[NSNumber class]] && [duration isKindOfClass:[NSNumber class]]
            ? fabs([current[@"duration"] doubleValue] - [duration doubleValue]) < kBrowserRemoteMediaDriftTolerance
            : [current[@"duration"] isEqual:duration];
        NSTimeInterval drift = fabs([self mediaPlayheadAtTime:now] - [next[@"time"] doubleValue]);
        if (sameShape && sameDuration && drift <= kBrowserRemoteMediaDriftTolerance) {
            return;
        }
    }
    self.sections[@"media"] = next;
    self.mediaTime = now;
    self.version += 1;
}

- (NSDictionary *)JSONObjectAtTime:(NSTimeInterval)now {
    NSMutableDictionary *JSONObject = [self.sections mutableCopy];
    JSONObject[@"v"] = @(self.version);
    if ([JSONObject[@"media"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *media = [JSONObject[@"media"] mutableCopy];
        media[@"time"] = @(round([self mediaPlayheadAtTime:now] * 10.0) / 10.0);
        JSONObject[@"media"] = media;
    }
    return JSONObject;
}

- (NSDictionary *)JSONObject {
    return [self JSONObjectAtTime:NSProcessInfo.processInfo.systemUptime];
}

@end
