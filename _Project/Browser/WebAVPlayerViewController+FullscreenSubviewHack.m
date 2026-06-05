#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL const kBrowserFullscreenHackEnabled = NO;


static void (*BrowserOriginalConfigurePlayerViewController)(id self, SEL _cmd, void *fullscreenInterface) = NULL;
static const ptrdiff_t kBrowserPlayerControllerHostOffset = 0x20;
static const ptrdiff_t kBrowserFullscreenInterfacePlayerLayerViewOffset = 0x58;
static const void *kBrowserFullscreenHackAssociatedViewsKey = &kBrowserFullscreenHackAssociatedViewsKey;
static BOOL const kBrowserFullscreenHackLoggingEnabled = YES;
static BOOL const kBrowserFullscreenHackMethodDumpEnabled = YES;

#define BrowserFullscreenHackLog(fmt, ...) \
    do { \
        if (kBrowserFullscreenHackLoggingEnabled) { \
            NSLog((@"[FullscreenHack] " fmt), ##__VA_ARGS__); \
        } \
    } while (0)

static BOOL BrowserFullscreenHackSelectorLooksInteresting(SEL selector) {
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    NSArray<NSString *> *needles = @[
        @"player",
        @"video",
        @"display",
        @"visible",
        @"render",
        @"attach",
        @"ready",
        @"layer",
        @"controller"
    ];

    for (NSString *needle in needles) {
        if ([name containsString:needle]) {
            return YES;
        }
    }

    return NO;
}

static void BrowserFullscreenHackDumpMethodsForClass(Class cls) {
    if (!kBrowserFullscreenHackMethodDumpEnabled || cls == Nil) {
        return;
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    NSMutableArray<NSString *> *interestingNames = [NSMutableArray array];
    for (unsigned int index = 0; index < methodCount; index++) {
        SEL selector = method_getName(methods[index]);
        if (!BrowserFullscreenHackSelectorLooksInteresting(selector)) {
            continue;
        }
        [interestingNames addObject:NSStringFromSelector(selector)];
    }
    free(methods);

    [interestingNames sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    BrowserFullscreenHackLog(@"method dump for %@: %@", NSStringFromClass(cls), interestingNames);
}

static Method BrowserFullscreenHackInstanceMethod(id object, NSString *selectorName) {
    if (object == nil) {
        return NULL;
    }
    return class_getInstanceMethod([object class], NSSelectorFromString(selectorName));
}

static id BrowserFullscreenHackObjectForSelectorName(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL BrowserFullscreenHackBoolForSelectorName(id object, NSString *selectorName, BOOL *didRespond) {
    if (didRespond != NULL) {
        *didRespond = NO;
    }

    if (object == nil || selectorName.length == 0) {
        return NO;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }

    if (didRespond != NULL) {
        *didRespond = YES;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGRect BrowserFullscreenHackRectForSelectorName(id object, NSString *selectorName, BOOL *didRespond) {
    if (didRespond != NULL) {
        *didRespond = NO;
    }

    if (object == nil || selectorName.length == 0) {
        return CGRectZero;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return CGRectZero;
    }

    if (didRespond != NULL) {
        *didRespond = YES;
    }
    return ((CGRect (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL BrowserViewIsDescendantOfView(UIView *view, UIView *ancestor) {
    if (view == nil || ancestor == nil) {
        return NO;
    }

    for (UIView *current = view; current != nil; current = current.superview) {
        if (current == ancestor) {
            return YES;
        }
    }

    return NO;
}

static void BrowserFullscreenHackDumpRelevantClassesOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BrowserFullscreenHackDumpMethodsForClass(objc_getClass("WebAVPlayerLayerView"));
        BrowserFullscreenHackDumpMethodsForClass(objc_getClass("WebAVPlayerLayer"));
        BrowserFullscreenHackDumpMethodsForClass(objc_getClass("__AVPlayerLayerView"));
    });
}

@interface BrowserFullscreenPlayerLayerView : UIView

@property (nonatomic, strong) id pixelBufferAttributes;
@property (nonatomic, strong) id playerController;
@property (nonatomic, assign) UIEdgeInsets legibleContentInsets;
@property (nonatomic, strong) UIView *embeddedVideoView;
@property (nonatomic, strong) AVPlayer *currentPlayer;
@property (nonatomic, strong) id currentPlayerControllerObject;
@property (nonatomic, assign) CGSize sourceVideoDimensions;
@property (nonatomic, strong) UIView *sourceWebPlayerLayerView;

- (id)playerLayer;
- (void)transferVideoViewTo:(UIView *)view;
- (BOOL)avkit_isVisible;
- (UIWindow *)avkit_window;
- (CGRect)avkit_videoRectInWindow;

@end

@implementation BrowserFullscreenPlayerLayerView

+ (Class)layerClass {
    return [AVPlayerLayer class];
}

- (CGRect)browser_screenBoundsFallback {
    UIWindow *window = self.window;
    if (window.windowScene.screen.bounds.size.width > 0.0 && window.windowScene.screen.bounds.size.height > 0.0) {
        return window.windowScene.screen.bounds;
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.screen.bounds.size.width > 0.0 && windowScene.screen.bounds.size.height > 0.0) {
            return windowScene.screen.bounds;
        }
    }

    return CGRectZero;
}

- (CGRect)browser_fallbackBounds {
    if (self.superview.bounds.size.width > 0.0 && self.superview.bounds.size.height > 0.0) {
        return self.superview.bounds;
    }

    if (self.window.bounds.size.width > 0.0 && self.window.bounds.size.height > 0.0) {
        return self.window.bounds;
    }

    return [self browser_screenBoundsFallback];
}

- (CGRect)browser_effectiveBounds {
    if (self.bounds.size.width > 0.0 && self.bounds.size.height > 0.0) {
        return self.bounds;
    }

    return [self browser_fallbackBounds];
}

- (AVPlayerLayer *)browser_playerLayer {
    return (AVPlayerLayer *)self.layer;
}

- (AVPlayerLayer *)browser_embeddedPlayerLayer {
    SEL selector = NSSelectorFromString(@"playerLayer");
    if (self.embeddedVideoView != nil && [self.embeddedVideoView respondsToSelector:selector]) {
        id layer = ((id (*)(id, SEL))objc_msgSend)(self.embeddedVideoView, selector);
        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            return layer;
        }
    }

    if ([self.embeddedVideoView.layer isKindOfClass:[AVPlayerLayer class]]) {
        return (AVPlayerLayer *)self.embeddedVideoView.layer;
    }

    return nil;
}

- (void)browser_applyPlayer:(AVPlayer *)player toLayerObject:(id)layerObject {
    if (player == nil || layerObject == nil) {
        return;
    }

    NSArray<NSString *> *selectors = @[@"setPlayer:", @"setAVPlayer:", @"setPlayerIfNeeded:"];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![layerObject respondsToSelector:selector]) {
            continue;
        }

        ((void (*)(id, SEL, id))objc_msgSend)(layerObject, selector, player);
        BrowserFullscreenHackLog(@"applied AVPlayer %@ to layer object %@ via %@", player, layerObject, selectorName);
        break;
    }
}

- (void)browser_applyPlayerControllerObject:(id)playerControllerObject toObject:(id)object {
    if (playerControllerObject == nil || object == nil) {
        return;
    }

    NSArray<NSString *> *selectors = @[
        @"setPlayerController:",
        @"setPlaybackController:",
        @"setPlayerControllerIfNeeded:",
        @"setVideoViewController:",
        @"setAVPlayerController:"
    ];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) {
            continue;
        }

        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, playerControllerObject);
        BrowserFullscreenHackLog(@"applied player controller %@ to object %@ via %@",
                                 playerControllerObject,
                                 object,
                                 selectorName);
        break;
    }
}

