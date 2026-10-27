#import "BrowserWebView.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>

// WebKit requires JavaScript panel completion handlers to be called exactly once;
// deallocating one uncalled raises an exception. Alerts can get dismissed without
// any action firing (e.g. our global Menu handling), so this guard fires a fallback
// on dealloc unless an action fulfilled it first.
@interface BrowserWebViewCompletionGuard : NSObject
+ (instancetype)guardWithFallback:(dispatch_block_t)fallback;
- (void)fulfill;
@end

@implementation BrowserWebViewCompletionGuard {
    dispatch_block_t _fallback;
}

+ (instancetype)guardWithFallback:(dispatch_block_t)fallback {
    BrowserWebViewCompletionGuard *completionGuard = [BrowserWebViewCompletionGuard new];
    completionGuard->_fallback = [fallback copy];
    return completionGuard;
}

- (void)fulfill {
    _fallback = nil;
}

- (void)dealloc {
    if (_fallback != nil) {
        _fallback();
    }
}

@end

// WKUserContentController retains its script message handlers strongly; this
// weak forwarder breaks the webview -> configuration -> handler -> webview cycle.
@interface BrowserWeakScriptMessageForwarder : NSObject
@property (nonatomic, weak) id target;
@end

@implementation BrowserWeakScriptMessageForwarder

+ (void)initialize {
    if (self == [BrowserWeakScriptMessageForwarder class]) {
        Protocol *handlerProtocol = objc_getProtocol("WKScriptMessageHandler");
        if (handlerProtocol != NULL) {
            class_addProtocol(self, handlerProtocol);
        }
    }
}

- (void)userContentController:(id)userContentController didReceiveScriptMessage:(id)message {
    SEL forwardSelector = @selector(userContentController:didReceiveScriptMessage:);
    id target = self.target;
    if (target != nil && [target respondsToSelector:forwardSelector]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(target, forwardSelector, userContentController, message);
    }
}

@end

static NSString * const kBrowserWebViewClassName = @"WKWebView";
static NSString * const kBrowserFullscreenMessageHandlerName = @"browserFullscreen";
static NSString * const kBrowserMediaProbeMessageHandlerName = @"browserMediaProbe";
// Extra key added to each stored probe payload; stripped before handing copies out.
static NSString * const kBrowserMediaProbeTimestampKey = @"_mediaProbeTimestamp";
static NSString * const kBrowserWebViewConfigurationClassName = @"WKWebViewConfiguration";
static NSString * const kBrowserWebsiteDataStoreClassName = @"WKWebsiteDataStore";
static NSString * const kBrowserUserContentControllerClassName = @"WKUserContentController";
static NSString * const kBrowserUserScriptClassName = @"WKUserScript";

static void BrowserEnsureWebKitRuntimeLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(kBrowserWebViewClassName) != Nil) {
            return;
        }

        NSArray<NSString *> *candidatePaths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];

        for (NSString *candidatePath in candidatePaths) {
            if (dlopen(candidatePath.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(kBrowserWebViewClassName) != Nil) {
                break;
            }
        }
    });
}

// Nesting guard: pumping while a pump is already active re-enters CA commits
// and WebKit callbacks and exhausts the 1 MB main-thread stack (SIGSEGV).
// Main-thread only — every caller is a synchronous helper running there.
static int sBrowserPumpDepth = 0;

// Runs the run loop until *done (set from a completion handler that also calls
// CFRunLoopStop on this loop) or until the timeout elapses. Event-driven rather
// than 10ms-polling, so a synchronous JS eval returns the instant its handler
// fires instead of waiting out a poll tick. The timeout guarantees it can never
// hang the main thread if the handler never arrives.
// Returns NO immediately WITHOUT pumping when a pump is already active; callers
// must degrade gracefully (nil/fallback) on NO. Otherwise returns *done.
static BOOL BrowserPumpRunLoopUntil(BOOL *done, CFRunLoopRef runLoop, CFTimeInterval timeout) {
    if (sBrowserPumpDepth > 0) {
        return NO;
    }

    sBrowserPumpDepth += 1;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (!*done) {
        CFAbsoluteTime remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0.0) {
            break;
        }
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, true);
        }
    }
    BOOL finished = *done ? YES : NO;
    sBrowserPumpDepth -= 1;
    return finished;
}

// Interactive degrade: one tap/hover on a JS-heavy page (ppv.st class) chains
// several synchronous evals, each stalling the main thread up to the full
// 2.0s window until the queue drains — the whole app feels dead. While the
// user is interacting, the JS-eval pump cuts that window short; diagnostics
// (BrowserMenuCoordinator) disarm it to get the full 2.0s eval windows back.
// Main-thread only, like every pump caller.
static BOOL sBrowserInteractivePumpTimeoutActive = YES;

static CFTimeInterval BrowserSyncEvalPumpTimeout(void) {
    return sBrowserInteractivePumpTimeoutActive ? 0.35 : 2.0;
}

static NSString *BrowserStringFromJavaScriptResult(id result) {
    if (result == nil || result == [NSNull null]) {
        return nil;
    }
    if ([result isKindOfClass:[NSString class]]) {
        return result;
    }
    if ([result respondsToSelector:@selector(stringValue)]) {
        return [result stringValue];
    }
    return [result description];
}

static BOOL BrowserSelectorNameMatchesMediaFilter(NSString *selectorName) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"mediasource",
            @"managedmediasource",
            @"sourcebuffer",
            @"media",
            @"video",
            @"inline",
            @"autoplay",
            @"fullscreen",
            @"pictureinpicture",
            @"airplay",
            @"webm",
            @"vp9",
            @"av1",
            @"hls",
            @"mse",
            @"codec",
        ];
    });

    NSString *lowercaseSelectorName = selectorName.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lowercaseSelectorName containsString:keyword]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *BrowserFilteredSelectorNamesForClass(Class klass) {
    if (klass == Nil) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *selectorNames = [NSMutableOrderedSet orderedSet];
    for (Class currentClass = klass; currentClass != Nil && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(currentClass, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex += 1) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *selectorName = NSStringFromSelector(selector);
            if (selectorName.length > 0 && BrowserSelectorNameMatchesMediaFilter(selectorName)) {
                [selectorNames addObject:selectorName];
            }
        }
        free(methods);
    }

    return [selectorNames.array sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *BrowserGetterNameFromSetterName(NSString *setterName) {
    if (![setterName hasPrefix:@"set"] || ![setterName hasSuffix:@":"] || setterName.length <= 4) {
        return nil;
    }

    NSString *propertyStem = [setterName substringWithRange:NSMakeRange(3, setterName.length - 4)];
    if (propertyStem.length == 0) {
        return nil;
    }

    NSString *firstCharacter = [[propertyStem substringToIndex:1] lowercaseString];
    if (propertyStem.length == 1) {
        return firstCharacter;
    }

    return [firstCharacter stringByAppendingString:[propertyStem substringFromIndex:1]];
}

static NSString *BrowserBooleanValueDescriptionForObjectAndSelector(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL) {
        return nil;
    }

    if (returnType[0] != 'B' && returnType[0] != 'c') {
        return nil;
    }

    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return value ? @"YES" : @"NO";
}

static id BrowserObjectResultForGetter(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL || returnType[0] != '@') {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *BrowserPreviewString(NSString *string, NSUInteger maxLength) {
    if (string.length <= maxLength) {
        return string;
    }
    return [[string substringToIndex:maxLength] stringByAppendingString:@"\n…"];
}

static NSString *BrowserStringValueForKnownSelectors(id object, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        id result = BrowserObjectResultForGetter(object, selectorName);
        if (result == nil || result == [NSNull null]) {
            continue;
        }
        NSString *stringResult = nil;
        if ([result isKindOfClass:[NSString class]]) {
            stringResult = result;
        } else if ([result respondsToSelector:@selector(stringValue)]) {
            stringResult = [result stringValue];
        } else {
            stringResult = [result description];
        }

        if (stringResult.length > 0) {
            return stringResult;
        }
    }
    return nil;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *BrowserFeatureEntriesForPreferences(id preferences) {
    if (preferences == nil) {
        return @[];
    }

    NSArray<NSString *> *collectionSelectors = @[
        @"_experimentalFeatures",
        @"_internalDebugFeatures",
        @"_features",
    ];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    for (NSString *collectionSelectorName in collectionSelectors) {
        id collection = BrowserObjectResultForGetter(preferences, collectionSelectorName);
        if (![collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
            continue;
        }

        for (id feature in collection) {
            NSString *name = BrowserStringValueForKnownSelectors(feature, @[@"name", @"key", @"identifier", @"title", @"details"]);
            if (name.length == 0) {
                continue;
            }

            NSString *lowercaseName = name.lowercaseString;
            if (![lowercaseName containsString:@"media"] &&
                ![lowercaseName containsString:@"source"] &&
                ![lowercaseName containsString:@"vp9"] &&
                ![lowercaseName containsString:@"av1"] &&
                ![lowercaseName containsString:@"webm"] &&
                ![lowercaseName containsString:@"video"] &&
                ![lowercaseName containsString:@"mse"] &&
                ![lowercaseName containsString:@"managed"]) {
                continue;
            }

            NSString *enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"enabled");
            if (enabledValue == nil) {
                enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"isEnabled");
            }
            if (enabledValue == nil) {
                enabledValue = @"unknown";
            }

            NSString *key = BrowserStringValueForKnownSelectors(feature, @[@"key", @"identifier"]);
            NSString *source = [collectionSelectorName stringByReplacingOccurrencesOfString:@"_" withString:@""];
            [entries addObject:@{
                @"source": source ?: @"features",
                @"name": name,
                @"enabled": enabledValue,
                @"key": key ?: @"",
            }];
        }
    }

    return entries;
}

static void BrowserSetBooleanSelectorIfAvailable(id object, NSString *selectorName, BOOL value) {
    if (object == nil || selectorName.length == 0) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static void BrowserEnableMediaFeatureFlags(id preferences);
static void BrowserDisableMatchingMediaFeatures(id preferences);

static void BrowserConfigurePrivateMediaPreferences(id configuration) {
    if (configuration == nil) {
        return;
    }

    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    if (![configuration respondsToSelector:preferencesSelector]) {
        return;
    }

    id preferences = ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector);
    if (preferences == nil) {
        return;
    }

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"NativeVideoModeDisabled"]) {
        // Native Video Mode (default ON, the Tanghulu strategy): advertise no
        // MSE at all so hls.js-style players fall back to a plain
        // <video src=<real m3u8>> that the AVPlayer-backed element can play.
        BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaSourceEnabled:", NO);
        BrowserSetBooleanSelectorIfAvailable(preferences, @"_setManagedMediaSourceEnabled:", NO);
        BrowserDisableMatchingMediaFeatures(preferences);
    }
    else {
        BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaSourceEnabled:", YES);
        BrowserSetBooleanSelectorIfAvailable(preferences, @"_setManagedMediaSourceEnabled:", YES);

        // On modern WebKit (tvOS 26), MSE/MMS is gated behind WKFeature flags rather
        // than the legacy _setMediaSourceEnabled: setter. Enable any feature whose key
        // mentions MediaSource so sites that feed <video> via MSE can play.
        BrowserEnableMediaFeatureFlags(preferences);
    }

    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaCapabilityGrantsEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setVideoQualityIncludesDisplayCompositingEnabled:", YES);
}

static void BrowserEnableMatchingFeatures(id preferences, NSArray *features) {
    if (![features isKindOfClass:[NSArray class]]) {
        return;
    }
    SEL setEnabledForFeature = NSSelectorFromString(@"_setEnabled:forFeature:");
    if (![preferences respondsToSelector:setEnabledForFeature]) {
        return;
    }
    SEL keySelector = NSSelectorFromString(@"key");
    for (id feature in features) {
        if (![feature respondsToSelector:keySelector]) {
            continue;
        }
        NSString *key = ((id (*)(id, SEL))objc_msgSend)(feature, keySelector);
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *lowercaseKey = key.lowercaseString;
        // Media playback features that sites commonly require.
        if ([lowercaseKey containsString:@"mediasource"] ||
            [lowercaseKey containsString:@"managedmediasource"] ||
            [lowercaseKey containsString:@"sourcebuffer"]) {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, setEnabledForFeature, YES, feature);
        }
    }
}

static void BrowserEnableMediaFeatureFlags(id preferences) {
    Class preferencesClass = NSClassFromString(@"WKPreferences");
    if (preferencesClass == Nil) {
        return;
    }
    // Experimental and internal feature catalogs are class methods on WKPreferences.
    SEL experimentalSelector = NSSelectorFromString(@"_experimentalFeatures");
    if ([preferencesClass respondsToSelector:experimentalSelector]) {
        BrowserEnableMatchingFeatures(preferences, ((id (*)(id, SEL))objc_msgSend)((id)preferencesClass, experimentalSelector));
    }
    SEL internalSelector = NSSelectorFromString(@"_internalDebugFeatures");
    if ([preferencesClass respondsToSelector:internalSelector]) {
        BrowserEnableMatchingFeatures(preferences, ((id (*)(id, SEL))objc_msgSend)((id)preferencesClass, internalSelector));
    }
}

