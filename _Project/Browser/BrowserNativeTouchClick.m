#import "BrowserNativeTouchClick.h"

#import <objc/message.h>

// Set for the lifetime of the two sendEvent: calls so the swizzled
// browser_sendEvent: knows this event is ours and passes it straight
// through (its scrub interceptor could otherwise eat touch events while a
// native player is paused).
static BOOL sBrowserSyntheticTapActive = NO;

BOOL BrowserNativeTouchClickTapIsActive(void) {
    return sBrowserSyntheticTapActive;
}

// Every private selector is resolved through NSSelectorFromString +
// respondsToSelector so a future OS that drops one simply makes
// isAvailable return NO instead of crashing.
@implementation BrowserNativeTouchClick

+ (NSArray<NSString *> *)requiredTouchSelectorNames {
    return @[
        @"setTimestamp:",
        @"setLocation:inView:",
        @"setTapCount:",
        @"_setIsFirstTouchForView:",
        @"_setPathIndex:",
        @"_setPathIdentity:",
        @"setPhase:",
    ];
}

+ (BOOL)isAvailable {
    Class touchClass = NSClassFromString(@"UITouch");
    Class eventClass = NSClassFromString(@"UIEvent");
    if (touchClass == Nil || eventClass == Nil) {
        return NO;
    }
    for (NSString *name in [self requiredTouchSelectorNames]) {
        if (![touchClass instancesRespondToSelector:NSSelectorFromString(name)]) {
            return NO;
        }
    }
    // setWindow:/setView: have underscored fallbacks; one of each pair
    // must respond.
    if (![touchClass instancesRespondToSelector:NSSelectorFromString(@"setWindow:")] &&
        ![touchClass instancesRespondToSelector:NSSelectorFromString(@"_setWindow:")]) {
        return NO;
    }
    if (![touchClass instancesRespondToSelector:NSSelectorFromString(@"setView:")] &&
        ![touchClass instancesRespondToSelector:NSSelectorFromString(@"_setView:")]) {
        return NO;
    }
    if (![eventClass instancesRespondToSelector:NSSelectorFromString(@"_setTimestamp:")] ||
        ![eventClass instancesRespondToSelector:NSSelectorFromString(@"_addTouch:forDelayedDelivery:")]) {
        return NO;
    }
    return YES;
}

+ (void)setTouchProperty:(UITouch *)touch withNames:(NSArray<NSString *> *)selectorNames setter:(void (^)(SEL))setter {
    for (NSString *name in selectorNames) {
        SEL selector = NSSelectorFromString(name);
        if ([touch respondsToSelector:selector]) {
            setter(selector);
            return;
        }
    }
}

+ (BOOL)tapAtWindowPoint:(CGPoint)windowPoint inWindow:(UIWindow *)window {
    if (window == nil) {
        return NO;
    }

    UIView *target = [window hitTest:windowPoint withEvent:nil];
    if (target == nil) {
        target = window;
    }

    BOOL sent = NO;
    @try {
        NSTimeInterval timestamp = [NSProcessInfo processInfo].systemUptime;

        Class touchClass = NSClassFromString(@"UITouch");
        Class eventClass = NSClassFromString(@"UIEvent");
        if (touchClass == Nil || eventClass == Nil) {
            return NO;
        }

        UITouch *touch = [[touchClass alloc] init];
        if (touch == nil) {
            return NO;
        }

        SEL setTimestampSelector = NSSelectorFromString(@"setTimestamp:");
        if ([touch respondsToSelector:setTimestampSelector]) {
            ((void (*)(id, SEL, double))objc_msgSend)(touch, setTimestampSelector, (double)timestamp);
        }

        [self setTouchProperty:touch withNames:@[ @"setWindow:", @"_setWindow:" ] setter:^(SEL selector) {
            ((void (*)(id, SEL, id))objc_msgSend)(touch, selector, window);
        }];
        [self setTouchProperty:touch withNames:@[ @"setView:", @"_setView:" ] setter:^(SEL selector) {
            ((void (*)(id, SEL, id))objc_msgSend)(touch, selector, target);
        }];

        SEL setLocationSelector = NSSelectorFromString(@"setLocation:inView:");
        if ([touch respondsToSelector:setLocationSelector]) {
            CGPoint location = windowPoint;
            ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(touch, setLocationSelector, location, window);
        }

        SEL setTapCountSelector = NSSelectorFromString(@"setTapCount:");
        if ([touch respondsToSelector:setTapCountSelector]) {
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(touch, setTapCountSelector, (NSUInteger)1);
        }

        SEL setFirstTouchSelector = NSSelectorFromString(@"_setIsFirstTouchForView:");
        if ([touch respondsToSelector:setFirstTouchSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(touch, setFirstTouchSelector, YES);
        }

        SEL setPathIndexSelector = NSSelectorFromString(@"_setPathIndex:");
        if ([touch respondsToSelector:setPathIndexSelector]) {
            ((void (*)(id, SEL, uint32_t))objc_msgSend)(touch, setPathIndexSelector, (uint32_t)0);
        }

        SEL setPathIdentitySelector = NSSelectorFromString(@"_setPathIdentity:");
        if ([touch respondsToSelector:setPathIdentitySelector]) {
            ((void (*)(id, SEL, uint32_t))objc_msgSend)(touch, setPathIdentitySelector, (uint32_t)0);
        }

        SEL setPhaseSelector = NSSelectorFromString(@"setPhase:");
        if (![touch respondsToSelector:setPhaseSelector]) {
            return NO;
        }
        ((void (*)(id, SEL, int))objc_msgSend)(touch, setPhaseSelector, (int)UITouchPhaseBegan);

        UIEvent *event = [[eventClass alloc] init];
        if (event == nil) {
            return NO;
        }

        SEL eventTimestampSelector = NSSelectorFromString(@"_setTimestamp:");
        if (![event respondsToSelector:eventTimestampSelector]) {
            return NO;
        }
        ((void (*)(id, SEL, double))objc_msgSend)(event, eventTimestampSelector, (double)timestamp);

        SEL addTouchSelector = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
        if (![event respondsToSelector:addTouchSelector]) {
            return NO;
        }
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addTouchSelector, touch, NO);

        sBrowserSyntheticTapActive = YES;
        [[UIApplication sharedApplication] sendEvent:event];

        // Same touch, ended a heartbeat later, delivered through the same event.
        ((void (*)(id, SEL, int))objc_msgSend)(touch, setPhaseSelector, (int)UITouchPhaseEnded);
        ((void (*)(id, SEL, double))objc_msgSend)(touch, setTimestampSelector, (double)(timestamp + 0.05));
        [[UIApplication sharedApplication] sendEvent:event];
        sBrowserSyntheticTapActive = NO;

        sent = YES;
        NSLog(@"[NativeClick] tap view=%@ windowPoint=%.0f,%.0f sent=%d", NSStringFromClass([target class]), windowPoint.x, windowPoint.y, sent);
    } @catch (NSException *exception) {
        sBrowserSyntheticTapActive = NO;
        NSLog(@"[NativeClick] failed: %@", exception);
        return NO;
    }
    return sent;
}

@end