- (void)browser_applyVideoView:(UIView *)videoView toObject:(id)object {
    if (videoView == nil || object == nil) {
        return;
    }

    SEL selector = NSSelectorFromString(@"setVideoView:");
    if (![object respondsToSelector:selector]) {
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, videoView);
    BrowserFullscreenHackLog(@"applied video view %@ to object %@ via setVideoView:", videoView, object);
}

- (void)browser_applyVideoSublayer:(CALayer *)videoSublayer toObject:(id)object {
    if (videoSublayer == nil || object == nil) {
        return;
    }

    SEL selector = NSSelectorFromString(@"setVideoSublayer:");
    if (![object respondsToSelector:selector]) {
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, videoSublayer);
    BrowserFullscreenHackLog(@"applied video sublayer %@ to object %@ via setVideoSublayer:", videoSublayer, object);
}

- (void)browser_applyReadyForDisplay:(BOOL)readyForDisplay toObject:(id)object {
    if (object == nil) {
        return;
    }

    SEL selector = NSSelectorFromString(@"setReadyForDisplay:");
    if (![object respondsToSelector:selector]) {
        return;
    }

    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, readyForDisplay);
    BrowserFullscreenHackLog(@"applied readyForDisplay=%@ to object %@ via setReadyForDisplay:",
                             readyForDisplay ? @"YES" : @"NO",
                             object);
}

- (void)browser_applyVideoDimensions:(CGSize)videoDimensions toObject:(id)object {
    if (object == nil || videoDimensions.width <= 0.0 || videoDimensions.height <= 0.0) {
        return;
    }

    SEL selector = NSSelectorFromString(@"setVideoDimensions:");
    if (![object respondsToSelector:selector]) {
        return;
    }

    Method method = BrowserFullscreenHackInstanceMethod(object, @"setVideoDimensions:");
    const char *typeEncoding = method != NULL ? method_getTypeEncoding(method) : NULL;
    NSString *encodingString = typeEncoding != NULL ? [NSString stringWithUTF8String:typeEncoding] : @"";
    if ([encodingString containsString:@"{CGSize"]) {
        ((void (*)(id, SEL, CGSize))objc_msgSend)(object, selector, videoDimensions);
    } else {
        NSValue *dimensionsValue = [NSValue valueWithCGSize:videoDimensions];
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, dimensionsValue);
    }
    BrowserFullscreenHackLog(@"applied videoDimensions=%@ to object %@ via setVideoDimensions: encoding=%@",
                             NSStringFromCGSize(videoDimensions),
                             object,
                             encodingString);
}

- (void)browser_applyVideoGravity:(NSString *)videoGravity toLayerObject:(id)layerObject {
    if (videoGravity.length == 0 || layerObject == nil) {
        return;
    }

    NSArray<NSString *> *selectors = @[@"setVideoGravity:", @"setAVLayerVideoGravity:"];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![layerObject respondsToSelector:selector]) {
            continue;
        }

        ((void (*)(id, SEL, id))objc_msgSend)(layerObject, selector, videoGravity);
        BrowserFullscreenHackLog(@"applied videoGravity %@ to layer object %@ via %@", videoGravity, layerObject, selectorName);
        break;
    }
}

- (void)browser_applyBoolean:(BOOL)value selectorName:(NSString *)selectorName toObject:(id)object {
    if (object == nil || selectorName.length == 0) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return;
    }

    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    BrowserFullscreenHackLog(@"applied %@=%@ to object %@",
                             selectorName,
                             value ? @"YES" : @"NO",
                             object);
}