// Native Video Mode mirror of the enable path: pass NO (not YES) to
// _setEnabled:forFeature: for features whose key mentions MediaSource
// (case-insensitive; ManagedMediaSource keys contain it too). Features with
// any other key are left untouched.
static void BrowserDisableMatchingFeatures(id preferences, NSArray *features) {
    if (![features isKindOfClass:[NSArray class]]) {
        return;
    }
    SEL setEnabledForFeature = NSSelectorFromString(@"_setEnabled:forFeature:");
    if (![preferences respondsToSelector:setEnabledForFeature]) {
        return;
    }
    SEL keySelector = NSSelectorFromString(@"key");
    for (id feature in features) {
        if (![feature respondsToSelector:keySelector]) {
            continue;
        }
        NSString *key = ((id (*)(id, SEL))objc_msgSend)(feature, keySelector);
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        if ([key.lowercaseString containsString:@"mediasource"]) {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, setEnabledForFeature, NO, feature);
        }
    }
}

static void BrowserDisableMatchingMediaFeatures(id preferences) {
    Class preferencesClass = NSClassFromString(@"WKPreferences");
    if (preferencesClass == Nil) {
        return;
    }
    SEL experimentalSelector = NSSelectorFromString(@"_experimentalFeatures");
    if ([preferencesClass respondsToSelector:experimentalSelector]) {
        BrowserDisableMatchingFeatures(preferences, ((id (*)(id, SEL))objc_msgSend)((id)preferencesClass, experimentalSelector));
    }
    SEL internalSelector = NSSelectorFromString(@"_internalDebugFeatures");
    if ([preferencesClass respondsToSelector:internalSelector]) {
        BrowserDisableMatchingFeatures(preferences, ((id (*)(id, SEL))objc_msgSend)((id)preferencesClass, internalSelector));
    }
}

