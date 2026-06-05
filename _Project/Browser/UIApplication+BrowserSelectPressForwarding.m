#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const BrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
static BOOL sBrowserNativeScrubTracking = NO;
static CGFloat sBrowserNativePendingScrubPixels = 0.0;
static CGPoint sBrowserNativeLastTouchLocation = {0, 0};
static BOOL sBrowserNativeSwallowTouchSequence = NO;
static CGFloat sBrowserNativeScrubGain = 1.0;
static NSTimeInterval sBrowserNativeLastPausedScrubEnd = 0.0;
static CGFloat const kBrowserNativeScrubPixelStep = 18.0;
static NSTimeInterval const kBrowserNativeScrubChainInterval = 0.5;
static CGFloat const kBrowserNativeScrubMaxGain = 6.0;

static NSString *BrowserPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

static UIViewController *BrowserFindViewControllerOfClass(UIViewController *viewController, Class targetClass) {
    if (viewController == nil || targetClass == Nil) {
        return nil;
    }

    if ([viewController isKindOfClass:targetClass]) {
        return viewController;
    }

    if (viewController.presentedViewController != nil) {
        UIViewController *match = BrowserFindViewControllerOfClass(viewController.presentedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *childViewController in viewController.childViewControllers) {
        UIViewController *match = BrowserFindViewControllerOfClass(childViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(navigationController.visibleViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabBarController = (UITabBarController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(tabBarController.selectedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static BOOL BrowserNativePlayerIsEffectivelyPaused(UIViewController *viewController) {
    SEL pausedSelector = NSSelectorFromString(@"isEffectivelyPaused");
    if (viewController != nil && [viewController respondsToSelector:pausedSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(viewController, pausedSelector);
    }
    return NO;
}

static BOOL BrowserNativePlayerIsScanning(UIViewController *viewController) {
    SEL scanningSelector = NSSelectorFromString(@"isScanning");
    if (viewController != nil && [viewController respondsToSelector:scanningSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(viewController, scanningSelector);
    }
    return NO;
}

static BOOL BrowserNativePlayerHasCancelableSeekSession(UIViewController *viewController) {
    SEL sessionSelector = NSSelectorFromString(@"hasCancelableSeekSession");
    if (viewController != nil && [viewController respondsToSelector:sessionSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(viewController, sessionSelector);
    }
    return NO;
}

static UIViewController *BrowserFindPresentedNativeVideoPlayerViewController(UIApplication *application, Class nativeVideoPlayerClass) {
    for (UIWindow *window in application.windows) {
        if (window.hidden || window.rootViewController == nil) {
            continue;
        }

        UIViewController *match = BrowserFindViewControllerOfClass(window.rootViewController, nativeVideoPlayerClass);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

@interface UIApplication (BrowserSelectPressForwarding)

- (void)browser_sendEvent:(UIEvent *)event;

@end

@implementation UIApplication (BrowserSelectPressForwarding)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalMethod = class_getInstanceMethod(self, @selector(sendEvent:));
        Method replacementMethod = class_getInstanceMethod(self, @selector(browser_sendEvent:));
        if (originalMethod != NULL && replacementMethod != NULL) {
            method_exchangeImplementations(originalMethod, replacementMethod);
        }
    });
}

- (void)browser_sendEvent:(UIEvent *)event {
    Class nativeVideoPlayerClass = NSClassFromString(@"BrowserNativeVideoPlayerViewController");
    UIViewController *nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);

    if (event.type == UIEventTypeTouches) {
        SEL allTouchesSelector = NSSelectorFromString(@"allTouches");
        if ([event respondsToSelector:allTouchesSelector]) {
            NSSet<UITouch *> *touches = ((id (*)(id, SEL))objc_msgSend)(event, allTouchesSelector);
            for (UITouch *touch in touches) {
                if (touch.type != UITouchTypeIndirect) {
                    continue;
                }

                CGPoint location = [touch locationInView:nil];
                if (touch.phase == UITouchPhaseBegan) {
                    BOOL playerPresented = (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil);
                    BOOL paused = playerPresented && BrowserNativePlayerIsEffectivelyPaused(nativeVideoPlayerViewController);
                    sBrowserNativeScrubTracking = playerPresented;
                    // While paused we own scrubbing entirely: swallow the touch sequence so
                    // AVPlayerViewController's internal preview scrubber (whose commit we
                    // can't drive reliably from outside) never engages. Our seeks move the
                    // real playhead and the paused frame follows.
                    sBrowserNativeSwallowTouchSequence = paused;
                    if (paused) {
                        BOOL chained = (touch.timestamp - sBrowserNativeLastPausedScrubEnd) < kBrowserNativeScrubChainInterval;
                        sBrowserNativeScrubGain = chained ? MIN(sBrowserNativeScrubGain * 1.6, kBrowserNativeScrubMaxGain) : 1.0;
                        NSLog(@"[InputTrace][App] paused scrub began gain=%.1f", sBrowserNativeScrubGain);
                    } else {
                        sBrowserNativeScrubGain = 1.0;
                    }
                    sBrowserNativePendingScrubPixels = 0.0;
                    sBrowserNativeLastTouchLocation = location;
                    continue;
                }

                if (!sBrowserNativeScrubTracking || nativeVideoPlayerViewController == nil) {
                    continue;
                }

                if (touch.phase == UITouchPhaseMoved) {
                    CGFloat deltaX = (location.x - sBrowserNativeLastTouchLocation.x) * sBrowserNativeScrubGain;
                    sBrowserNativeLastTouchLocation = location;
                    sBrowserNativePendingScrubPixels += deltaX;

                    SEL scrubSelector = NSSelectorFromString(@"scrubByHorizontalDelta:");
                    if ([nativeVideoPlayerViewController respondsToSelector:scrubSelector]) {
                        // Coalesce whole steps into a single scrub call per move event.
                        CGFloat steps = trunc(sBrowserNativePendingScrubPixels / kBrowserNativeScrubPixelStep);
                        if (steps != 0.0) {
                            CGFloat pixels = steps * kBrowserNativeScrubPixelStep;
                            ((void (*)(id, SEL, CGFloat))objc_msgSend)(nativeVideoPlayerViewController, scrubSelector, pixels);
                            sBrowserNativePendingScrubPixels -= pixels;
                            NSLog(@"[InputTrace][App] scrub step delta=%.2f gain=%.1f", pixels, sBrowserNativeScrubGain);
                        }
                    }
                }

                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    if (sBrowserNativeSwallowTouchSequence) {
                        sBrowserNativeLastPausedScrubEnd = touch.timestamp;
                    }
                    sBrowserNativeScrubTracking = NO;
                    sBrowserNativePendingScrubPixels = 0.0;
                }
            }
        }

        if (sBrowserNativeSwallowTouchSequence) {
            // Paused-scrub touches never reach AVKit; flag is recomputed on the next Began.
            return;
        }

        [self browser_sendEvent:event];
        return;
    }

    if (event.type != UIEventTypePresses) {
        [self browser_sendEvent:event];
        return;
    }

    SEL allPressesSelector = NSSelectorFromString(@"allPresses");
    if (![event respondsToSelector:allPressesSelector]) {
        [self browser_sendEvent:event];
        return;
    }

    NSSet<UIPress *> *presses = ((id (*)(id, SEL))objc_msgSend)(event, allPressesSelector);
    for (UIPress *press in presses) {
        nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
            NSLog(@"[InputTrace][App] press=%@ phase=%@ top=%@",
                  BrowserPressTypeString(press.type),
                  BrowserPressPhaseString(press.phase),
                  nativeVideoPlayerViewController == nil ? @"(nil)" : NSStringFromClass([nativeVideoPlayerViewController class]));
        }

        if (press.type == UIPressTypeMenu) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                if (press.phase == UIPressPhaseBegan) {
                    // While fast-forwarding or mid scrub/skip exploration, Menu cancels
                    // and returns to where it started instead of closing the player.
                    SEL cancelScanSelector = NSSelectorFromString(@"cancelScanningAndReturnToOrigin");
                    SEL cancelSeekSelector = NSSelectorFromString(@"cancelSeekSessionAndReturnToOrigin");
                    UIViewController *playerViewController = nativeVideoPlayerViewController;
                    if (BrowserNativePlayerIsScanning(playerViewController) &&
                        [playerViewController respondsToSelector:cancelScanSelector]) {
                        NSLog(@"[InputTrace][App] swallow Menu: cancel scanning for native player");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ((void (*)(id, SEL))objc_msgSend)(playerViewController, cancelScanSelector);
                        });
                    } else if (BrowserNativePlayerHasCancelableSeekSession(playerViewController) &&
                               [playerViewController respondsToSelector:cancelSeekSelector]) {
                        NSLog(@"[InputTrace][App] swallow Menu: cancel seek session for native player");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ((void (*)(id, SEL))objc_msgSend)(playerViewController, cancelSeekSelector);
                        });
                    } else {
                        NSLog(@"[InputTrace][App] swallow Menu for native player");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [nativeVideoPlayerViewController dismissViewControllerAnimated:YES completion:nil];
                        });
                    }
                }
                return; // swallow every phase while the player is up
            }
        }

        if (press.type == UIPressTypeMenu) {
            // Safety net: in plain browsing state (nothing presented) Menu must NEVER
            // fall through to the system, which would suspend the app without warning.
            // Route it to the browser's back / double-back-to-exit handling instead.
            UIViewController *browserRootViewController = nil;
            SEL globalMenuSelector = NSSelectorFromString(@"browserHandleGlobalMenuPress");
            for (UIWindow *window in self.windows) {
                if (!window.hidden && [window.rootViewController respondsToSelector:globalMenuSelector]) {
                    browserRootViewController = window.rootViewController;
                    break;
                }
            }
            if (browserRootViewController != nil && browserRootViewController.presentedViewController == nil) {
                if (press.phase == UIPressPhaseEnded) {
                    NSLog(@"[InputTrace][App] swallow Menu globally (browser back/exit)");
                    UIViewController *targetViewController = browserRootViewController;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(targetViewController, globalMenuSelector);
                    });
                }
                return; // swallow every phase
            }
        }

        if ((press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    NSLog(@"[InputTrace][App] swallow %@ for native player",
                          BrowserPressTypeString(press.type));
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
                    });
                    return;
                }
            }
        }

        if (press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                // Swallow EVERY phase: if Began leaks through to AVPlayerViewController without
                // a matching Ended, it thinks the arrow is held down and starts its internal
                // scanning (runaway x2/x3 fast-forward that can't be cancelled).
                if (press.phase == UIPressPhaseEnded) {
                    SEL arrowSelector = (press.type == UIPressTypeRightArrow)
                        ? NSSelectorFromString(@"handleRightArrowPress")
                        : NSSelectorFromString(@"handleLeftArrowPress");
                    if ([nativeVideoPlayerViewController respondsToSelector:arrowSelector]) {
                        NSLog(@"[InputTrace][App] swallow %@ press for native player",
                              BrowserPressTypeString(press.type));
                        UIViewController *playerViewController = nativeVideoPlayerViewController;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ((void (*)(id, SEL))objc_msgSend)(playerViewController, arrowSelector);
                        });
                    }
                }
                return;
            }
        }
    }

    [self browser_sendEvent:event];

    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            NSLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil];
            });
            break;
        }
    }
}

@end