- (void)browser_forceLayoutAndActivationOnDestinationView:(UIView *)view {
    if (view == nil) {
        return;
    }

    [view setNeedsLayout];
    [view layoutIfNeeded];
    [view.layer setNeedsLayout];

    SEL layoutSublayersSelector = NSSelectorFromString(@"layoutSublayers");
    if ([view.layer respondsToSelector:layoutSublayersSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(view.layer, layoutSublayersSelector);
        BrowserFullscreenHackLog(@"forced layoutSublayers on %@", view.layer);
    }

    SEL calculateTargetVideoFrameSelector = NSSelectorFromString(@"calculateTargetVideoFrame");
    if ([view.layer respondsToSelector:calculateTargetVideoFrameSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(view.layer, calculateTargetVideoFrameSelector);
        BrowserFullscreenHackLog(@"forced calculateTargetVideoFrame on %@", view.layer);
    }
}

- (void)browser_forceDestinationGeometry:(UIView *)view preferredBounds:(CGRect)preferredBounds {
    if (view == nil || preferredBounds.size.width <= 0.0 || preferredBounds.size.height <= 0.0) {
        return;
    }

    CGRect containerBounds = CGRectZero;
    if (view.superview.bounds.size.width > 0.0 && view.superview.bounds.size.height > 0.0) {
        containerBounds = view.superview.bounds;
    } else if (view.window.bounds.size.width > 0.0 && view.window.bounds.size.height > 0.0) {
        containerBounds = view.window.bounds;
    } else {
        containerBounds = preferredBounds;
    }

    CGRect targetFrame = CGRectMake(0.0, 0.0, preferredBounds.size.width, preferredBounds.size.height);
    if (containerBounds.size.width >= preferredBounds.size.width &&
        containerBounds.size.height >= preferredBounds.size.height) {
        targetFrame.origin.x = floor((containerBounds.size.width - preferredBounds.size.width) / 2.0);
        targetFrame.origin.y = floor((containerBounds.size.height - preferredBounds.size.height) / 2.0);
    }

    view.bounds = CGRectMake(0.0, 0.0, preferredBounds.size.width, preferredBounds.size.height);
    view.frame = targetFrame;
    view.center = CGPointMake(CGRectGetMidX(targetFrame), CGRectGetMidY(targetFrame));

    view.layer.bounds = view.bounds;
    view.layer.frame = view.bounds;
    view.layer.position = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    [view setNeedsLayout];
    [view layoutIfNeeded];
    [view setNeedsDisplay];
    [view.layer setNeedsLayout];
    [view.layer setNeedsDisplay];

    BrowserFullscreenHackLog(@"forced destination geometry on %@ frame=%@ bounds=%@",
                             view,
                             NSStringFromCGRect(view.frame),
                             NSStringFromCGRect(view.bounds));
}

- (void)browser_logDestinationState:(UIView *)view label:(NSString *)label {
    if (view == nil) {
        return;
    }

    id destinationVideoView = BrowserFullscreenHackObjectForSelectorName(view, @"videoView");
    id destinationPlayerController = BrowserFullscreenHackObjectForSelectorName(view, @"playerController");
    id destinationLayerPlayerController = BrowserFullscreenHackObjectForSelectorName(view.layer, @"playerController");
    id destinationVideoSublayer = BrowserFullscreenHackObjectForSelectorName(view.layer, @"videoSublayer");
    BOOL didRespondReady = NO;
    BOOL readyForDisplay = BrowserFullscreenHackBoolForSelectorName(view.layer, @"isReadyForDisplay", &didRespondReady);
    BOOL didRespondVideoRect = NO;
    CGRect videoRect = BrowserFullscreenHackRectForSelectorName(view.layer, @"videoRect", &didRespondVideoRect);

    BrowserFullscreenHackLog(@"destination state[%@] view=%@ frame=%@ bounds=%@ videoView=%@(%@) playerController=%@(%@) layerPlayerController=%@(%@) videoSublayer=%@(%@) ready=%@ videoRect=%@",
                             label,
                             view,
                             NSStringFromCGRect(view.frame),
                             NSStringFromCGRect(view.bounds),
                             destinationVideoView,
                             destinationVideoView == nil ? @"nil" : NSStringFromClass([destinationVideoView class]),
                             destinationPlayerController,
                             destinationPlayerController == nil ? @"nil" : NSStringFromClass([destinationPlayerController class]),
                             destinationLayerPlayerController,
                             destinationLayerPlayerController == nil ? @"nil" : NSStringFromClass([destinationLayerPlayerController class]),
                             destinationVideoSublayer,
                             destinationVideoSublayer == nil ? @"nil" : NSStringFromClass([destinationVideoSublayer class]),
                             didRespondReady ? (readyForDisplay ? @"YES" : @"NO") : @"n/a",
                             didRespondVideoRect ? NSStringFromCGRect(videoRect) : @"n/a");
}

- (void)browser_attemptSourceWebTransferToDestination:(UIView *)destinationView {
    if (self.sourceWebPlayerLayerView == nil || destinationView == nil) {
        return;
    }

    SEL transferSelector = @selector(transferVideoViewTo:);
    if (![self.sourceWebPlayerLayerView respondsToSelector:transferSelector]) {
        return;
    }

    BrowserFullscreenHackLog(@"attempting source WebAVPlayerLayerView transfer %@ -> %@",
                             self.sourceWebPlayerLayerView,
                             destinationView);
    ((void (*)(id, SEL, id))objc_msgSend)(self.sourceWebPlayerLayerView, transferSelector, destinationView);
}

- (BOOL)browser_embeddedVideoReadyForDisplay {
    SEL selector = NSSelectorFromString(@"isReadyForDisplay");
    if (self.embeddedVideoView != nil && [self.embeddedVideoView respondsToSelector:selector]) {
        BOOL ready = ((BOOL (*)(id, SEL))objc_msgSend)(self.embeddedVideoView, selector);
        if (ready) {
            return YES;
        }
    }

    AVPlayerLayer *embeddedLayer = [self browser_embeddedPlayerLayer];
    if (embeddedLayer.isReadyForDisplay) {
        return YES;
    }

    if (self.currentPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay ||
        self.currentPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying ||
        self.currentPlayer.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
        return YES;
    }

    return ([self browser_embeddedVideoDimensions].width > 0.0 &&
            [self browser_embeddedVideoDimensions].height > 0.0 &&
            self.currentPlayer != nil);
}

- (CGSize)browser_embeddedVideoDimensions {
    SEL videoBoundsSelector = NSSelectorFromString(@"videoBounds");
    if (self.embeddedVideoView != nil && [self.embeddedVideoView respondsToSelector:videoBoundsSelector]) {
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self.embeddedVideoView, videoBoundsSelector);
        if (bounds.size.width > 0.0 && bounds.size.height > 0.0) {
            return bounds.size;
        }
    }

    AVPlayerLayer *embeddedLayer = [self browser_embeddedPlayerLayer];
    CGRect videoRect = embeddedLayer.videoRect;
    if (videoRect.size.width > 0.0 && videoRect.size.height > 0.0) {
        return videoRect.size;
    }

    CGSize presentationSize = self.currentPlayer.currentItem.presentationSize;
    if (presentationSize.width > 0.0 && presentationSize.height > 0.0) {
        return presentationSize;
    }

    if (self.sourceVideoDimensions.width > 0.0 && self.sourceVideoDimensions.height > 0.0) {
        return self.sourceVideoDimensions;
    }

    if (self.embeddedVideoView.frame.size.width > 0.0 && self.embeddedVideoView.frame.size.height > 0.0) {
        return self.embeddedVideoView.frame.size;
    }

    return self.embeddedVideoView.bounds.size;
}

- (id)playerLayer {
    AVPlayerLayer *embeddedLayer = [self browser_embeddedPlayerLayer];
    return embeddedLayer != nil ? embeddedLayer : [self browser_playerLayer];
}

- (NSString *)videoGravity {
    AVPlayerLayer *playerLayer = [self browser_embeddedPlayerLayer] ?: [self browser_playerLayer];
    return playerLayer.videoGravity;
}

- (void)setVideoGravity:(NSString *)videoGravity {
    [self browser_playerLayer].videoGravity = videoGravity;
    AVPlayerLayer *embeddedLayer = [self browser_embeddedPlayerLayer];
    if (embeddedLayer != nil) {
        embeddedLayer.videoGravity = videoGravity;
    }
}

- (AVPlayer *)browser_extractPlayerFromObject:(id)object {
    if ([object isKindOfClass:[AVPlayer class]]) {
        BrowserFullscreenHackLog(@"player controller is AVPlayer directly: %@", object);
        return object;
    }

    NSArray<NSString *> *selectors = @[@"player", @"avPlayer", @"_player", @"currentPlayer"];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) {
            continue;
        }

        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:[AVPlayer class]]) {
            BrowserFullscreenHackLog(@"found AVPlayer via selector %@ on %@ (%@)", selectorName, object, NSStringFromClass([object class]));
            return value;
        }
    }

    BrowserFullscreenHackLog(@"no AVPlayer found on %@ (%@)", object, object == nil ? @"nil" : NSStringFromClass([object class]));
    return nil;
}