static NSString *BrowserYouTubeRequestCaptureScript(void) {
    return
    @"(function(){"
        "if (window.__browserYouTubeHookInstalled) { return; }"
        "window.__browserYouTubeHookInstalled = true;"
        "window.__browserYouTubeIntegrity = window.__browserYouTubeIntegrity || {};"
        "function assignIfPresent(key, value) {"
            "if (value === undefined || value === null) { return; }"
            "var stringValue = String(value || '');"
            "if (!stringValue) { return; }"
            "window.__browserYouTubeIntegrity[key] = stringValue;"
        "}"
        "function capturePayload(payload) {"
            "try {"
                "if (!payload || typeof payload !== 'object') { return; }"
                "if (payload.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.serviceIntegrityDimensions.poToken || payload.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.context.serviceIntegrityDimensions.poToken || payload.context.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.client) {"
                    "assignIfPresent('requestClientName', payload.context.client.clientName);"
                    "assignIfPresent('requestClientVersion', payload.context.client.clientVersion);"
                "}"
            "} catch (error) {}"
        "}"
        "function toHeaderObject(headers) {"
            "var result = {};"
            "try {"
                "if (!headers) { return result; }"
                "if (typeof Headers !== 'undefined' && headers instanceof Headers) {"
                    "headers.forEach(function(value, key) { result[String(key)] = String(value); });"
                    "return result;"
                "}"
                "if (Array.isArray(headers)) {"
                    "headers.forEach(function(entry) {"
                        "if (Array.isArray(entry) && entry.length >= 2) { result[String(entry[0])] = String(entry[1]); }"
                    "});"
                    "return result;"
                "}"
                "if (typeof headers === 'object') {"
                    "Object.keys(headers).forEach(function(key) { result[String(key)] = String(headers[key]); });"
                "}"
            "} catch (error) {}"
            "return result;"
        "}"
        "function rememberRequest(url, body, headers, transport) {"
            "try {"
                "var integrity = window.__browserYouTubeIntegrity;"
                "integrity.lastPlayerRequestURL = String(url || '');"
                "integrity.lastPlayerRequestBody = String(body || '');"
                "integrity.lastPlayerRequestHeaders = JSON.stringify(headers || {});"
                "integrity.lastPlayerRequestTransport = String(transport || '');"
                "if (!integrity.firstPlayerRequestURL) {"
                    "integrity.firstPlayerRequestURL = integrity.lastPlayerRequestURL;"
                    "integrity.firstPlayerRequestBody = integrity.lastPlayerRequestBody;"
                    "integrity.firstPlayerRequestHeaders = integrity.lastPlayerRequestHeaders;"
                    "integrity.firstPlayerRequestTransport = integrity.lastPlayerRequestTransport;"
                "}"
            "} catch (error) {}"
        "}"
        "function captureBodyStringAsync(source, bodyString, headers, transport) {"
            "try {"
                "if (bodyString && bodyString !== '[object ReadableStream]') {"
                    "rememberRequest(source.url || '', bodyString, headers || {}, transport || '');"
                    "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
                    "return;"
                "}"
                "if (source && typeof source.clone === 'function' && typeof source.text === 'function') {"
                    "source.clone().text().then(function(text) {"
                        "rememberRequest(source.url || '', text || '', headers || {}, transport || '');"
                        "try { capturePayload(JSON.parse(text || '')); } catch (error) {}"
                    "}).catch(function(){});"
                "}"
            "} catch (error) {}"
        "}"
        "function captureRequest(input, init) {"
            "try {"
                "var url = '';"
                "if (typeof input === 'string') { url = input; }"
                "else if (input && typeof input.url === 'string') { url = input.url; }"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var body = (init && init.body) || (input && input.body) || null;"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = toHeaderObject((init && init.headers) || (input && input.headers) || null);"
                "rememberRequest(url, bodyString, headers, 'fetch');"
                "captureBodyStringAsync((input && typeof input.clone === 'function') ? input : null, bodyString, headers, 'fetch');"
                "if (typeof bodyString !== 'string' || !bodyString || bodyString === '[object ReadableStream]') { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "function captureXHRRequest(xhr, body) {"
            "try {"
                "var url = String((xhr && xhr.__browserYouTubeURL) || '');"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = xhr && xhr.__browserYouTubeHeaders ? xhr.__browserYouTubeHeaders : {};"
                "rememberRequest(url, bodyString, headers, 'xhr');"
                "if (typeof bodyString !== 'string' || !bodyString) { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "try { capturePayload(JSON.parse(body)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "var cfg = (window.ytcfg && window.ytcfg.data_) || {};"
        "assignIfPresent('poToken', cfg.PO_TOKEN || cfg.po_token || cfg.POTOKEN);"
        "if (cfg.SERVICE_INTEGRITY_DIMENSIONS) {"
            "assignIfPresent('poToken', cfg.SERVICE_INTEGRITY_DIMENSIONS.poToken || cfg.SERVICE_INTEGRITY_DIMENSIONS.po_token);"
        "}"
        "if (cfg.WEB_PLAYER_CONTEXT_CONFIGS) {"
            "var watchConfig = cfg.WEB_PLAYER_CONTEXT_CONFIGS.WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH || {};"
            "if (watchConfig.serviceIntegrityDimensions) {"
                "assignIfPresent('poToken', watchConfig.serviceIntegrityDimensions.poToken || watchConfig.serviceIntegrityDimensions.po_token);"
            "}"
        "}"
        "if (window.fetch) {"
            "var originalFetch = window.fetch;"
            "window.fetch = function(input, init) {"
                "captureRequest(input, init);"
                "return originalFetch.apply(this, arguments);"
            "};"
        "}"
        "if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {"
            "var originalOpen = window.XMLHttpRequest.prototype.open;"
            "var originalSend = window.XMLHttpRequest.prototype.send;"
            "var originalSetRequestHeader = window.XMLHttpRequest.prototype.setRequestHeader;"
            "window.XMLHttpRequest.prototype.open = function(method, url) {"
                "this.__browserYouTubeURL = String(url || '');"
                "this.__browserYouTubeHeaders = {};"
                "return originalOpen.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.setRequestHeader = function(key, value) {"
                "try {"
                    "if (!this.__browserYouTubeHeaders) { this.__browserYouTubeHeaders = {}; }"
                    "this.__browserYouTubeHeaders[String(key)] = String(value);"
                "} catch (error) {}"
                "return originalSetRequestHeader.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.send = function(body) {"
                "captureXHRRequest(this, body);"
                "return originalSend.apply(this, arguments);"
            "};"
        "}"
    "})();";
}

// Streameast-family embeds load hls.js and only fall back to native
// video.src = <m3u8> playback when Hls.isSupported() reports false. tvOS
// WKWebView plays native HLS reliably but the MSE path hls.js drives is
// crash-prone there, so when the frame has native HLS we shadow window.Hls
// and make isSupported() return false to keep pages on the native branch.
// The same hook records playlist URLs (fetch/XHR/video src) per frame so the
// native player can take over even when the <video> src is a blob: URL, and
// (probe section) posts per-frame media reports through the browserMediaProbe
// message channel so the app can see inside cross-origin player iframes.
// The hook sections are separately switchable for the remote bisect:
// the config literal carries the negation of the (default-NO) ...FlagDisabled
// NSUserDefaults keys, each section runs only when its flag is true, and the
// whole script is bypassed when MediaEngineHooksDisabled is set.
// forcePlayEnabled is the positive (default-NO) ForcePlayOnLaunch key: when
// true the probe section also forces the largest visible video to start
// playing once per document, for unattended headless regression runs.
static NSString *BrowserMediaEngineUserScriptWithFlags(BOOL hlsEnabled, BOOL netEnabled, BOOL srcEnabled, BOOL probeEnabled, BOOL noMSEEnabled, BOOL forcePlayEnabled) {
    NSString *config =
        [NSString stringWithFormat:
            @"window.__browserMediaEngineConfig = {hls:%@,net:%@,src:%@,probe:%@,noMSE:%@,forcePlay:%@};",
            hlsEnabled ? @"true" : @"false",
            netEnabled ? @"true" : @"false",
            srcEnabled ? @"true" : @"false",
            probeEnabled ? @"true" : @"false",
            noMSEEnabled ? @"true" : @"false",
            forcePlayEnabled ? @"true" : @"false"];
    NSString *script =
    @"(function(){"
        "if (window.__browserMediaEngineHookInstalled) { return; }"
        "window.__browserMediaEngineHookInstalled = true;"
        "window.__browserCapturedMediaURLs = window.__browserCapturedMediaURLs || [];"
        "window.__browserForceNativeHLS = false;"
        "window.__browserMediaEngineConfig = window.__browserMediaEngineConfig || {hls:true,net:true,src:true,probe:true,noMSE:true,forcePlay:false};"
        "try {"
            // Native Video Mode belt-and-braces: hls.js isSupported() only
            // checks window.MediaSource || window.ManagedMediaSource, so
            // making both undefined is enough to keep pages on the native
            // <video src=m3u8> branch even if the private WebKit flags do
            // not exist on a future WebKit. The Hls interceptor below stays
            // as the second layer.
            "if (window.__browserMediaEngineConfig.noMSE) {"
                "try { Object.defineProperty(window, 'MediaSource', {value: undefined, configurable: true}); } catch (error) {}"
                "try { Object.defineProperty(window, 'ManagedMediaSource', {value: undefined, configurable: true}); } catch (error) {}"
                "try { if (window.MediaSource && window.MediaSource.isTypeSupported) { /* dead */ } } catch (error) {}"
            "}"
        "} catch (error) {}"
        "function rememberMediaURL(url) {"
            "try {"
                "var value = String(url || '');"
                "if (!value) { return; }"
                "var absolute = value;"
                "try { absolute = String(new URL(value, document.baseURI).toString()); } catch (error) {}"
                "var lowercase = absolute.toLowerCase();"
                "if (lowercase.indexOf('blob:') === 0 || lowercase.indexOf('data:') === 0 || lowercase.indexOf('mediastream:') === 0) { return; }"
                "if (lowercase.indexOf('http:') !== 0 && lowercase.indexOf('https:') !== 0) { return; }"
                "if (!(/(\\.m3u8(\\?|$)|\\/playlist\\/)/).test(lowercase)) { return; }"
                "var list = window.__browserCapturedMediaURLs;"
                "if (!Array.isArray(list)) { list = []; window.__browserCapturedMediaURLs = list; }"
                "var index = list.indexOf(absolute);"
                "if (index !== -1) { list.splice(index, 1); }"
                "list.push(absolute);"
                "while (list.length > 12) { list.shift(); }"
            "} catch (error) {}"
        "}"
        "try {"
            "if (window.__browserMediaEngineConfig.hls) {"
                "if (document.createElement('video').canPlayType('application/vnd.apple.mpegurl')) {"
                    "window.__browserForceNativeHLS = true;"
                    "var hlsValue;"
                    "Object.defineProperty(window, 'Hls', {"
                        "configurable: true,"
                        "get: function() { return hlsValue; },"
                        "set: function(value) {"
                            "hlsValue = value;"
                            "try {"
                                "if (value && typeof value.isSupported === 'function') {"
                                    // hls.js exposes isSupported as a static method; returning a
                                    // false-function from the getter covers both Hls.isSupported()
                                    // calls and bare existence checks, and keeps working when the
                                    // build replaces the method with a static property.
                                    "Object.defineProperty(value, 'isSupported', { get: function() { return function() { return false; }; }, configurable: true });"
                                "}"
                            "} catch (error) {}"
                        "}"
                    "});"
                "}"
            "}"
        "} catch (error) {}"
        "try {"
            "if (window.__browserMediaEngineConfig.net) {"
                "if (window.fetch) {"
                    "var originalFetch = window.fetch;"
                    "window.fetch = function(input, init) {"
                        "try {"
                            "if (typeof input === 'string') { rememberMediaURL(input); }"
                            "else if (input && typeof input.url === 'string') { rememberMediaURL(input.url); }"
                        "} catch (error) {}"
                        "return originalFetch.apply(this, arguments);"
                    "};"
                "}"
                "if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {"
                    "var originalOpen = window.XMLHttpRequest.prototype.open;"
                    "window.XMLHttpRequest.prototype.open = function(method, url) {"
                        "try { rememberMediaURL(url); } catch (error) {}"
                        "return originalOpen.apply(this, arguments);"
                    "};"
                "}"
            "}"
        "} catch (error) {}"
        "try {"
            "if (window.__browserMediaEngineConfig.src) {"
                "document.addEventListener('loadstart', function(event) {"
                    "try {"
                        "var target = event && event.target;"
                        "if (!target || String(target.tagName || '').toLowerCase() !== 'video') { return; }"
                        "rememberMediaURL(String(target.currentSrc || target.src || ''));"
                    "} catch (error) {}"
                "}, true);"
            "}"
        "} catch (error) {}"
        "try {"
            "if (window.__browserMediaEngineConfig.probe && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserMediaProbe) {"
                "var probeLastPayload = '';"
                "function clipProbeString(value) {"
                    "var s = String(value || '');"
                    "if (s.length > 500) { s = s.slice(0, 500); }"
                    "return s;"
                "}"
                "function probeHttpURL(value) {"
                    "try {"
                        "var s = String(value || '');"
                        "if (!s) { return ''; }"
                        "var absolute = s;"
                        "try { absolute = String(new URL(s, document.baseURI).toString()); } catch (error) {}"
                        "var lowercase = absolute.toLowerCase();"
                        "if (lowercase.indexOf('blob:') === 0 || lowercase.indexOf('data:') === 0 || lowercase.indexOf('mediastream:') === 0) { return ''; }"
                        "if (lowercase.indexOf('http:') !== 0 && lowercase.indexOf('https:') !== 0) { return ''; }"
                        "return clipProbeString(absolute);"
                    "} catch (error) { return ''; }"
                "}"
                "function buildProbePayload() {"
                    "var payload = {pageURL: clipProbeString(document.location.href), videos: [], captured: []};"
                    "try {"
                        "var nodes = document.querySelectorAll('video');"
                        "for (var i = 0; i < nodes.length && payload.videos.length < 4; i += 1) {"
                            "var v = nodes[i];"
                            "payload.videos.push({"
                                "src: probeHttpURL(v.src),"
                                "currentSrc: probeHttpURL(v.currentSrc),"
                                "paused: v.paused === true,"
                                "duration: (typeof v.duration === 'number' && isFinite(v.duration)) ? v.duration : 0,"
                                "title: clipProbeString(v.title),"
                                "poster: probeHttpURL(v.poster)"
                            "});"
                        "}"
                    "} catch (error) {}"
                    "try {"
                        "var probeList = window.__browserCapturedMediaURLs;"
                        "if (Array.isArray(probeList)) {"
                            "for (var j = probeList.length - 1; j >= 0 && payload.captured.length < 8; j -= 1) {"
                                "var capturedURL = probeHttpURL(probeList[j]);"
                                "if (capturedURL) { payload.captured.push(capturedURL); }"
                            "}"
                        "}"
                    "} catch (error) {}"
                    "return payload;"
                "}"
                "function postProbeReport(force) {"
                    "try {"
                        "var payload = buildProbePayload();"
                        "if (payload.videos.length === 0 && payload.captured.length === 0) { return; }"
                        "var json = JSON.stringify(payload);"
                        "if (!force && json === probeLastPayload) { return; }"
                        "probeLastPayload = json;"
                        "window.webkit.messageHandlers.browserMediaProbe.postMessage(payload);"
                    "} catch (error) {}"
                "}"
                "var probeEventNames = ['loadstart', 'play', 'loadedmetadata'];"
                "for (var p = 0; p < probeEventNames.length; p += 1) {"
                    "document.addEventListener(probeEventNames[p], function() { postProbeReport(true); }, true);"
                "}"
                "setInterval(function() { postProbeReport(false); }, 2000);"
                // Headless forced play (ForcePlayOnLaunch, default OFF): one
                // shot per document — pick the largest visible video that is
                // ready or has a src, mute it so the autoplay policy accepts
                // the play, start it, and log once. Runs on its own timer so
                // the probe report shape and throttle above stay untouched.
                "if (window.__browserMediaEngineConfig.forcePlay) {"
                    "function tryForcedPlay() {"
                        "try {"
                            "if (window.__nebulaForcedPlay) { return; }"
                            "var videos = document.querySelectorAll('video');"
                            "var bestVideo = null;"
                            "var bestArea = -1;"
                            "for (var f = 0; f < videos.length; f += 1) {"
                                "var candidate = videos[f];"
                                "if (!(candidate.videoWidth >= 200)) { continue; }"
                                "var candidateReady = false;"
                                "try { candidateReady = candidate.readyState >= 2 || !!(candidate.currentSrc || candidate.src); } catch (error) { candidateReady = false; }"
                                "if (!candidateReady) { continue; }"
                                "var area = candidate.videoWidth * (candidate.videoHeight || 0);"
                                "if (area > bestArea) { bestArea = area; bestVideo = candidate; }"
                            "}"
                            "if (bestVideo === null || bestVideo.paused !== true) { return; }"
                            "window.__nebulaForcedPlay = true;"
                            "bestVideo.muted = true;"
                            "try {"
                                "var playResult = bestVideo.play();"
                                "if (playResult && typeof playResult.catch === 'function') { playResult.catch(function() {}); }"
                                // Success: report immediately so a ForceNativePresentOnPlay
                                // host sees the playing video without waiting a probe tick.
                                "if (playResult && typeof playResult.then === 'function') { playResult.then(function() { try { postProbeReport(true); } catch (error) {} }); }"
                            "} catch (error) {}"
                            "console.log('[ForcePlay] forced play attempt');"
                        "} catch (error) {}"
                    "}"
                    "setInterval(function() { tryForcedPlay(); }, 2000);"
                "}"
            "}"
        "} catch (error) {}"
    "})();";
    return [config stringByAppendingString:script];
}

static NSString *BrowserMediaEngineUserScript(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return BrowserMediaEngineUserScriptWithFlags(
        ![defaults boolForKey:@"MediaEngineHlsFlagDisabled"],
        ![defaults boolForKey:@"MediaEngineNetFlagDisabled"],
        ![defaults boolForKey:@"MediaEngineSrcFlagDisabled"],
        ![defaults boolForKey:@"MediaEngineProbeFlagDisabled"],
        ![defaults boolForKey:@"NativeVideoModeDisabled"],
        [defaults boolForKey:@"ForcePlayOnLaunch"]);
}

// All-frames anti-hijack script (popup blocker + ad-overlay defusing +
// visibility spoof), installed alongside BrowserMediaEngineUserScript at the
// same injection point. Sections are gated inside the page by the config
// literal built from the (default-NO) PopupBlockerDisabled /
// VisibilitySpoofDisabled NSUserDefaults keys.
//
// Popup policy (kept deliberately simple, ES5, nothing throws into page code):
// a window.open is allowed when it happens within 800 ms of a real
// pointerdown/click seen in THIS frame (captured-phase listeners maintain a
// per-frame __lastUserGestureTs), when it targets a blob: URL, or when it
// resolves to the same origin as the top document. Everything else — the
// classic about:blank/javascript:/about:srcdoc ad-openers and every open
// issued from a sub-frame (the streameast embeds live in iframes and pop from
// there) — is blocked by returning null and reported through the
// browserMediaProbe channel as {blocked:true, url}.
// <a target=_blank> clicks from non-main frames go through the same policy
// (preventDefault when the policy says block).
//
// Ad overlay hijack: instead of destructive global CSS, a 1500 ms sweep finds
// fixed/absolute elements with z-index >= 999 covering >60% of the viewport
// with no interactive descendants (the invisible "click anywhere -> popunder"
// layer) and sets pointer-events:none on them. Elements processed per sweep
// are capped and iframes are skipped.
//
// Visibility spoof (play-after-pause fix): hypothesis — the site's player
// watches document.hidden/visibilitychange (and blur) and tears down its
// buffer when the page "goes hidden"; on tvOS WKWebView our probe intervals /
// alert presentations can flip that and the video never resumes. Fix: with
// any <video> present and the per-page __browserFakeVisibility flag on
// (default ON, gate VisibilitySpoofDisabled), report document.hidden as false
// so the site never sees "hidden", and re-dispatch a synthetic cancelable
// visibilitychange when the page becomes visible again so listeners that
// re-attach their buffer run against the spoofed visible state.
static NSString *BrowserPopupBlockerUserScriptWithFlags(BOOL popupEnabled, BOOL visibilityEnabled) {
    NSString *config =
        [NSString stringWithFormat:
            @"window.__browserPopupBlockerConfig = {block:%@,vis:%@};",
            popupEnabled ? @"true" : @"false",
            visibilityEnabled ? @"true" : @"false"];
    NSString *script =
    @"(function(){"
        "if (window.__browserPopupBlockerInstalled) { return; }"
        "window.__browserPopupBlockerInstalled = true;"
        "window.__browserPopupBlockerConfig = window.__browserPopupBlockerConfig || {block:true,vis:true};"
        "window.__lastUserGestureTs = window.__lastUserGestureTs || 0;"
        // Default ON: the spoof opts out via VisibilitySpoofDisabled, which
        // arrives as vis:false in the config above.
        "window.__browserFakeVisibility = window.__browserPopupBlockerConfig.vis ? true : false;"
        "function popupNow() { try { return Date.now(); } catch (error) { return 0; } }"
        "function popupBlockerHasProbe() {"
            "try { return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserMediaProbe); } catch (error) { return false; }"
        "}"
        "function popupClip(value) { var s = String(value == null ? '' : value); if (s.length > 500) { s = s.slice(0, 500); } return s; }"
        "function postPopupBlock(url, overlay) {"
            "try {"
                "if (!popupBlockerHasProbe()) { return; }"
                "var payload = {blocked: true, url: popupClip(url)};"
                "if (overlay) { payload.overlay = true; }"
                "window.webkit.messageHandlers.browserMediaProbe.postMessage(payload);"
            "} catch (error) {}"
        "}"
        "function popupIsTopFrame() {"
            "try { return window.top === window.self; } catch (error) { return false; }"
        "}"
        "function popupWithinGestureWindow() {"
            "try { return (popupNow() - window.__lastUserGestureTs) <= 800; } catch (error) { return false; }"
        "}"
        "function popupSameOriginToTop(url) {"
            "try {"
                "var raw = String(url == null ? '' : url);"
                "if (!raw) { return false; }"
                "var topHref = '';"
                "try { topHref = String(window.top.location.href || ''); } catch (error) { return false; }"
                "if (!topHref) { return false; }"
                "var topOrigin, candidate;"
                "try {"
                    "topOrigin = String(new URL(topHref).origin || '');"
                    "candidate = String(new URL(raw, document.baseURI).origin || '');"
                "} catch (error) { return false; }"
                "return !!topOrigin && topOrigin === candidate;"
            "} catch (error) { return false; }"
        "}"
        "function popupShouldBlock(url) {"
            "try {"
                // Never block: real user gesture in this frame, blob:, or
                // same-origin to the top document.
                "if (popupWithinGestureWindow()) { return false; }"
                "var u = String(url == null ? '' : url).toLowerCase();"
                "if (u.indexOf('blob:') === 0) { return false; }"
                "if (popupSameOriginToTop(url)) { return false; }"
                // Block heuristics: sub-frame opens, and blankish targets
                // (about:blank / about:srcdoc / javascript: / empty) are the
                // classic ad-popup shapes. A non-gesture http(s) popup from
                // the top frame is blocked too (it failed the allow-list).
                "return true;"
            "} catch (error) { return false; }"
        "}"
        "try {"
            "if (window.__browserPopupBlockerConfig.block) {"
                // Per-frame user-gesture timestamps: capture-phase listeners
                // so page stopPropagation() cannot hide a real click.
                "var popupMarkGesture = function() { try { window.__lastUserGestureTs = popupNow(); } catch (error) {} };"
                "window.addEventListener('pointerdown', popupMarkGesture, true);"
                "window.addEventListener('click', popupMarkGesture, true);"
            "}"
        "} catch (error) {}"
        "try {"
            "if (window.__browserPopupBlockerConfig.block && window.open) {"
                "var popupOriginalOpen = window.open;"
                "window.open = function(url) {"
                    "try {"
                        "if (popupShouldBlock(url)) {"
                            "postPopupBlock(url, false);"
                            "return null;"
                        "}"
                    "} catch (error) {}"
                    "return popupOriginalOpen.apply(this, arguments);"
                "};"
            "}"
        "} catch (error) {}"
        "try {"
            "if (window.__browserPopupBlockerConfig.block) {"
                // <a target=_blank> from non-main frames: route through the
                // same policy; the main frame keeps default behavior.
                "document.addEventListener('click', function(event) {"
                    "try {"
                        "if (popupIsTopFrame()) { return; }"
                        "var node = event && event.target;"
                        "var anchor = null;"
                        "while (node && node !== document) {"
                            "if (String(node.tagName || '').toUpperCase() === 'A') { anchor = node; break; }"
                            "node = node.parentNode;"
                        "}"
                        "if (!anchor) { return; }"
                        "if (!/blank/i.test(String(anchor.target || ''))) { return; }"
                        "var href = String(anchor.href || anchor.getAttribute('href') || '');"
                        "if (popupShouldBlock(href)) {"
                            "event.preventDefault();"
                            "postPopupBlock(href, false);"
                        "}"
                    "} catch (error) {}"
                "}, true);"
            "}"
        "} catch (error) {}"
        "try {"
            "if (window.__browserPopupBlockerConfig.block) {"
                // Overlay hijack sweep: one interval, capped work per pass.
                "setInterval(function() {"
                    "try {"
                        "var vw = window.innerWidth || 0;"
                        "var vh = window.innerHeight || 0;"
                        "if (vw <= 0 || vh <= 0) { return; }"
                        "var viewportArea = vw * vh;"
                        "var candidates = document.querySelectorAll('div,ins,section,aside,span,canvas,embed');"
                        "var processed = 0;"
                        "for (var i = 0; i < candidates.length && processed < 200; i += 1) {"
                            "var element = candidates[i];"
                            "try {"
                                "var tagName = String(element.tagName || '').toUpperCase();"
                                "if (tagName === 'IFRAME') { continue; }"
                                "if (element.__browserOverlayDefused) { continue; }"
                                "var style = window.getComputedStyle(element);"
                                "var position = String(style.position || '');"
                                "if (position !== 'fixed' && position !== 'absolute') { continue; }"
                                "var zIndex = parseInt(style.zIndex, 10);"
                                "if (!isFinite(zIndex)) { zIndex = 0; }"
                                "if (zIndex < 999) { continue; }"
                                "var rect = element.getBoundingClientRect();"
                                "var area = (rect.width > 0 ? rect.width : 0) * (rect.height > 0 ? rect.height : 0);"
                                "if (area <= viewportArea * 0.6) { continue; }"
                                "if (element.querySelector('a,button,input,select,textarea,video,iframe,canvas,[onclick]') !== null) { continue; }"
                                "element.style.setProperty('pointer-events', 'none', 'important');"
                                "element.__browserOverlayDefused = true;"
                                "processed += 1;"
                                "postPopupBlock('overlay:' + tagName + (element.id ? ('#' + element.id) : '') + ':z' + zIndex, true);"
                            "} catch (error) {}"
                        "}"
                    "} catch (error) {}"
                "}, 1500);"
            "}"
        "} catch (error) {}"
        "try {"
            "if (window.__browserPopupBlockerConfig.vis) {"
                "var hiddenDescriptor = null;"
                "try { hiddenDescriptor = Object.getOwnPropertyDescriptor(document, 'hidden'); } catch (error) {}"
                "try { if (!hiddenDescriptor) { hiddenDescriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden'); } } catch (error) {}"
                // Hypothesis (see header comment): the player's visibilitychange
                // handler destroys its buffer when the page reports hidden. Keep
                // the REAL hidden value readable through the original getter
                // only, and spoof false whenever a <video> exists.
                "var realHiddenValue = function() {"
                    "try {"
                        "if (hiddenDescriptor && typeof hiddenDescriptor.get === 'function') { return hiddenDescriptor.get.call(document) === true; }"
                    "} catch (error) {}"
                    "return false;"
                "};"
                "if (hiddenDescriptor) {"
                    "try {"
                        "Object.defineProperty(document, 'hidden', {"
                            "configurable: true,"
                            "get: function() {"
                                "try {"
                                    "if (window.__browserFakeVisibility === true && document.getElementsByTagName('video').length > 0) { return false; }"
                                "} catch (error) {}"
                                "return realHiddenValue();"
                            "}"
                        "});"
                    "} catch (error) {}"
                    "var stateDescriptor = null;"
                    "try { stateDescriptor = Object.getOwnPropertyDescriptor(document, 'visibilityState'); } catch (error) {}"
                    "try { if (!stateDescriptor) { stateDescriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState'); } } catch (error) {}"
                    "if (stateDescriptor) {"
                        "try {"
                            "Object.defineProperty(document, 'visibilityState', {"
                                "configurable: true,"
                                "get: function() {"
                                    "try {"
                                        "if (window.__browserFakeVisibility === true && document.getElementsByTagName('video').length > 0) { return 'visible'; }"
                                    "} catch (error) {}"
                                    "try { if (typeof stateDescriptor.get === 'function') { return stateDescriptor.get.call(document); } } catch (error) {}"
                                    "return 'visible';"
                                "}"
                            "});"
                        "} catch (error) {}"
                    "}"
                    // Becoming visible again: re-run the page's handlers with
                    // the spoofed visible state (synthetic, cancelable, and
                    // marked so our own listener does not loop).
                    "document.addEventListener('visibilitychange', function(event) {"
                        "try {"
                            "if (event && event.__browserSyntheticVisibility) { return; }"
                            "if (window.__browserFakeVisibility !== true) { return; }"
                            "if (realHiddenValue()) { return; }"
                            "var synthetic = new Event('visibilitychange', {bubbles: true, cancelable: true});"
                            "synthetic.__browserSyntheticVisibility = true;"
                            "document.dispatchEvent(synthetic);"
                        "} catch (error) {}"
                    "}, true);"
                "}"
            "}"
        "} catch (error) {}"
    "})();";
    return [config stringByAppendingString:script];
}

static NSString *BrowserPopupBlockerUserScript(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return BrowserPopupBlockerUserScriptWithFlags(
        ![defaults boolForKey:@"PopupBlockerDisabled"],
        ![defaults boolForKey:@"VisibilitySpoofDisabled"]);
}

// tvOS WebKit routes <video> fullscreen to AVPlayerViewController's
// enterFullScreenAnimated:, which the OS doesn't support — the transition fails
// halfway and leaves the page (and the focus system) frozen. Replace the
// fullscreen APIs with a CSS-based fullscreen that never leaves the page.
static NSString *BrowserFakeFullscreenScript(void) {
    return
    @"(function(){"
        "if (window.__browserFakeFullscreenInstalled) { return; }"
        "window.__browserFakeFullscreenInstalled = true;"
        "var fullscreenElement = null;"
        "var savedStyle = null;"
        "var savedOverflow = null;"
        "function fireEvent(target, name) {"
            "try { target.dispatchEvent(new Event(name, {bubbles: true})); } catch (e) {}"
        "}"
        "function notifyChange() {"
            "fireEvent(document, 'fullscreenchange');"
            "fireEvent(document, 'webkitfullscreenchange');"
        "}"
        "var pendingElement = null;"
        "function requestNativeFullscreen(element) {"
            "if (!element) { return; }"
            "pendingElement = element;"
            "var video = (element.tagName === 'VIDEO') ? element : element.querySelector('video');"
            "var src = '';"
            "var time = 0;"
            "if (video) {"
                "src = video.currentSrc || video.src || '';"
                "time = video.currentTime || 0;"
            "}"
            "var sent = false;"
            "try {"
                "if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserFullscreen) {"
                    "window.webkit.messageHandlers.browserFullscreen.postMessage({"
                        "src: src,"
                        "time: time,"
                        "title: document.title || '',"
                        "capturedMedia: (function() {"
                            "var list = window.__browserCapturedMediaURLs || [];"
                            "var result = [];"
                            "for (var i = list.length - 1; i >= 0 && result.length < 8; i -= 1) {"
                                "result.push(String(list[i]));"
                            "}"
                            "return result;"
                        "})(),"
                        "pageURL: document.location.href || ''"
                    "});"
                    "sent = true;"
                "}"
            "} catch (e) {}"
            "if (!sent) { enterFullscreen(element); }"
        "}"
        "window.__browserApplyCssFullscreen = function() {"
            "if (pendingElement) { enterFullscreen(pendingElement); }"
        "};"
        "function enterFullscreen(element) {"
            "if (!element || fullscreenElement === element) { return; }"
            "if (fullscreenElement) { exitFullscreen(); }"
            "fullscreenElement = element;"
            "savedStyle = element.getAttribute('style');"
            "savedOverflow = document.documentElement.style.overflow;"
            "element.style.setProperty('position', 'fixed', 'important');"
            "element.style.setProperty('top', '0', 'important');"
            "element.style.setProperty('left', '0', 'important');"
            "element.style.setProperty('width', '100vw', 'important');"
            "element.style.setProperty('height', '100vh', 'important');"
            "element.style.setProperty('max-width', 'none', 'important');"
            "element.style.setProperty('max-height', 'none', 'important');"
            "element.style.setProperty('margin', '0', 'important');"
            "element.style.setProperty('padding', '0', 'important');"
            "element.style.setProperty('z-index', '2147483647', 'important');"
            "element.style.setProperty('background-color', 'black', 'important');"
            "if (element.tagName === 'VIDEO') {"
                "element.style.setProperty('object-fit', 'contain', 'important');"
                "fireEvent(element, 'webkitbeginfullscreen');"
            "}"
            "document.documentElement.style.overflow = 'hidden';"
            "notifyChange();"
        "}"
        "function exitFullscreen() {"
            "var element = fullscreenElement;"
            "if (!element) { return; }"
            "fullscreenElement = null;"
            "if (savedStyle === null) { element.removeAttribute('style'); }"
            "else { element.setAttribute('style', savedStyle); }"
            "savedStyle = null;"
            "document.documentElement.style.overflow = savedOverflow || '';"
            "savedOverflow = null;"
            "if (element.tagName === 'VIDEO') { fireEvent(element, 'webkitendfullscreen'); }"
            "notifyChange();"
        "}"
        "try {"
            "HTMLVideoElement.prototype.webkitEnterFullscreen = function() { requestNativeFullscreen(this); };"
            "HTMLVideoElement.prototype.webkitEnterFullScreen = function() { requestNativeFullscreen(this); };"
            "HTMLVideoElement.prototype.webkitExitFullscreen = function() { exitFullscreen(); };"
            "HTMLVideoElement.prototype.webkitExitFullScreen = function() { exitFullscreen(); };"
            "Object.defineProperty(HTMLVideoElement.prototype, 'webkitSupportsFullscreen', { get: function() { return true; }, configurable: true });"
            "Object.defineProperty(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', { get: function() { return this === fullscreenElement; }, configurable: true });"
        "} catch (e) {}"
        "try {"
            "Element.prototype.requestFullscreen = function() { requestNativeFullscreen(this); return Promise.resolve(); };"
            "Element.prototype.webkitRequestFullscreen = function() { requestNativeFullscreen(this); };"
            "Element.prototype.webkitRequestFullScreen = function() { requestNativeFullscreen(this); };"
            "document.exitFullscreen = function() { exitFullscreen(); return Promise.resolve(); };"
            "document.webkitExitFullscreen = function() { exitFullscreen(); };"
            "document.webkitCancelFullScreen = function() { exitFullscreen(); };"
            "Object.defineProperty(Document.prototype, 'fullscreenElement', { get: function() { return fullscreenElement; }, configurable: true });"
            "Object.defineProperty(Document.prototype, 'webkitFullscreenElement', { get: function() { return fullscreenElement; }, configurable: true });"
            "Object.defineProperty(Document.prototype, 'webkitCurrentFullScreenElement', { get: function() { return fullscreenElement; }, configurable: true });"
            "Object.defineProperty(Document.prototype, 'fullscreenEnabled', { get: function() { return true; }, configurable: true });"
            "Object.defineProperty(Document.prototype, 'webkitFullscreenEnabled', { get: function() { return true; }, configurable: true });"
        "} catch (e) {}"
    "})();";
}

static void BrowserInstallUserScriptSource(id configuration, NSString *source) {
    if (configuration == nil || source.length == 0) {
        return;
    }

    Class userContentControllerClass = NSClassFromString(kBrowserUserContentControllerClassName);
    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    if (userContentControllerClass == Nil || userScriptClass == Nil) {
        return;
    }

    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL setUserContentControllerSelector = NSSelectorFromString(@"setUserContentController:");
    id userContentController = nil;
    if ([configuration respondsToSelector:userContentControllerGetter]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    }

    if (userContentController == nil && [configuration respondsToSelector:setUserContentControllerSelector]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)((id)userContentControllerClass, @selector(new));
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setUserContentControllerSelector, userContentController);
    }

    SEL addUserScriptSelector = NSSelectorFromString(@"addUserScript:");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (userContentController == nil ||
        ![userContentController respondsToSelector:addUserScriptSelector] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }

    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, source, 0, NO);
    if (userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, userScript);
    }
}

