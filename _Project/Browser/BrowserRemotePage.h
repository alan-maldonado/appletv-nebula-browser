#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The Nebula Remote page served at GET / (inline CSS/JS/SVG, no external requests).
@interface BrowserRemotePage : NSObject

// accentHex: the TV theme accent (e.g. @"#7B6CDE"); onAccentHex: legible text on it.
+ (NSString *)HTMLWithAccentHex:(NSString *)accentHex onAccentHex:(NSString *)onAccentHex;

@end

NS_ASSUME_NONNULL_END
