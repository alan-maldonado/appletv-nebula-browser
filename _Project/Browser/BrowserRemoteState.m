#import "BrowserRemoteState.h"

@interface BrowserRemoteState ()

@property (nonatomic, readwrite) NSUInteger version;
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, copy) NSString *pageURLString;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *field;

@end

@implementation BrowserRemoteState

- (instancetype)init {
    self = [super init];
    if (self) {
        _version = 1;
        _pageTitle = @"";
        _pageURLString = @"";
    }
    return self;
}

- (void)updatePageTitle:(NSString *)title URLString:(NSString *)URLString {
    NSString *newTitle = title ?: @"";
    NSString *newURLString = URLString ?: @"";
    if ([newTitle isEqualToString:self.pageTitle] && [newURLString isEqualToString:self.pageURLString]) {
        return;
    }
    self.pageTitle = newTitle;
    self.pageURLString = newURLString;
    self.version += 1;
}

- (void)updateField:(NSDictionary<NSString *, NSString *> *)field {
    if (field == self.field || [field isEqualToDictionary:self.field]) {
        return;
    }
    self.field = field;
    self.version += 1;
}

- (NSDictionary *)JSONObject {
    return @{
        @"v": @(self.version),
        @"page": @{@"title": self.pageTitle, @"url": self.pageURLString},
        @"field": self.field ?: NSNull.null,
    };
}

@end