static void BrowserInstallYouTubeCaptureUserScript(id configuration) {
    if (configuration == nil) {
        return;
    }

    Class userContentControllerClass = NSClassFromString(kBrowserUserContentControllerClassName);
    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    if (userContentControllerClass == Nil || userScriptClass == Nil) {
        return;
    }

    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL setUserContentControllerSelector = NSSelectorFromString(@"setUserContentController:");
    id userContentController = nil;
    if ([configuration respondsToSelector:userContentControllerGetter]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    }

    if (userContentController == nil && [configuration respondsToSelector:setUserContentControllerSelector]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)((id)userContentControllerClass, @selector(new));
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setUserContentControllerSelector, userContentController);
    }

    SEL addUserScriptSelector = NSSelectorFromString(@"addUserScript:");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (userContentController == nil ||
        ![userContentController respondsToSelector:addUserScriptSelector] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }

    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, BrowserYouTubeRequestCaptureScript(), 0, NO);
    if (userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, userScript);
    }
}

@interface BrowserWebView () {
    // Latest per-frame media probe reports: frame key (pageURL host+path) ->
    // payload dictionary plus an _mediaProbeTimestamp NSDate. Written on the
    // main thread only (script message handlers deliver there).
    NSMutableDictionary<NSString *, NSDictionary *> *_mediaProbeByFrame;
    // The reporting frame's WKScriptMessage.frameInfo (kept as id: this file
    // talks to WebKit through the runtime only), keyed like _mediaProbeByFrame
    // and replaced per report. Lets JS be evaluated directly in the
    // cross-origin embed frames' documents. Main thread only.
    NSMutableDictionary<NSString *, id> *_frameInfoByFrameKey;
    // When each _frameInfoByFrameKey entry was stored (the frameInfo's own
    // lifetime, parallel to it). Resume targeting prunes on THIS age, not on
    // probe freshness: the embed's probe script stops reporting while the
    // native player owns playback, yet its WKFrameInfo stays valid to target
    // through the reload the embed performs at takeover/dismissal.
    NSMutableDictionary<NSString *, NSDate *> *_frameInfoStoredTimeByFrameKey;
    // {url, timestamp} entries reported by the popup blocker script, capped;
    // newest-last. Main thread only.
    NSMutableArray<NSDictionary *> *_blockedPopups;
    // Per-frame "a video is currently playing" (any video with paused=false),
    // used to catch the paused:true -> false transition for the auto-fullscreen
    // prompt. Main thread only.
    NSMutableDictionary<NSString *, NSNumber *> *_probePlayingByFrame;
    // Auto-fullscreen prompt is offered at most once per page load; reset with
    // the probe state on provisional navigation.
    BOOL _embedPlaybackPromptOffered;
    // ForceNativePresentOnPlay: the auto-present has fired for this document.
    BOOL _forceNativePresentFired;
}

