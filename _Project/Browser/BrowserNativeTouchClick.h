#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// True between the Began and Ended sends of tapAtWindowPoint:inWindow:.
// The UIApplication+BrowserSelectPressForwarding swizzle checks this so a
// synthetic tap is never swallowed by the paused-scrub interceptor.
BOOL BrowserNativeTouchClickTapIsActive(void);

// Synthesizes a REAL UITouch tap (Began/Ended) through UIApplication's
// event pipeline so WebKit delivers a trusted click at the given screen
// point. Unlike JS synthetic events this passes isTrusted checks and can
// land inside cross-origin iframes (CAPTCHA/Trustwall modals).
@interface BrowserNativeTouchClick : NSObject

// YES only if every private selector the synthesis needs responds on the
// current OS. Callers must fall back to the JS path when this is NO.
+ (BOOL)isAvailable;

// YES when the Began/Ended pair was sent.
+ (BOOL)tapAtWindowPoint:(CGPoint)windowPoint inWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