- (void)setPlayerController:(id)playerController {
    _playerController = playerController;
    self.currentPlayerControllerObject = playerController;
    BrowserFullscreenHackLog(@"setPlayerController: %@ (%@)", playerController, playerController == nil ? @"nil" : NSStringFromClass([playerController class]));
    AVPlayer *player = [self browser_extractPlayerFromObject:playerController];
    if (player != nil) {
        self.currentPlayer = player;
        [self browser_playerLayer].player = player;
        AVPlayerLayer *embeddedLayer = [self browser_embeddedPlayerLayer];
        if (embeddedLayer != nil) {
            embeddedLayer.player = player;
        }
        BrowserFullscreenHackLog(@"bound AVPlayer %@ to synthetic player layer", player);
    }
}

- (void)browser_configureFromExistingPlayerLayer:(AVPlayerLayer *)playerLayer {
    if (playerLayer == nil) {
        return;
    }

    AVPlayerLayer *targetLayer = [self browser_playerLayer];
    targetLayer.player = playerLayer.player;
    targetLayer.videoGravity = playerLayer.videoGravity;
    BrowserFullscreenHackLog(@"copied existing AVPlayerLayer state from %@ to synthetic layer %@", playerLayer, targetLayer);
}

- (void)browser_embedVideoView:(UIView *)videoView {
    if (videoView == nil) {
        return;
    }

    _embeddedVideoView = videoView;
    _embeddedVideoView.hidden = NO;
    [self browser_applyBoolean:YES selectorName:@"setVideoScaled:" toObject:_embeddedVideoView];
    [self browser_applyPlayerControllerObject:self.currentPlayerControllerObject toObject:_embeddedVideoView];
    [self browser_applyVideoGravity:self.videoGravity toLayerObject:_embeddedVideoView];
    if (videoView.frame.size.width > 0.0 && videoView.frame.size.height > 0.0) {
        self.sourceVideoDimensions = videoView.frame.size;
    } else if (videoView.bounds.size.width > 0.0 && videoView.bounds.size.height > 0.0) {
        self.sourceVideoDimensions = videoView.bounds.size;
    } else if ([self browser_embeddedPlayerLayer].videoRect.size.width > 0.0 &&
               [self browser_embeddedPlayerLayer].videoRect.size.height > 0.0) {
        self.sourceVideoDimensions = [self browser_embeddedPlayerLayer].videoRect.size;
    }

    if (_embeddedVideoView.superview != self) {
        [_embeddedVideoView removeFromSuperview];
        _embeddedVideoView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_embeddedVideoView];
        [NSLayoutConstraint activateConstraints:@[
            [_embeddedVideoView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_embeddedVideoView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_embeddedVideoView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_embeddedVideoView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }

    _embeddedVideoView.frame = [self browser_effectiveBounds];
    [self sendSubviewToBack:_embeddedVideoView];
    BrowserFullscreenHackLog(@"embedded source video view %@ (%@) into synthetic view",
                             videoView,
                             NSStringFromClass([videoView class]));
}

- (void)setPixelBufferAttributes:(id)pixelBufferAttributes {
    _pixelBufferAttributes = pixelBufferAttributes;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect effectiveBounds = [self browser_effectiveBounds];
    if (!CGRectEqualToRect(self.bounds, effectiveBounds)) {
        self.frame = effectiveBounds;
    }
    self.embeddedVideoView.frame = effectiveBounds;
}

- (void)transferVideoViewTo:(UIView *)view {
    if (view == nil || view == self) {
        return;
    }

    SEL transferSelector = @selector(transferVideoViewTo:);
    if (self.embeddedVideoView != nil && [self.embeddedVideoView respondsToSelector:transferSelector]) {
        BrowserFullscreenHackLog(@"forwarding transferVideoViewTo: from synthetic view to embedded video view %@ (%@) -> %@ (%@)",
                                 self.embeddedVideoView,
                                 NSStringFromClass([self.embeddedVideoView class]),
                                 view,
                                 NSStringFromClass([view class]));
        ((void (*)(id, SEL, id))objc_msgSend)(self.embeddedVideoView, transferSelector, view);
    }

    [self browser_attemptSourceWebTransferToDestination:view];

    CGRect targetBounds = view.bounds;
    if (targetBounds.size.width <= 0.0 || targetBounds.size.height <= 0.0) {
        targetBounds = view.window.bounds;
    }
    if (targetBounds.size.width <= 0.0 || targetBounds.size.height <= 0.0) {
        targetBounds = [self browser_screenBoundsFallback];
    }

    self.frame = targetBounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if (self.superview != view) {
        [self removeFromSuperview];
        [view addSubview:self];
    }

    BOOL destinationAcceptsVideoView = [view respondsToSelector:NSSelectorFromString(@"setVideoView:")];
    if (destinationAcceptsVideoView && self.embeddedVideoView.superview == self) {
        [self.embeddedVideoView removeFromSuperview];
        BrowserFullscreenHackLog(@"detached embedded video view from synthetic container before setVideoView:");
    } else if (!destinationAcceptsVideoView && self.embeddedVideoView != nil && self.embeddedVideoView.superview != view) {
        [self.embeddedVideoView removeFromSuperview];
        self.embeddedVideoView.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:self.embeddedVideoView];
        [NSLayoutConstraint activateConstraints:@[
            [self.embeddedVideoView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [self.embeddedVideoView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [self.embeddedVideoView.topAnchor constraintEqualToAnchor:view.topAnchor],
            [self.embeddedVideoView.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ]];
        self.embeddedVideoView.frame = self.embeddedVideoView.superview.bounds;
        BrowserFullscreenHackLog(@"moved embedded video view into destination %@ (%@)",
                                 view,
                                 NSStringFromClass([view class]));
    }

    id destinationVideoViewAfterSourceTransfer = BrowserFullscreenHackObjectForSelectorName(view, @"videoView");
    id destinationVideoSublayerAfterSourceTransfer = BrowserFullscreenHackObjectForSelectorName(view.layer, @"videoSublayer");
    BOOL destinationAlreadyHasTransferredVideo = (destinationVideoViewAfterSourceTransfer != nil ||
                                                  destinationVideoSublayerAfterSourceTransfer != nil);

    [self browser_applyPlayer:self.currentPlayer toLayerObject:view];
    [self browser_applyPlayer:self.currentPlayer toLayerObject:view.layer];
    [self browser_applyPlayerControllerObject:self.currentPlayerControllerObject toObject:view];
    [self browser_applyPlayerControllerObject:self.currentPlayerControllerObject toObject:view.layer];
    [self browser_applyPlayerControllerObject:self.currentPlayerControllerObject toObject:self.embeddedVideoView];
    if (!destinationAlreadyHasTransferredVideo) {
        [self browser_applyVideoView:self.embeddedVideoView toObject:view];
        [self browser_applyVideoSublayer:self.embeddedVideoView.layer toObject:view.layer];
    } else {
        BrowserFullscreenHackLog(@"destination already has transferred WebKit video objects; skipping fallback videoView/videoSublayer setters");
    }
    BOOL readyForDisplay = [self browser_embeddedVideoReadyForDisplay];
    CGSize videoDimensions = [self browser_embeddedVideoDimensions];
    if (!readyForDisplay && self.currentPlayer != nil && videoDimensions.width > 0.0 && videoDimensions.height > 0.0) {
        readyForDisplay = YES;
    }
    [self browser_applyReadyForDisplay:readyForDisplay toObject:view.layer];
    [self browser_applyVideoDimensions:videoDimensions toObject:view.layer];
    [self browser_applyVideoGravity:self.videoGravity toLayerObject:view];
    [self browser_applyVideoGravity:self.videoGravity toLayerObject:view.layer];
    [self browser_forceDestinationGeometry:view preferredBounds:[self browser_effectiveBounds]];
    [self browser_forceLayoutAndActivationOnDestinationView:view];

    if (!destinationAcceptsVideoView) {
        self.embeddedVideoView.frame = [self browser_effectiveBounds];
    }
    [self browser_logDestinationState:view label:@"initial"];
    BrowserFullscreenHackLog(@"transferVideoViewTo: %@ bounds=%@ effective=%@ ready=%@ dimensions=%@ destinationAcceptsVideoView=%@ sourceDimensions=%@",
                             view,
                             NSStringFromCGRect(view.bounds),
                             NSStringFromCGRect(self.embeddedVideoView.frame),
                             readyForDisplay ? @"YES" : @"NO",
                             NSStringFromCGSize(videoDimensions),
                             destinationAcceptsVideoView ? @"YES" : @"NO",
                             NSStringFromCGSize(self.sourceVideoDimensions));

    __weak typeof(self) weakSelf = self;
    __weak UIView *weakDestinationView = view;
    NSArray<NSNumber *> *retryDelays = @[@0.05, @0.15, @0.35, @0.75];
    for (NSNumber *delay in retryDelays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            UIView *strongDestinationView = weakDestinationView;
            if (strongSelf == nil || strongDestinationView == nil) {
                return;
            }

            CGSize retryDimensions = [strongSelf browser_embeddedVideoDimensions];
            BOOL retryReady = [strongSelf browser_embeddedVideoReadyForDisplay];
            if (!retryReady && strongSelf.currentPlayer != nil &&
                retryDimensions.width > 0.0 && retryDimensions.height > 0.0) {
                retryReady = YES;
            }

            [strongSelf browser_applyPlayer:strongSelf.currentPlayer toLayerObject:strongDestinationView];
            [strongSelf browser_applyPlayer:strongSelf.currentPlayer toLayerObject:strongDestinationView.layer];
            [strongSelf browser_applyPlayerControllerObject:strongSelf.currentPlayerControllerObject toObject:strongDestinationView];
            [strongSelf browser_applyPlayerControllerObject:strongSelf.currentPlayerControllerObject toObject:strongDestinationView.layer];
            [strongSelf browser_applyPlayerControllerObject:strongSelf.currentPlayerControllerObject toObject:strongSelf.embeddedVideoView];
            [strongSelf browser_attemptSourceWebTransferToDestination:strongDestinationView];
            id retryDestinationVideoView = BrowserFullscreenHackObjectForSelectorName(strongDestinationView, @"videoView");
            id retryDestinationVideoSublayer = BrowserFullscreenHackObjectForSelectorName(strongDestinationView.layer, @"videoSublayer");
            if (retryDestinationVideoView == nil && retryDestinationVideoSublayer == nil) {
                [strongSelf browser_applyVideoView:strongSelf.embeddedVideoView toObject:strongDestinationView];
                [strongSelf browser_applyVideoSublayer:strongSelf.embeddedVideoView.layer toObject:strongDestinationView.layer];
            } else {
                BrowserFullscreenHackLog(@"retry found transferred WebKit video objects already present on destination");
            }
            [strongSelf browser_applyReadyForDisplay:retryReady toObject:strongDestinationView.layer];
            [strongSelf browser_applyVideoDimensions:retryDimensions toObject:strongDestinationView.layer];
            [strongSelf browser_applyVideoGravity:strongSelf.videoGravity toLayerObject:strongDestinationView];
            [strongSelf browser_applyVideoGravity:strongSelf.videoGravity toLayerObject:strongDestinationView.layer];
            [strongSelf browser_applyBoolean:YES selectorName:@"setVideoScaled:" toObject:strongSelf.embeddedVideoView];
            [strongSelf browser_forceDestinationGeometry:strongDestinationView preferredBounds:[strongSelf browser_effectiveBounds]];
            [strongSelf browser_forceLayoutAndActivationOnDestinationView:strongDestinationView];
            [strongSelf browser_logDestinationState:strongDestinationView label:[NSString stringWithFormat:@"retry-%@", delay]];
            BrowserFullscreenHackLog(@"retry activation delay=%@ ready=%@ dimensions=%@ destination=%@",
                                     delay,
                                     retryReady ? @"YES" : @"NO",
                                     NSStringFromCGSize(retryDimensions),
                                     strongDestinationView);
        });
    }
}

- (BOOL)avkit_isVisible {
    if (self.hidden || self.alpha <= 0.0) {
        return NO;
    }

    return self.window != nil || self.superview != nil;
}

- (UIWindow *)avkit_window {
    return self.window;
}

- (CGRect)avkit_videoRectInWindow {
    UIWindow *window = self.window;
    if (window == nil) {
        return CGRectZero;
    }

    return [self convertRect:self.bounds toView:window];
}

@end

static UIView *BrowserViewForObject(id object) {
    if (object == nil || ![object respondsToSelector:@selector(view)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, @selector(view));
}

static void BrowserStoreRetainedHackView(id owner, UIView *view) {
    if (owner == nil || view == nil) {
        return;
    }

    NSMutableArray *views = objc_getAssociatedObject(owner, kBrowserFullscreenHackAssociatedViewsKey);
    if (views == nil) {
        views = [NSMutableArray array];
        objc_setAssociatedObject(owner, kBrowserFullscreenHackAssociatedViewsKey, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [views addObject:view];
}

static UIView *BrowserCurrentPlayerLayerViewFromHost(id playerControllerHost) {
    SEL selector = NSSelectorFromString(@"playerLayerView");
    if (playerControllerHost == nil || ![playerControllerHost respondsToSelector:selector]) {
        return nil;
    }

    id value = ((id (*)(id, SEL))objc_msgSend)(playerControllerHost, selector);
    BrowserFullscreenHackLog(@"host playerLayerView lookup on %@ (%@) -> %@ (%@)",
                             playerControllerHost,
                             playerControllerHost == nil ? @"nil" : NSStringFromClass([playerControllerHost class]),
                             value,
                             value == nil ? @"nil" : NSStringFromClass([value class]));
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

static BOOL BrowserViewLooksLikePlayerLayerView(UIView *view) {
    if (view == nil) {
        return NO;
    }

    NSString *className = NSStringFromClass([view class]);
    if ([className containsString:@"ContainerView"]) {
        return NO;
    }

    if ([view respondsToSelector:NSSelectorFromString(@"playerLayer")] ||
        [view respondsToSelector:NSSelectorFromString(@"setLegibleContentInsets:")] ||
        [className containsString:@"PlayerLayer"] ||
        [className containsString:@"Video"]) {
        return YES;
    }

    return NO;
}

static UIView *BrowserFindPlayerLayerViewInHierarchy(UIView *view) {
    for (UIView *subview in view.subviews) {
        if (BrowserViewLooksLikePlayerLayerView(subview)) {
            return subview;
        }

        UIView *match = BrowserFindPlayerLayerViewInHierarchy(subview);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static UIView *BrowserFindVisibleInlineWebPlayerLayerViewInHierarchy(UIView *rootView, UIView *excludedRoot) {
    for (UIView *subview in rootView.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        BOOL isInlineWebPlayerLayerView = [className isEqualToString:@"WebAVPlayerLayerView"];
        BOOL isVisible = !subview.hidden && subview.alpha > 0.0;
        BOOL hasGeometry = (subview.bounds.size.width > 0.0 && subview.bounds.size.height > 0.0) ||
                           (subview.frame.size.width > 0.0 && subview.frame.size.height > 0.0);
        BOOL excluded = BrowserViewIsDescendantOfView(subview, excludedRoot);
        if (isInlineWebPlayerLayerView && isVisible && hasGeometry && !excluded) {
            return subview;
        }

        UIView *match = BrowserFindVisibleInlineWebPlayerLayerViewInHierarchy(subview, excludedRoot);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static UIView *BrowserFindVisibleInlineWebPlayerLayerView(UIView *excludedRoot) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            UIView *match = BrowserFindVisibleInlineWebPlayerLayerViewInHierarchy(window, excludedRoot);
            if (match != nil) {
                return match;
            }
        }
    }

    return nil;
}

static AVPlayerLayer *BrowserExtractPlayerLayerFromView(UIView *view) {
    if (view == nil) {
        return nil;
    }

    if ([view.layer isKindOfClass:[AVPlayerLayer class]]) {
        return (AVPlayerLayer *)view.layer;
    }

    SEL selector = NSSelectorFromString(@"playerLayer");
    if ([view respondsToSelector:selector]) {
        id layer = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            return layer;
        }
    }

    return nil;
}

static BOOL BrowserIsPotentialPlayerControllerHost(id object) {
    if (object == nil) {
        return NO;
    }

    return [object respondsToSelector:@selector(view)] &&
           [object respondsToSelector:NSSelectorFromString(@"videoGravity")] &&
           [object respondsToSelector:NSSelectorFromString(@"playerLayerView")] &&
           [object respondsToSelector:NSSelectorFromString(@"setPlayerLayerView:")] &&
	           [object respondsToSelector:NSSelectorFromString(@"pixelBufferAttributes")];
}

static id BrowserPlayerControllerHostFromKnownOffset(id fullscreenController) {
    if (fullscreenController == nil) {
        return nil;
    }

    uint8_t *bytes = (uint8_t *)(__bridge void *)fullscreenController;
    __unsafe_unretained id playerControllerHost = nil;
    memcpy(&playerControllerHost, bytes + kBrowserPlayerControllerHostOffset, sizeof(playerControllerHost));
    return playerControllerHost;
}

static UIView *BrowserPlayerLayerViewFromFullscreenInterface(void *fullscreenInterface) {
    if (fullscreenInterface == NULL) {
        return nil;
    }

    __unsafe_unretained UIView *playerLayerView = nil;
    memcpy(&playerLayerView,
           ((uint8_t *)fullscreenInterface) + kBrowserFullscreenInterfacePlayerLayerViewOffset,
           sizeof(playerLayerView));
    return playerLayerView;
}

static void BrowserSetPlayerLayerViewOnFullscreenInterface(void *fullscreenInterface, UIView *playerLayerView) {
    if (fullscreenInterface == NULL || playerLayerView == nil) {
        return;
    }

    __unsafe_unretained UIView *unretainedPlayerLayerView = playerLayerView;
    memcpy(((uint8_t *)fullscreenInterface) + kBrowserFullscreenInterfacePlayerLayerViewOffset,
           &unretainedPlayerLayerView,
           sizeof(unretainedPlayerLayerView));
}

static id BrowserFindPlayerControllerHost(id fullscreenController) {
    for (Class currentClass = [fullscreenController class];
         currentClass != Nil && currentClass != [NSObject class];
         currentClass = class_getSuperclass(currentClass)) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(currentClass, &ivarCount);
        for (unsigned int index = 0; index < ivarCount; index++) {
            Ivar ivar = ivars[index];
            const char *typeEncoding = ivar_getTypeEncoding(ivar);
            if (typeEncoding == NULL || typeEncoding[0] != '@') {
                continue;
            }

            id value = object_getIvar(fullscreenController, ivar);
            if (BrowserIsPotentialPlayerControllerHost(value)) {
                free(ivars);
                return value;
            }
        }
        free(ivars);
    }
    return nil;
}

static void BrowserEnsureFullscreenContainerSubview(id fullscreenController) {
    id playerControllerHost = BrowserPlayerControllerHostFromKnownOffset(fullscreenController);
    if (!BrowserIsPotentialPlayerControllerHost(playerControllerHost)) {
        playerControllerHost = BrowserFindPlayerControllerHost(fullscreenController);
    }

    UIView *playerControllerView = BrowserViewForObject(playerControllerHost);
    BrowserFullscreenHackLog(@"host view %@ for controller %@ (%@), subviews=%lu",
                             playerControllerView,
                             playerControllerHost,
                             playerControllerHost == nil ? @"nil" : NSStringFromClass([playerControllerHost class]),
                             (unsigned long)playerControllerView.subviews.count);
    if (playerControllerView == nil || playerControllerView.subviews.count > 0) {
        return;
    }

    UIView *containerView = [[UIView alloc] initWithFrame:playerControllerView.bounds];
    containerView.backgroundColor = UIColor.clearColor;
    containerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [playerControllerView addSubview:containerView];
    BrowserStoreRetainedHackView(fullscreenController, containerView);
}

static void BrowserEnsurePlayerLayerView(void *fullscreenInterface, id fullscreenController) {
    if (BrowserPlayerLayerViewFromFullscreenInterface(fullscreenInterface) != nil) {
        return;
    }

    id playerControllerHost = BrowserPlayerControllerHostFromKnownOffset(fullscreenController);
    if (!BrowserIsPotentialPlayerControllerHost(playerControllerHost)) {
        playerControllerHost = BrowserFindPlayerControllerHost(fullscreenController);
    }

    UIView *existingPlayerLayerView = BrowserCurrentPlayerLayerViewFromHost(playerControllerHost);
    UIView *playerControllerView = BrowserViewForObject(playerControllerHost);
    UIView *inlineWebPlayerLayerView = BrowserFindVisibleInlineWebPlayerLayerView(playerControllerView);
    UIView *discoveredPlayerLayerView = BrowserFindPlayerLayerViewInHierarchy(playerControllerView);

    CGRect frame = playerControllerView != nil ? playerControllerView.bounds : CGRectZero;
    BrowserFullscreenPlayerLayerView *playerLayerView = [[BrowserFullscreenPlayerLayerView alloc] initWithFrame:frame];
    playerLayerView.backgroundColor = UIColor.clearColor;
    playerLayerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if (inlineWebPlayerLayerView != nil) {
        playerLayerView.sourceWebPlayerLayerView = inlineWebPlayerLayerView;
        BrowserFullscreenHackLog(@"using inline WebKit player layer view %@ (%@) as preferred source",
                                 inlineWebPlayerLayerView,
                                 NSStringFromClass([inlineWebPlayerLayerView class]));
    }

    UIView *preferredEmbeddedVideoView = nil;
    if (inlineWebPlayerLayerView != nil) {
        id inlineVideoView = BrowserFullscreenHackObjectForSelectorName(inlineWebPlayerLayerView, @"videoView");
        if ([inlineVideoView isKindOfClass:[UIView class]]) {
            preferredEmbeddedVideoView = inlineVideoView;
        }
    }

    UIView *sourcePlayerLayerView = preferredEmbeddedVideoView ?: existingPlayerLayerView ?: discoveredPlayerLayerView;
    AVPlayerLayer *sourcePlayerLayer = BrowserExtractPlayerLayerFromView(sourcePlayerLayerView);
    if (sourcePlayerLayer != nil) {
        [playerLayerView browser_configureFromExistingPlayerLayer:sourcePlayerLayer];
        [playerLayerView browser_embedVideoView:sourcePlayerLayerView];
        BrowserFullscreenHackLog(@"using %@ playerLayerView %@ (%@) as source for synthetic layer",
                                 preferredEmbeddedVideoView != nil ? @"inline WebKit source" : (existingPlayerLayerView != nil ? @"existing host" : @"discovered host"),
                                 sourcePlayerLayerView,
                                 NSStringFromClass([sourcePlayerLayerView class]));
    }

    BrowserSetPlayerLayerViewOnFullscreenInterface(fullscreenInterface, playerLayerView);
    BrowserStoreRetainedHackView(fullscreenController, playerLayerView);
    BrowserFullscreenHackLog(@"using synthetic playerLayerView %@ with frame %@",
                             playerLayerView,
                             NSStringFromCGRect(frame));
}

static void BrowserConfigurePlayerViewControllerReplacement(id self, SEL _cmd, void *fullscreenInterface) {
    BrowserFullscreenHackDumpRelevantClassesOnce();
    BrowserEnsurePlayerLayerView(fullscreenInterface, self);
    BrowserEnsureFullscreenContainerSubview(self);

    if (BrowserOriginalConfigurePlayerViewController != NULL) {
        BrowserOriginalConfigurePlayerViewController(self, _cmd, fullscreenInterface);
    }
}

@interface BrowserFullscreenSubviewHack : NSObject
@end

@implementation BrowserFullscreenSubviewHack

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!kBrowserFullscreenHackEnabled) {
            return;
        }

        Class playerViewControllerClass = objc_getClass("WebAVPlayerViewController");
        if (playerViewControllerClass == Nil) {
            return;
        }

        SEL selector = NSSelectorFromString(@"configurePlayerViewControllerWithFullscreenInterface:");
        Method method = class_getInstanceMethod(playerViewControllerClass, selector);
        if (method == NULL) {
            return;
        }

        BrowserOriginalConfigurePlayerViewController = (void (*)(id, SEL, void *))method_getImplementation(method);
        method_setImplementation(method, (IMP)BrowserConfigurePlayerViewControllerReplacement);
    });
}

@end