@property (nullable, nonatomic, strong) id runtimeWebView;
@property (nullable, nonatomic, strong) NSURLRequest *lastRequest;
@property (nullable, nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL loading;
@property (nullable, nonatomic, strong) BrowserWeakScriptMessageForwarder *fullscreenMessageForwarder;
@property (nullable, nonatomic, strong) BrowserWeakScriptMessageForwarder *mediaProbeMessageForwarder;

@end

@implementation BrowserWebView

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithUserAgent:nil allowsInlineMediaPlayback:YES];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInitWithUserAgent:nil allowsInlineMediaPlayback:YES];
    }
    return self;
}

- (instancetype)initWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self commonInitWithUserAgent:userAgent allowsInlineMediaPlayback:allowsInlineMediaPlayback];
    }
    return self;
}

- (void)commonInitWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    BrowserEnsureWebKitRuntimeLoaded();

    self.backgroundColor = UIColor.blackColor;
    self.userAgent = userAgent;
    self.scalesPageToFit = NO;

    Class configurationClass = NSClassFromString(kBrowserWebViewConfigurationClassName);
    Class webViewClass = NSClassFromString(kBrowserWebViewClassName);
    if (configurationClass == Nil || webViewClass == Nil) {
        return;
    }

    id configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(new));
    SEL allowsInlineMediaPlaybackSelector = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if (configuration != nil && [configuration respondsToSelector:allowsInlineMediaPlaybackSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, allowsInlineMediaPlaybackSelector, allowsInlineMediaPlayback);
    }
    // Synthetic clicks (cursor mode) don't carry user activation, so a page's
    // play button calling video.play() would be blocked. Drop the user-action
    // requirement so taps on play overlays actually start playback.
    SEL mediaTypesSelector = NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if (configuration != nil && [configuration respondsToSelector:mediaTypesSelector]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaTypesSelector, 0); // WKAudiovisualMediaTypeNone
    }
    // Autoplay launch flag (-WebViewAutoPlayAll YES, default NO): explicitly
    // removes the user-gesture requirement for embedded players so unattended
    // regression runs autoplay right after page load. NOTE: the synthetic
    // click fix above already assigns WKAudiovisualMediaTypeNone for every
    // web view today, so the OFF path is byte-identical to before and the ON
    // path re-applies the same value; the flag only becomes a behavioral gate
    // if the unconditional default assignment above is ever narrowed.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"WebViewAutoPlayAll"]) {
        if (configuration != nil && [configuration respondsToSelector:mediaTypesSelector]) {
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaTypesSelector, 0); // WKAudiovisualMediaTypeNone
        }
    }
    BrowserConfigurePrivateMediaPreferences(configuration);
    BrowserInstallYouTubeCaptureUserScript(configuration);
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"MediaEngineHooksDisabled"]) {
        BrowserInstallUserScriptSource(configuration, BrowserMediaEngineUserScript());
    }
    // Popup blocker + visibility spoof: same injection point, own gates
    // (PopupBlockerDisabled / VisibilitySpoofDisabled) evaluated per webview.
    BrowserInstallUserScriptSource(configuration, BrowserPopupBlockerUserScript());
    BrowserInstallUserScriptSource(configuration, BrowserFakeFullscreenScript());
    [self installFullscreenScriptMessageHandlerOnConfiguration:configuration];
    [self installMediaProbeScriptMessageHandlerOnConfiguration:configuration];

    id webViewObject = ((id (*)(id, SEL))objc_msgSend)((id)webViewClass, @selector(alloc));
    SEL initializer = NSSelectorFromString(@"initWithFrame:configuration:");
    webViewObject = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webViewObject, initializer, self.bounds, configuration);
    if (webViewObject == nil) {
        return;
    }

    self.runtimeWebView = webViewObject;
    UIView *runtimeView = (UIView *)webViewObject;
    runtimeView.frame = self.bounds;
    runtimeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    runtimeView.backgroundColor = UIColor.blackColor;

    SEL navigationDelegateSelector = NSSelectorFromString(@"setNavigationDelegate:");
    if ([webViewObject respondsToSelector:navigationDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, navigationDelegateSelector, self);
    }

    SEL UIDelegateSelector = NSSelectorFromString(@"setUIDelegate:");
    if ([webViewObject respondsToSelector:UIDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, UIDelegateSelector, self);
    }

    [self addSubview:runtimeView];
    [self setUserAgent:userAgent];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.runtimeWebView).frame = self.bounds;
    [self applyPageScalingIfNeeded];
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];

    UIView *runtimeView = (UIView *)self.runtimeWebView;
    runtimeView.userInteractionEnabled = userInteractionEnabled;

    UIScrollView *scrollView = [self scrollView];
    scrollView.userInteractionEnabled = userInteractionEnabled;
}

- (UIScrollView *)scrollView {
    SEL selector = NSSelectorFromString(@"scrollView");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURL *)currentURL {
    SEL selector = NSSelectorFromString(@"URL");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURLRequest *)request {
    NSURL *currentURL = [self currentURL];
    if (currentURL != nil) {
        return [NSURLRequest requestWithURL:currentURL];
    }
    return self.lastRequest;
}

- (NSString *)title {
    SEL selector = NSSelectorFromString(@"title");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return self.lastTitle;
    }
    NSString *title = ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    return title ?: self.lastTitle;
}

- (BOOL)canGoBack {
    SEL selector = NSSelectorFromString(@"canGoBack");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (BOOL)canGoForward {
    SEL selector = NSSelectorFromString(@"canGoForward");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (void)loadRequest:(NSURLRequest *)request {
    if (request == nil || self.runtimeWebView == nil) {
        return;
    }
    self.lastRequest = request;
    SEL selector = NSSelectorFromString(@"loadRequest:");
    if ([self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, request);
    }
}

- (void)reload {
    SEL selector = NSSelectorFromString(@"reload");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goBack {
    SEL selector = NSSelectorFromString(@"goBack");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goForward {
    SEL selector = NSSelectorFromString(@"goForward");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script {
    if (script.length == 0 || self.runtimeWebView == nil) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    __block id evaluationResult = nil;
    __block NSError *evaluationError = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, ^(id result, NSError *error) {
        evaluationResult = result;
        evaluationError = error;
        finished = YES;
        CFRunLoopStop(runLoop); // wake the pump immediately
    });
    CFAbsoluteTime evalStart = CFAbsoluteTimeGetCurrent();
    // Capture before pumping: a nonzero depth here means an outer pump owns
    // the main thread, so the pump's NO is a nested rejection, not a timeout.
    BOOL nestedPumpActive = sBrowserPumpDepth > 0;
    BOOL pumped = BrowserPumpRunLoopUntil(&finished, runLoop, BrowserSyncEvalPumpTimeout());
    if (!pumped && !finished) {
        NSString *truncatedScript = script.length > 60 ? [script substringToIndex:60] : script;
        if (nestedPumpActive) {
            NSLog(@"[SyncEval] nested-pump rejected script=%@", truncatedScript);
        } else {
            // Rate-limit: one input chain can produce several full-timeout evals
            // back to back; at most one log line per 500ms.
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            static CFAbsoluteTime sLastSyncEvalTimeoutLog = 0.0;
            if (now - sLastSyncEvalTimeoutLog >= 0.5) {
                sLastSyncEvalTimeoutLog = now;
                NSLog(@"[SyncEval] timeout after %.0fms script=%@", (now - evalStart) * 1000.0, truncatedScript);
            }
        }
        return nil;
    }

    if (evaluationError != nil) {
        return nil;
    }
    return BrowserStringFromJavaScriptResult(evaluationResult);
}

// Fire-and-forget: evaluate JS without blocking the caller. Use when the result
// is not needed (applying styles, dispatching synthetic events, installing hooks).
- (void)evaluateJavaScriptStringAsync:(NSString *)script {
    [self evaluateJavaScriptStringAsync:script completion:nil];
}

- (void)evaluateJavaScriptStringAsync:(NSString *)script completion:(void (^)(id _Nullable result))completion {
    if (script.length == 0 || self.runtimeWebView == nil) {
        if (completion != nil) {
            completion(nil);
        }
        return;
    }
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.runtimeWebView respondsToSelector:selector]) {
        if (completion != nil) {
            completion(nil);
        }
        return;
    }
    // completionHandler:(void (^)(id, NSError *)) — bridged through objc_msgSend
    // like every other runtime-WebView call in this file.
    id completionHandler = nil;
    if (completion != nil) {
        completionHandler = ^(id result, __unused NSError *error) { completion(result); };
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, completionHandler);
}

- (void)pauseAllMediaPlayback {
    if (self.runtimeWebView == nil) {
        return;
    }

    // Prefer WebKit's internal media pause APIs when available.
    SEL pauseWithCompletionHandlerSelector = NSSelectorFromString(@"pauseAllMediaPlaybackWithCompletionHandler:");
    if ([self.runtimeWebView respondsToSelector:pauseWithCompletionHandlerSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseWithCompletionHandlerSelector, nil);
    } else {
        SEL pauseSelector = NSSelectorFromString(@"pauseAllMediaPlayback:");
        if ([self.runtimeWebView respondsToSelector:pauseSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseSelector, nil);
        } else {
            SEL privatePauseSelector = NSSelectorFromString(@"_pauseAllMediaPlayback");
            if ([self.runtimeWebView respondsToSelector:privatePauseSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, privatePauseSelector);
            }
        }
    }

    // JS fallback for page media elements and common iframe-based players.
    NSString *pauseScript =
        @"(function(){"
            "function safe(fn){ try { fn(); } catch (error) {} }"
            "var media = document.querySelectorAll('video,audio');"
            "for (var i = 0; i < media.length; i++) {"
                "var element = media[i];"
                "safe(function(){ element.pause(); });"
                "safe(function(){ element.autoplay = false; });"
                "safe(function(){ element.removeAttribute('autoplay'); });"
            "}"
            "var iframePlayers = document.querySelectorAll('iframe');"
            "for (var j = 0; j < iframePlayers.length; j++) {"
                "var frame = iframePlayers[j];"
                "var src = String(frame.src || '').toLowerCase();"
                "if (!src) { continue; }"
                "safe(function(){"
                    "if (src.indexOf('youtube.com') !== -1 || src.indexOf('youtube-nocookie.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:''}), '*');"
                    "}"
                "});"
                "safe(function(){"
                    "if (src.indexOf('vimeo.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({method:'pause'}), '*');"
                    "}"
                "});"
            "}"
        "})();";
    [self evaluateJavaScriptStringAsync:pauseScript];
}

- (NSString *)runtimeMediaPreferenceReport {
    if (self.runtimeWebView == nil) {
        return @"Runtime web view unavailable.";
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *objectSelectors = @[
        @{@"label": @"WKWebView", @"selector": @""},
        @{@"label": @"Configuration", @"selector": @"configuration"},
        @{@"label": @"Configuration._preferences", @"selector": @"configuration._preferences"},
        @{@"label": @"Configuration.preferences", @"selector": @"configuration.preferences"},
        @{@"label": @"Configuration.defaultWebpagePreferences", @"selector": @"configuration.defaultWebpagePreferences"},
        @{@"label": @"Configuration.websiteDataStore", @"selector": @"configuration.websiteDataStore"},
        @{@"label": @"WKWebView._configuration", @"selector": @"_configuration"},
        @{@"label": @"WKWebView._page", @"selector": @"_page"},
    ];

    NSMutableDictionary<NSValue *, NSString *> *seenObjects = [NSMutableDictionary dictionary];
    NSMutableString *report = [NSMutableString string];

    for (NSDictionary<NSString *, NSString *> *entry in objectSelectors) {
        NSString *label = entry[@"label"] ?: @"Object";
        NSString *selectorPath = entry[@"selector"] ?: @"";
        id currentObject = self.runtimeWebView;

        if (selectorPath.length > 0) {
            NSArray<NSString *> *components = [selectorPath componentsSeparatedByString:@"."];
            for (NSString *component in components) {
                currentObject = BrowserObjectResultForGetter(currentObject, component);
                if (currentObject == nil) {
                    break;
                }
            }
        }

        if (currentObject == nil) {
            [report appendFormat:@"[%@] unavailable\n\n", label];
            continue;
        }

        NSValue *objectKey = [NSValue valueWithNonretainedObject:currentObject];
        NSString *previousLabel = seenObjects[objectKey];
        if (previousLabel != nil) {
            [report appendFormat:@"[%@] same object as %@ (%@)\n\n", label, previousLabel, NSStringFromClass([currentObject class])];
            continue;
        }
        seenObjects[objectKey] = label;

        NSArray<NSString *> *selectorNames = BrowserFilteredSelectorNamesForClass([currentObject class]);
        NSMutableArray<NSString *> *booleanLines = [NSMutableArray array];
        for (NSString *selectorName in selectorNames) {
            NSString *getterName = nil;
            if ([selectorName hasPrefix:@"set"] && [selectorName hasSuffix:@":"]) {
                getterName = BrowserGetterNameFromSetterName(selectorName);
            } else {
                getterName = selectorName;
            }

            NSString *valueDescription = BrowserBooleanValueDescriptionForObjectAndSelector(currentObject, getterName);
            if (valueDescription != nil) {
                [booleanLines addObject:[NSString stringWithFormat:@"%@ = %@", getterName, valueDescription]];
            }
        }

        [report appendFormat:@"[%@] %@\n", label, NSStringFromClass([currentObject class])];
        if (booleanLines.count > 0) {
            [report appendString:@"Boolean getters:\n"];
            for (NSString *line in booleanLines) {
                [report appendFormat:@"- %@\n", line];
            }
        } else {
            [report appendString:@"Boolean getters:\n- none resolved\n"];
        }

        [report appendString:@"Matching selectors:\n"];
        if (selectorNames.count == 0) {
            [report appendString:@"- none\n\n"];
            continue;
        }

        for (NSString *selectorName in selectorNames) {
            [report appendFormat:@"- %@\n", selectorName];
        }

        if ([label isEqualToString:@"Configuration.preferences"]) {
            NSArray<NSDictionary<NSString *, NSString *> *> *featureEntries = BrowserFeatureEntriesForPreferences(currentObject);
            [report appendString:@"Feature entries:\n"];
            if (featureEntries.count == 0) {
                [report appendString:@"- none\n"];
            } else {
                for (NSDictionary<NSString *, NSString *> *featureEntry in featureEntries) {
                    NSString *featureSource = featureEntry[@"source"] ?: @"features";
                    NSString *featureName = featureEntry[@"name"] ?: @"Unknown";
                    NSString *featureEnabled = featureEntry[@"enabled"] ?: @"unknown";
                    NSString *featureKey = featureEntry[@"key"];
                    if (featureKey.length > 0) {
                        [report appendFormat:@"- [%@] %@ (%@) = %@\n", featureSource, featureName, featureKey, featureEnabled];
                    } else {
                        [report appendFormat:@"- [%@] %@ = %@\n", featureSource, featureName, featureEnabled];
                    }
                }
            }
        }
        [report appendString:@"\n"];
    }

    return BrowserPreviewString(report, 24000);
}

- (void)installYouTubeRequestCaptureHook {
    [self evaluateJavaScriptStringAsync:BrowserYouTubeRequestCaptureScript()];
    [self evaluateJavaScriptStringAsync:BrowserFakeFullscreenScript()];
}

- (void)setUserAgent:(NSString *)userAgent {
    _userAgent = [userAgent copy];
    SEL selector = NSSelectorFromString(@"setCustomUserAgent:");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, _userAgent);
    }
}

- (void)setScalesPageToFit:(BOOL)scalesPageToFit {
    _scalesPageToFit = scalesPageToFit;
    [self applyPageScalingIfNeeded];
}

- (void)applyPageScalingIfNeeded {
    if (self.runtimeWebView == nil) {
        return;
    }

    UIScrollView *scrollView = [self scrollView];
    if (scrollView == nil || CGRectIsEmpty(scrollView.bounds)) {
        return;
    }

    CGFloat zoomValue = 1.0;
    if (self.scalesPageToFit) {
        CGFloat contentWidth = scrollView.contentSize.width;
        CGFloat boundsWidth = CGRectGetWidth(scrollView.bounds);
        if (contentWidth > 1.0 && boundsWidth > 1.0) {
            zoomValue = MIN(1.0, MAX(0.25, boundsWidth / contentWidth));
        }
    }

    SEL pageZoomSelector = NSSelectorFromString(@"setPageZoom:");
    if ([self.runtimeWebView respondsToSelector:pageZoomSelector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(self.runtimeWebView, pageZoomSelector, zoomValue);
        return;
    }

    NSString *script = zoomValue == 1.0
        ? @"document.documentElement.style.zoom=''; document.body.style.zoom='';"
        : [NSString stringWithFormat:@"document.documentElement.style.zoom='%0.4f'; document.body.style.zoom='%0.4f';", zoomValue, zoomValue];
    [self evaluateJavaScriptStringAsync:script];
}

- (void)webView:(id)webView didStartProvisionalNavigation:(id)navigation {
    self.loading = YES;
    // A new main-frame page: reports from the previous page's frames are stale.
    // This callback also fires for iframe provisional navigations (a cross-origin
    // embed reloading its own document); wiping the registry then destroys the
    // embed WKFrameInfo the resume path needs. Gate the reset on main-frame.
    BOOL isMainFrame = YES; // unknown navigation/targetFrame: fall back to resetting
    @try {
        id targetFrame = [navigation valueForKey:@"targetFrame"];
        NSNumber *mainFrame = [targetFrame valueForKey:@"isMainFrame"];
        if (mainFrame) {
            isMainFrame = [mainFrame boolValue];
        }
    } @catch (NSException *exception) {
        isMainFrame = YES;
    }
    if (isMainFrame) {
        [self resetMediaProbeReports];
        NSLog(@"[NativeVideoPlayer] main-frame navigation: probe reports reset");
    }
    if ([self.delegate respondsToSelector:@selector(webViewDidStartLoad:)]) {
        [self.delegate webViewDidStartLoad:self];
    }
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    self.loading = NO;
    self.lastTitle = [self title];
    self.lastRequest = [self request];
    [self installYouTubeRequestCaptureHook];
    [self applyPageScalingIfNeeded];
    if ([self.delegate respondsToSelector:@selector(webViewDidFinishLoad:)]) {
        [self.delegate webViewDidFinishLoad:self];
    }
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    self.loading = NO;
    // DIAGNOSTIC(webshim): evidence for the google.com page-death repro — footprint at death + which page.
    struct task_vm_info vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    NSString *footprintDescription = @"unknown";
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
        footprintDescription = [NSString stringWithFormat:@"%.0fMB", (double)vmInfo.phys_footprint / (1024.0 * 1024.0)];
    }
    NSLog(@"[WebProcessDied] url=%@ appFootprint=%@ lastTitle=%@",
          self.request.URL.absoluteString ?: @"",
          footprintDescription,
          self.lastTitle ?: @"");
}

- (NSURLRequest *)requestFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return nil;
    }
    SEL requestSelector = NSSelectorFromString(@"request");
    if (![navigationAction respondsToSelector:requestSelector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(navigationAction, requestSelector);
}

- (NSInteger)navigationTypeFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return 0;
    }
    SEL navigationTypeSelector = NSSelectorFromString(@"navigationType");
    if (![navigationAction respondsToSelector:navigationTypeSelector]) {
        return 0;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, navigationTypeSelector);
}

- (void)webView:(id)webView decidePolicyForNavigationAction:(id)navigationAction decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];
    BOOL isMainFrameRequest = YES;

    SEL targetFrameSelector = NSSelectorFromString(@"targetFrame");
    if ([navigationAction respondsToSelector:targetFrameSelector]) {
        id targetFrame = ((id (*)(id, SEL))objc_msgSend)(navigationAction, targetFrameSelector);
        SEL mainFrameSelector = NSSelectorFromString(@"isMainFrame");
        if (targetFrame != nil && [targetFrame respondsToSelector:mainFrameSelector]) {
            isMainFrameRequest = ((BOOL (*)(id, SEL))objc_msgSend)(targetFrame, mainFrameSelector);
        }
    }

    BOOL shouldAllow = YES;
    if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
        shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
    }

    if (shouldAllow && isMainFrameRequest && request != nil) {
        self.lastRequest = request;
    }

    if (decisionHandler != nil) {
        decisionHandler(shouldAllow ? 1 : 0);
    }
}

#pragma mark - Fullscreen script message bridge

- (void)installFullscreenScriptMessageHandlerOnConfiguration:(id)configuration {
    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    if (configuration == nil || ![configuration respondsToSelector:userContentControllerGetter]) {
        return;
    }
    id userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    SEL addHandlerSelector = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if (userContentController == nil || ![userContentController respondsToSelector:addHandlerSelector]) {
        return;
    }
    BrowserWeakScriptMessageForwarder *forwarder = [BrowserWeakScriptMessageForwarder new];
    forwarder.target = self;
    self.fullscreenMessageForwarder = forwarder;
    ((void (*)(id, SEL, id, id))objc_msgSend)(userContentController, addHandlerSelector, forwarder, kBrowserFullscreenMessageHandlerName);
}

#pragma mark - Media probe script message bridge

// Mirror of the fullscreen handler install: second weak forwarder so the
// configuration can hold a browserMediaProbe handler without a retain cycle.
- (void)installMediaProbeScriptMessageHandlerOnConfiguration:(id)configuration {
    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    if (configuration == nil || ![configuration respondsToSelector:userContentControllerGetter]) {
        return;
    }
    id userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    SEL addHandlerSelector = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if (userContentController == nil || ![userContentController respondsToSelector:addHandlerSelector]) {
        return;
    }
    BrowserWeakScriptMessageForwarder *forwarder = [BrowserWeakScriptMessageForwarder new];
    forwarder.target = self;
    self.mediaProbeMessageForwarder = forwarder;
    ((void (*)(id, SEL, id, id))objc_msgSend)(userContentController, addHandlerSelector, forwarder, kBrowserMediaProbeMessageHandlerName);
}

// Script messages arrive on the main thread. Malformed payloads (non-dict,
// missing/unparseable pageURL) are ignored. frameInfo is the reporting
// WKScriptMessage.frameInfo (nil when unavailable); it is retained next to
// the probe so JS can later target this exact frame document.
- (void)storeMediaProbeMessageBody:(id)body frameInfo:(nullable id)frameInfo {
    if (![body isKindOfClass:[NSDictionary class]]) {
        return;
    }
    // Popup-blocker reports ({blocked:true, url}) carry no pageURL: append
    // them to the capped blockedPopups list instead of the per-frame store.
    if ([body[@"blocked"] boolValue]) {
        if (_blockedPopups == nil) {
            _blockedPopups = [NSMutableArray array];
        }
        NSString *blockedURL = [body[@"url"] isKindOfClass:[NSString class]] ? body[@"url"] : @"";
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"url"] = blockedURL;
        entry[@"timestamp"] = [NSDate date];
        if ([body[@"overlay"] boolValue]) {
            entry[@"overlay"] = @YES;
        }
        [_blockedPopups addObject:entry];
        while (_blockedPopups.count > 25) {
            [_blockedPopups removeObjectAtIndex:0];
        }
        NSLog(@"[PopupBlocker] blocked=%@ url=%@", [body[@"overlay"] boolValue] ? @"overlay" : @"window", blockedURL);
        return;
    }
    NSString *pageURLString = [body[@"pageURL"] isKindOfClass:[NSString class]] ? body[@"pageURL"] : nil;
    if (pageURLString.length == 0) {
        return;
    }
    NSURL *pageURL = [NSURL URLWithString:pageURLString];
    NSString *frameKey = pageURL.host.length > 0
        ? [pageURL.host stringByAppendingString:pageURL.path ?: @""]
        : pageURLString;

    if (_mediaProbeByFrame == nil) {
        _mediaProbeByFrame = [NSMutableDictionary dictionary];
    }
    NSMutableDictionary *entry = [body mutableCopy];
    entry[kBrowserMediaProbeTimestampKey] = [NSDate date];
    _mediaProbeByFrame[frameKey] = entry;
    if (frameInfo != nil) {
        if (_frameInfoByFrameKey == nil) {
            _frameInfoByFrameKey = [NSMutableDictionary dictionary];
        }
        _frameInfoByFrameKey[frameKey] = frameInfo;
        if (_frameInfoStoredTimeByFrameKey == nil) {
            _frameInfoStoredTimeByFrameKey = [NSMutableDictionary dictionary];
        }
        _frameInfoStoredTimeByFrameKey[frameKey] = [NSDate date];
    }
    static NSInteger probeStoreLogCount = 0;
    if (probeStoreLogCount < 5) {
        probeStoreLogCount++;
        NSLog(@"[NativeVideoPlayer] probe store frameKey=%@ frameInfo=%@ self=%p", frameKey, frameInfo ? NSStringFromClass([frameInfo class]) : @"NIL", self);
    }

    [self detectPlayingEmbedVideoInReport:body pageURL:pageURL frameKey:frameKey];
    [self detectForcedNativePresentationInReport:body];
}

// Streameast-family player iframes live on a different origin than the page
// (and their URLs contain a new-stream-embed path segment). When such a frame
// transitions a video from paused to playing, ask the host to take over with
// the native player — the in-page fullscreen paths are broken on tvOS.
// At most once per page load. In Native Video Mode the host presents the
// player automatically unless NativeAutoFullscreenDisabled is set; on the
// legacy (mode-off) path the host shows its confirmation prompt, suppressed
// by NativeAutoFullscreenPromptDisabled.
- (void)detectPlayingEmbedVideoInReport:(NSDictionary *)report pageURL:(NSURL *)pageURL frameKey:(NSString *)frameKey {
    if (_embedPlaybackPromptOffered) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL autoFullscreenEnabled = ![defaults boolForKey:@"NativeVideoModeDisabled"] &&
                                 ![defaults boolForKey:@"NativeAutoFullscreenDisabled"];
    if (!autoFullscreenEnabled && [defaults boolForKey:@"NativeAutoFullscreenPromptDisabled"]) {
        return;
    }
    if ([self.delegate respondsToSelector:@selector(webView:didDetectPlayingEmbedVideoReport:)] == NO) {
        return;
    }

    // Any video reported as playing (paused == false)?
    NSArray *videos = [report[@"videos"] isKindOfClass:[NSArray class]] ? report[@"videos"] : @[];
    BOOL anyPlaying = NO;
    for (id videoObject in videos) {
        if (![videoObject isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id pausedValue = ((NSDictionary *)videoObject)[@"paused"];
        if ([pausedValue isKindOfClass:[NSNumber class]] && [(NSNumber *)pausedValue boolValue] == NO) {
            anyPlaying = YES;
            break;
        }
    }

    if (_probePlayingByFrame == nil) {
        _probePlayingByFrame = [NSMutableDictionary dictionary];
    }
    NSNumber *previousPlaying = _probePlayingByFrame[frameKey];
    _probePlayingByFrame[frameKey] = @(anyPlaying);
    // Require a known previous state that was paused so the first report of an
    // already-playing embed (page-load resume) is not mistaken for the press.
    if (previousPlaying == nil || [previousPlaying boolValue] == YES || anyPlaying == NO) {
        return;
    }

    // Embed-like frame: the new-stream-embed marker, or a pageURL origin
    // different from the main frame (third-party player iframes).
    NSString *lowercasePath = pageURL.path.lowercaseString ?: @"";
    NSString *lowercaseHost = pageURL.host.lowercaseString ?: @"";
    BOOL embedLike = [lowercasePath containsString:@"new-stream-embed"] || [lowercaseHost containsString:@"new-stream-embed"];
    if (!embedLike) {
        NSString *mainFrameHost = self.currentURL.host.lowercaseString ?: @"";
        embedLike = mainFrameHost.length > 0 && ![lowercaseHost isEqualToString:mainFrameHost];
    }
    if (!embedLike) {
        return;
    }

    _embedPlaybackPromptOffered = YES;
    NSLog(@"[NativeVideoPlayer] embed video playing in frame=%@ — offering fullscreen", frameKey);
    [self.delegate webView:self didDetectPlayingEmbedVideoReport:report];
}

// ForceNativePresentOnPlay (default-NO launch flag): once per document, the
// first probe report whose frame has a playing video (paused == false) asks
// the host to present the native player automatically. Covers the
// ForcePlayOnLaunch headless play: its forced play() shows up here as the
// video turning playing, so no separate JS signal is needed.
- (void)detectForcedNativePresentationInReport:(NSDictionary *)report {
    if (_forceNativePresentFired) {
        return;
    }
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"ForceNativePresentOnPlay"]) {
        return;
    }
    if ([self.delegate respondsToSelector:@selector(webViewWantsForcedNativePresentation:)] == NO) {
        return;
    }
    NSArray *videos = [report[@"videos"] isKindOfClass:[NSArray class]] ? report[@"videos"] : @[];
    for (id videoObject in videos) {
        if (![videoObject isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id pausedValue = ((NSDictionary *)videoObject)[@"paused"];
        if ([pausedValue isKindOfClass:[NSNumber class]] && [(NSNumber *)pausedValue boolValue] == NO) {
            _forceNativePresentFired = YES;
            NSLog(@"[NativeVideoPlayer] force-native-present fired");
            [self.delegate webViewWantsForcedNativePresentation:self];
            return;
        }
    }
}

- (NSArray<NSDictionary *> *)freshMediaProbeReportsYoungerThan:(NSTimeInterval)age {
    if (_mediaProbeByFrame.count == 0) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
    [_mediaProbeByFrame enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, __unused BOOL *stop) {
        NSDate *timestamp = [entry[kBrowserMediaProbeTimestampKey] isKindOfClass:[NSDate class]] ? entry[kBrowserMediaProbeTimestampKey] : nil;
        NSTimeInterval ageOfEntry = timestamp != nil ? -[timestamp timeIntervalSinceNow] : DBL_MAX;
        if (ageOfEntry > 30.0) {
            [staleKeys addObject:key];
            return;
        }
        if (timestamp == nil || ageOfEntry > age) {
            return;
        }
        [entries addObject:[entry copy]];
    }];
    [_mediaProbeByFrame removeObjectsForKeys:staleKeys];

    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[kBrowserMediaProbeTimestampKey] compare:a[kBrowserMediaProbeTimestampKey]]; // newest first
    }];

    // The reports are returned WITH kBrowserMediaProbeTimestampKey retained:
    // the presentation side (BrowserVideoPlaybackCoordinator) logs the age of
    // a report that succeeds past the auto path's freshness window (the
    // manual-takeover-from-aged-probe line), which needs the receive stamp.
    NSMutableArray<NSDictionary *> *reports = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *entry in entries) {
        [reports addObject:[entry copy]];
    }
    return reports;
}

// Evaluate the script directly in every frame document that reported a media
// probe, including the cross-origin embed iframes top-document JS cannot
// reach, through the public WKWebView (iOS/tvOS 14+)
// -evaluateJavaScript:inFrame:inContentWorld:completionHandler: API, passing
// the page content world. Entries whose frameInfo was STORED more than 600s
// ago are pruned before dispatch: the resume runs well after dismissal while
// the embed's probe script is silent (the native player owns playback), and a
// WKFrameInfo remains valid to target through the document reload the embed
// performs, so presentation-candidate probe staleness must not gate this.
// Evaluations on since-dead frames no-op harmlessly; the completion only logs
// the per-frame error (if any) so in-frame SyntaxErrors are not silent.
// Returns the number of frames targeted. Main thread only.
- (NSUInteger)evaluateJavaScriptOnRecentProbeFrames:(NSString *)javaScript {
    NSLog(@"[NativeVideoPlayer] frame-eval entry js=%lu frames=%lu runtime=%@ webviewSelf=%p", (unsigned long)javaScript.length, (unsigned long)_frameInfoByFrameKey.count, self.runtimeWebView == nil ? @"NIL" : @"set", self);
    if (javaScript.length == 0 || self.runtimeWebView == nil || _frameInfoByFrameKey.count == 0) {
        return 0;
    }
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:inFrame:inContentWorld:completionHandler:");
    // WKContentWorld is not directly referenceable under this target's
    // availability guards, so resolve +[WKContentWorld pageWorld] at runtime.
    id pageWorld = nil;
    Class contentWorldClass = NSClassFromString(@"WKContentWorld");
    SEL pageWorldSelector = NSSelectorFromString(@"pageWorld");
    if (contentWorldClass != nil && [contentWorldClass respondsToSelector:pageWorldSelector]) {
        pageWorld = ((id (*)(id, SEL))objc_msgSend)((id)contentWorldClass, pageWorldSelector);
    }
    if (![self.runtimeWebView respondsToSelector:selector] || pageWorld == nil) {
        static BOOL loggedMissingFrameEvalSelector = NO;
        if (!loggedMissingFrameEvalSelector) {
            loggedMissingFrameEvalSelector = YES;
            NSLog(@"[NativeVideoPlayer] frame-eval selector unavailable");
        }
        return 0;
    }
    NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
    [_frameInfoByFrameKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, __unused id frameInfo, __unused BOOL *stop) {
        NSDate *stored = [_frameInfoStoredTimeByFrameKey[key] isKindOfClass:[NSDate class]] ? _frameInfoStoredTimeByFrameKey[key] : nil;
        NSTimeInterval ageOfEntry = stored != nil ? -[stored timeIntervalSinceNow] : DBL_MAX;
        if (ageOfEntry > 600.0) {
            [staleKeys addObject:key];
        }
    }];
    [_frameInfoByFrameKey removeObjectsForKeys:staleKeys];
    [_frameInfoStoredTimeByFrameKey removeObjectsForKeys:staleKeys];

    NSUInteger dispatchedFrames = 0;
    for (id frameInfo in [_frameInfoByFrameKey allValues]) {
        ((void (*)(id, SEL, id, id, id, void (^)(id, id)))objc_msgSend)(self.runtimeWebView, selector, javaScript, frameInfo, pageWorld, ^(id result, id error) {
            if (error != nil) {
                NSLog(@"[NativeVideoPlayer] frame-eval error=%@", error);
            }
        });
        dispatchedFrames++;
    }
    return dispatchedFrames;
}

// WebVTT subtitle extraction, evaluated on-demand at native takeover inside
// one probe frame's document (page content world). Reads the largest <video>'s
// loaded subtitle/caption TextTrack cues; when none are loaded, falls back to
// listing the page's <track kind="subtitles|captions"> srcs so the app can
// fetch the VTT itself. Returns a JSON string, never throws from JS.
static NSString *const kBrowserSubtitleTrackExtractionScript =
    @"(() => {"
    "  try {"
    "    var vids = Array.from(document.querySelectorAll('video'));"
    "    if (!vids.length) return '[]';"
    "    var v = vids.sort((a,b)=>(b.clientWidth*b.clientHeight)-(a.clientWidth*a.clientHeight))[0];"
    "    var out = [];"
    "    var seen = {};"
    "    var tracks = [];"
    "    try { tracks = Array.from(v.textTracks || []); } catch(e){}"
    "    tracks.forEach(function(t){"
    "      try {"
    "        if (!t) return;"
    "        var k = String(t.kind||'');"
    "        if (k !== 'subtitles' && k !== 'captions') return;"
    "        var cues = [];"
    "        var cl = t.cues || null;"
    "        var n = cl ? Math.min(cl.length, 3000) : 0;"
    "        for (var i=0;i<n;i++){"
    "          var c = cl[i];"
    "          if (!c) continue;"
    "          var txt = String(c.text||'').replace(/<[^>]*>/g,'').replace(/\\{[^}]*\\}/g,'').trim();"
    "          if (!txt) continue;"
    "          cues.push({ s: Math.round(c.startTime*1000), e: Math.round(c.endTime*1000), t: txt });"
    "        }"
    "        var key = (t.label||'')+'|'+k+'|'+cues.length;"
    "        if (cues.length && !seen[key]) { seen[key]=1; out.push({ label: String(t.label||t.language||'subtitles'), mode: String(t.mode||''), cues: cues }); }"
    "      } catch(e){}"
    "    });"
    "    if (!out.length) {"
    "      /* no loaded cues: expose <track> srcs so the app can fetch the VTT itself */"
    "      var srcs = [];"
    "      try {"
    "        Array.from(document.querySelectorAll('track')).forEach(function(tr){"
    "          var k = String(tr.kind||''); if (k!=='subtitles'&&k!=='captions') return;"
    "          if (tr.src) srcs.push({ label: String(tr.label||tr.srclang||'subtitles'), src: String(tr.src) });"
    "        });"
    "      } catch(e){}"
    "      out = srcs;"
    "    }"
    "    if (!out.length) {"
    "      return JSON.stringify([{diag:'vids='+vids.length+',tt='+(v?v.textTracks.length:-1)+',trackEls='+document.querySelectorAll('track').length+',title='+document.title.slice(0,20)}]);"
    "    }"
    "    return JSON.stringify(out);"
    "  } catch(e) { return '[]'; }"
    "})()";

// Evaluate the extraction script directly in the stored WKFrameInfo document of
// one probe frame (the same runtime-targeted
// -evaluateJavaScript:inFrame:inContentWorld: path as
// -evaluateJavaScriptOnRecentProbeFrames:, page content world). On-demand only:
// never runs on the probe cadence. A 1.5s watchdog guarantees the completion
// fires exactly once on the main thread (empty array on frame loss, missing
// API, timeout, or parse failure) so the native takeover is never delayed
// beyond it.
- (void)extractSubtitleTracksForFrameKey:(NSString *)frameKey
                              completion:(void (^)(NSArray<NSDictionary *> *subtitleTracks))completion {
    __block BOOL delivered = NO;
    void (^deliver)(NSArray<NSDictionary *> *) = ^(NSArray<NSDictionary *> *subtitleTracks) {
        if (delivered) {
            return; // watchdog vs JS completion: exactly once
        }
        delivered = YES;
        NSArray<NSDictionary *> *tracks = [subtitleTracks isKindOfClass:[NSArray class]] ? subtitleTracks : @[];
        NSUInteger cueCount = 0;
        for (id track in tracks) {
            if ([track isKindOfClass:[NSDictionary class]] && [((NSDictionary *)track)[@"cues"] isKindOfClass:[NSArray class]]) {
                cueCount += [(NSArray *)((NSDictionary *)track)[@"cues"] count];
            }
        }
        NSLog(@"[Subs] frame=%@ tracks=%lu cues=%lu", frameKey ?: @"", (unsigned long)tracks.count, (unsigned long)cueCount);
        if (completion != nil) {
            completion(tracks);
        }
    };
    id frameInfo = frameKey.length > 0 ? _frameInfoByFrameKey[frameKey] : nil;
    if (frameInfo == nil || self.runtimeWebView == nil) {
        deliver(@[]);
        return;
    }
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:inFrame:inContentWorld:completionHandler:");
    id pageWorld = nil;
    Class contentWorldClass = NSClassFromString(@"WKContentWorld");
    SEL pageWorldSelector = NSSelectorFromString(@"pageWorld");
    if (contentWorldClass != nil && [contentWorldClass respondsToSelector:pageWorldSelector]) {
        pageWorld = ((id (*)(id, SEL))objc_msgSend)((id)contentWorldClass, pageWorldSelector);
    }
    if (![self.runtimeWebView respondsToSelector:selector] || pageWorld == nil) {
        deliver(@[]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        deliver(@[]);
    });
    ((void (*)(id, SEL, id, id, id, void (^)(id, id)))objc_msgSend)(self.runtimeWebView, selector,
                                                                    kBrowserSubtitleTrackExtractionScript, frameInfo, pageWorld,
                                                                    ^(id result, id error) {
        // WebKit delivers this on its own queue: parse off-main, then hop to
        // main so deliver()'s once-only flag has a single writer.
        NSLog(@"[Subs] raw=%@", [result isKindOfClass:NSString.class] ? [(NSString *)result substringToIndex:MIN((NSUInteger)140, [(NSString *)result length])] : NSStringFromClass([result class]));
        NSLog(@"[Subs] err=%@", error ?: @"(none)");
        NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
        if ([result isKindOfClass:[NSString class]]) {
            NSData *jsonData = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = jsonData != nil ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL] : nil;
            if ([parsed isKindOfClass:[NSArray class]]) {
                for (id track in (NSArray *)parsed) {
                    if (![track isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }
                    BOOL hasCues = [((NSDictionary *)track)[@"cues"] isKindOfClass:[NSArray class]];
                    BOOL hasSrc = [((NSDictionary *)track)[@"src"] isKindOfClass:[NSString class]];
                    if (hasCues || hasSrc) {
                        [tracks addObject:track];
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            deliver(tracks);
        });
    });
}

- (void)resetMediaProbeReports {
    [_mediaProbeByFrame removeAllObjects];
    [_frameInfoByFrameKey removeAllObjects];
    [_frameInfoStoredTimeByFrameKey removeAllObjects];
    [_probePlayingByFrame removeAllObjects];
    _embedPlaybackPromptOffered = NO;
    _forceNativePresentFired = NO;
}

- (NSArray<NSDictionary *> *)blockedPopups {
    return [_blockedPopups copy] ?: @[];
}

- (void)userContentController:(id)userContentController didReceiveScriptMessage:(id)message {
    (void)userContentController;
    SEL nameSelector = NSSelectorFromString(@"name");
    SEL bodySelector = NSSelectorFromString(@"body");
    if (![message respondsToSelector:nameSelector] || ![message respondsToSelector:bodySelector]) {
        return;
    }
    NSString *name = ((id (*)(id, SEL))objc_msgSend)(message, nameSelector);
    if ([name isEqualToString:kBrowserMediaProbeMessageHandlerName]) {
        SEL frameInfoSelector = NSSelectorFromString(@"frameInfo");
        id frameInfo = [message respondsToSelector:frameInfoSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(message, frameInfoSelector)
            : nil;
        [self storeMediaProbeMessageBody:((id (*)(id, SEL))objc_msgSend)(message, bodySelector) frameInfo:frameInfo];
        return;
    }
    if (![name isEqualToString:kBrowserFullscreenMessageHandlerName]) {
        return;
    }
    id body = ((id (*)(id, SEL))objc_msgSend)(message, bodySelector);
    if (![body isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSLog(@"[NativeVideoPlayer] page fullscreen message received: %@", body);
    if ([self.delegate respondsToSelector:@selector(webView:didRequestFullscreenWithVideoInfo:)]) {
        [self.delegate webView:self didRequestFullscreenWithVideoInfo:body];
    } else {
        // No one to handle it: expand in the page so the button still works.
        [self evaluateJavaScriptStringAsync:@"window.__browserApplyCssFullscreen && window.__browserApplyCssFullscreen();"];
    }
}

#pragma mark - WKUIDelegate JavaScript panels

- (NSString *)javaScriptPanelTitle {
    NSString *host = self.request.URL.host;
    return host.length > 0 ? host : @"This page";
}

- (void)webView:(id)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
initiatedByFrame:(id)frame
completionHandler:(void (^)(void))completionHandler {
    (void)webView;
    (void)frame;
    if (![self.delegate respondsToSelector:@selector(webView:requestsPresentingAlertController:)]) {
        if (completionHandler != nil) {
            completionHandler();
        }
        return;
    }
    BrowserWebViewCompletionGuard *completionGuard = [BrowserWebViewCompletionGuard guardWithFallback:^{
        completionHandler();
    }];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[self javaScriptPanelTitle]
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [completionGuard fulfill];
        completionHandler();
    }]];
    [self.delegate webView:self requestsPresentingAlertController:alertController];
}

- (void)webView:(id)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
initiatedByFrame:(id)frame
completionHandler:(void (^)(BOOL))completionHandler {
    (void)webView;
    (void)frame;
    if (![self.delegate respondsToSelector:@selector(webView:requestsPresentingAlertController:)]) {
        if (completionHandler != nil) {
            completionHandler(NO);
        }
        return;
    }
    BrowserWebViewCompletionGuard *completionGuard = [BrowserWebViewCompletionGuard guardWithFallback:^{
        completionHandler(NO);
    }];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[self javaScriptPanelTitle]
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(__unused UIAlertAction *action) {
        [completionGuard fulfill];
        completionHandler(NO);
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [completionGuard fulfill];
        completionHandler(YES);
    }]];
    [self.delegate webView:self requestsPresentingAlertController:alertController];
}

- (void)webView:(id)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText
initiatedByFrame:(id)frame
completionHandler:(void (^)(NSString *))completionHandler {
    (void)webView;
    (void)frame;
    if (![self.delegate respondsToSelector:@selector(webView:requestsPresentingAlertController:)]) {
        if (completionHandler != nil) {
            completionHandler(nil);
        }
        return;
    }
    BrowserWebViewCompletionGuard *completionGuard = [BrowserWebViewCompletionGuard guardWithFallback:^{
        completionHandler(nil);
    }];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[self javaScriptPanelTitle]
                                                                             message:prompt
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = defaultText;
    }];
    __weak UIAlertController *weakAlertController = alertController;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(__unused UIAlertAction *action) {
        [completionGuard fulfill];
        completionHandler(nil);
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [completionGuard fulfill];
        completionHandler(weakAlertController.textFields.firstObject.text ?: @"");
    }]];
    [self.delegate webView:self requestsPresentingAlertController:alertController];
}

- (id)webView:(id)webView
createWebViewWithConfiguration:(id)configuration
forNavigationAction:(id)navigationAction
windowFeatures:(id)windowFeatures {
    (void)webView;
    (void)configuration;
    (void)windowFeatures;

    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];

    // Frame-initiated popups (streameast-style click-hijack: an iframe
    // overlays a transparent layer on the play button and turns clicks into
    // window.open/target=_blank from itself) are denied silently: no new
    // webview, no alert. Only an explicit non-main-frame source counts; a
    // missing or unreadable sourceFrame keeps the legacy main-frame flow.
    SEL sourceFrameSelector = NSSelectorFromString(@"sourceFrame");
    if ([navigationAction respondsToSelector:sourceFrameSelector]) {
        id sourceFrame = ((id (*)(id, SEL))objc_msgSend)(navigationAction, sourceFrameSelector);
        SEL isMainFrameSelector = NSSelectorFromString(@"isMainFrame");
        if (sourceFrame != nil && [sourceFrame respondsToSelector:isMainFrameSelector] &&
            !((BOOL (*)(id, SEL))objc_msgSend)(sourceFrame, isMainFrameSelector)) {
            NSString *sourceHost = @"";
            SEL frameRequestSelector = NSSelectorFromString(@"request");
            if ([sourceFrame respondsToSelector:frameRequestSelector]) {
                NSURLRequest *frameRequest = ((id (*)(id, SEL))objc_msgSend)(sourceFrame, frameRequestSelector);
                sourceHost = frameRequest.URL.host ?: @"";
            }
            NSLog(@"popup blocked (frame-initiated) url=%@ from=%@",
                  request.URL.absoluteString ?: @"",
                  sourceHost);
            return nil;
        }
    }

    // Confirmation gate: the host shows the prompt and opens the tab itself
    // from the alert (async), so we never honor the request here. One alert
    // per navigationAction; requests that are nil can't be confirmed.
    if (request != nil &&
        [self.delegate respondsToSelector:@selector(webView:wantsConfirmationForNewTabRequest:navigationType:)] &&
        [self.delegate webView:self wantsConfirmationForNewTabRequest:request navigationType:navigationType]) {
        return nil;
    }

    BOOL delegateHandlesNewTabRequests = [self.delegate respondsToSelector:@selector(webView:shouldCreateNewTabWithRequest:navigationType:)];
    BOOL handledInTab = NO;
    if (delegateHandlesNewTabRequests) {
        handledInTab = [self.delegate webView:self shouldCreateNewTabWithRequest:request navigationType:navigationType];
    }

    if (!delegateHandlesNewTabRequests && !handledInTab && request != nil) {
        BOOL shouldAllow = YES;
        if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
            shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
        }
        if (shouldAllow) {
            [self loadRequest:request];
        }
    }

    return nil;
}

+ (void)setInteractivePumpTimeoutActive:(BOOL)active {
    // Main thread only — same contract as every pump caller.
    sBrowserInteractivePumpTimeoutActive = active;
}

+ (BOOL)interactivePumpTimeoutActive {
    return sBrowserInteractivePumpTimeoutActive;
}

+ (id)defaultWebsiteDataStore {
    BrowserEnsureWebKitRuntimeLoaded();
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"defaultDataStore");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (id)defaultCookieStore {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"httpCookieStore");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(dataStore, selector);
}

+ (NSArray<NSHTTPCookie *> *)allCookies {
    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"getAllCookies:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        return NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies ?: @[];
    }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    __block NSArray<NSHTTPCookie *> *cookies = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, selector, ^(NSArray<NSHTTPCookie *> *fetchedCookies) {
        cookies = fetchedCookies;
        finished = YES;
        CFRunLoopStop(runLoop);
    });
    // Cookie I/O is not on the interactive hot path: full window.
    BOOL pumped = BrowserPumpRunLoopUntil(&finished, runLoop, 2.0);
    if (!pumped && !finished) {
        return NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies ?: @[];
    }
    return cookies ?: @[];
}

+ (NSData *)cookieDataRepresentation {
    NSArray<NSHTTPCookie *> *cookies = [self allCookies];
    NSError *error = nil;
    NSData *cookieData = [NSKeyedArchiver archivedDataWithRootObject:cookies requiringSecureCoding:NO error:&error];
    return error == nil ? cookieData : nil;
}

+ (void)restoreCookiesFromData:(NSData *)cookieData {
    if (cookieData.length == 0) {
        return;
    }

    NSError *error = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [NSHTTPCookie class], nil];
    NSArray<NSHTTPCookie *> *cookies = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses fromData:cookieData error:&error];
    if (![cookies isKindOfClass:[NSArray class]]) {
        return;
    }

    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"setCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        for (NSHTTPCookie *cookie in cookies) {
            [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
        }
        return;
    }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    __block NSInteger remainingCount = cookies.count;
    __block BOOL finished = cookies.count == 0;
    for (NSHTTPCookie *cookie in cookies) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, selector, cookie, ^{
            remainingCount -= 1;
            finished = remainingCount == 0;
            if (finished) {
                CFRunLoopStop(runLoop);
            }
        });
    }
    // Nested rejection behaves like the timeout path: proceed, handlers land
    // inside the outer pump.
    (void)BrowserPumpRunLoopUntil(&finished, runLoop, 2.0);
}

+ (NSSet<NSString *> *)allWebsiteDataTypes {
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"allWebsiteDataTypes");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return [NSSet set];
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (void)removeWebsiteDataTypes:(NSSet<NSString *> *)websiteDataTypes completion:(void (^)(void))completion {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        if (completion != nil) {
            completion();
        }
        return;
    }

    NSDate *beginningOfTime = [NSDate dateWithTimeIntervalSince1970:0];
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(dataStore, selector, websiteDataTypes, beginningOfTime, ^{
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

+ (void)clearCachedDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSMutableSet<NSString *> *websiteDataTypes = [[self allWebsiteDataTypes] mutableCopy];
    for (NSString *dataType in websiteDataTypes.allObjects) {
        if ([dataType.lowercaseString containsString:@"cookie"]) {
            [websiteDataTypes removeObject:dataType];
        }
    }

    [self removeWebsiteDataTypes:websiteDataTypes completion:completion];
}

+ (void)clearCookiesWithCompletion:(void (^)(void))completion {
    id cookieStore = [self defaultCookieStore];
    SEL getAllCookiesSelector = NSSelectorFromString(@"getAllCookies:");
    SEL deleteCookieSelector = NSSelectorFromString(@"deleteCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:getAllCookiesSelector] || ![cookieStore respondsToSelector:deleteCookieSelector]) {
        NSHTTPCookieStorage *storage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
        for (NSHTTPCookie *cookie in storage.cookies) {
            [storage deleteCookie:cookie];
        }
        if (completion != nil) {
            completion();
        }
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, getAllCookiesSelector, ^(NSArray<NSHTTPCookie *> *cookies) {
        if (cookies.count == 0) {
            if (completion != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
            return;
        }

        __block NSInteger remainingCount = cookies.count;
        for (NSHTTPCookie *cookie in cookies) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, deleteCookieSelector, cookie, ^{
                remainingCount -= 1;
                if (remainingCount == 0 && completion != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion();
                    });
                }
            });
        }
    });
}

+ (void)resetWebsiteDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    [self removeWebsiteDataTypes:[self allWebsiteDataTypes] completion:completion];
}

@end
