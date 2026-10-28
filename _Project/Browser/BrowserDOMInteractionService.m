#import "BrowserDOMInteractionService.h"

#import "BrowserWebView.h"

static NSString * const kInteractiveElementSelector = @"a, button, input, textarea, select, option, label, summary, [role='button'], [onclick], [tabindex]";
static NSString * const kEditableElementSelector = @"input, textarea, select, [contenteditable='true'], [contenteditable=''], [contenteditable]";

@implementation BrowserDOMInteractionService

- (NSString *)resolvedElementScriptForPoint:(CGPoint)point body:(NSString *)body {
    NSInteger pointX = (NSInteger)llround(point.x);
    NSInteger pointY = (NSInteger)llround(point.y);
    return [NSString stringWithFormat:
                        @"(function(){"
                        "var x=%ld;"
                        "var y=%ld;"
                        "var interactiveSelector=\"%@\";"
                        "var editableSelector=\"%@\";"
                        "function resolveElement(root, px, py) {"
                            "if (!root || typeof root.elementFromPoint !== 'function') { return null; }"
                            "var element = root.elementFromPoint(px, py);"
                            "while (element) {"
                                "if (element.shadowRoot && typeof element.shadowRoot.elementFromPoint === 'function') {"
                                    "var shadowRect = element.getBoundingClientRect();"
                                    "var shadowElement = resolveElement(element.shadowRoot, px - shadowRect.left, py - shadowRect.top);"
                                    "if (shadowElement && shadowElement !== element) {"
                                        "element = shadowElement;"
                                        "continue;"
                                    "}"
                                "}"
                                "if (element.tagName === 'IFRAME') {"
                                    "try {"
                                        "var frameRect = element.getBoundingClientRect();"
                                        "var frameDocument = element.contentDocument;"
                                        "var frameElement = resolveElement(frameDocument, px - frameRect.left, py - frameRect.top);"
                                        "if (frameElement) {"
                                            "element = frameElement;"
                                            "continue;"
                                        "}"
                                    "} catch (error) {}"
                                "}"
                                "return element;"
                            "}"
                            "return null;"
                        "}"
                        "function closestMatch(element, selector) {"
                            "while (element) {"
                                "if (element.matches && element.matches(selector)) { return element; }"
                                "element = element.parentElement;"
                            "}"
                            "return null;"
                        "}"
                        "var resolvedElement = resolveElement(document, x, y);"
                        "var interactiveElement = closestMatch(resolvedElement, interactiveSelector);"
                        "var editableElement = closestMatch(resolvedElement, editableSelector);"
                        "%@"
                        "})()",
                        (long)pointX,
                        (long)pointY,
                        kInteractiveElementSelector,
                        kEditableElementSelector,
                        body];
}

- (NSString *)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body {
    if (webView == nil) {
        return @"";
    }
    NSString *script = [self resolvedElementScriptForPoint:point body:body];
    return [webView stringByEvaluatingJavaScriptFromString:script] ?: @"";
}

// Non-blocking variant: completion runs on the main queue with the script result (or @"").
- (void)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                         webView:(BrowserWebView *)webView
                                            body:(NSString *)body
                                      completion:(void (^)(NSString *result))completion {
    if (webView == nil) {
        completion(@"");
        return;
    }
    NSString *script = [self resolvedElementScriptForPoint:point body:body];
    [webView evaluateJavaScriptString:script completion:^(NSString *result) {
        completion(result ?: @"");
    }];
}

// Fire-and-forget: runs the resolved-element script without blocking. For pure
// side effects (e.g. dispatching synthetic click events) where the result is unused.
- (void)dispatchResolvedElementJavaScriptAtPoint:(CGPoint)point
                                          webView:(BrowserWebView *)webView
                                             body:(NSString *)body {
    if (webView == nil) {
        return;
    }
    [webView evaluateJavaScriptStringAsync:[self resolvedElementScriptForPoint:point body:body]];
}

- (NSString *)evaluateEditableElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body {
    return [self evaluateResolvedElementJavaScriptAtPoint:point webView:webView body:[self editableElementScriptBody:body]];
}

// Fire-and-forget variant for writes whose result is unused (never blocks the caller).
- (void)dispatchEditableElementJavaScriptAtPoint:(CGPoint)point
                                         webView:(BrowserWebView *)webView
                                            body:(NSString *)body {
    [self dispatchResolvedElementJavaScriptAtPoint:point webView:webView body:[self editableElementScriptBody:body]];
}

// Prepends browserEditableTarget() (the field being edited) to body.
- (NSString *)editableElementScriptBody:(NSString *)body {
    return [NSString stringWithFormat:
                             @"function browserIsEditableCandidate(element) {"
                                 "if (!element) { return false; }"
                                 "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                 "if (element.matches && element.matches(editableSelector)) { return true; }"
                                 "if (tagName === 'textarea' || tagName === 'select') { return true; }"
                                 "if (element.isContentEditable) { return true; }"
                                 "return false;"
                             "}"
                             "function browserEditableTarget() {"
                                 "var stored = window.__browserLastEditableElement;"
                                 "if (stored && stored.isConnected && browserIsEditableCandidate(stored)) { return stored; }"
                                 "var active = document.activeElement;"
                                 "if (active && browserIsEditableCandidate(active)) {"
                                     "window.__browserLastEditableElement = active;"
                                     "return active;"
                                 "}"
                                 "var candidate = editableElement || interactiveElement || resolvedElement;"
                                 "if (candidate && browserIsEditableCandidate(candidate)) {"
                                     "window.__browserLastEditableElement = candidate;"
                                     "return candidate;"
                                 "}"
                                 "if (candidate && candidate.closest) {"
                                     "var fallback = candidate.closest(editableSelector) || candidate.closest('textarea, select');"
                                     "if (fallback && browserIsEditableCandidate(fallback)) {"
                                         "window.__browserLastEditableElement = fallback;"
                                         "return fallback;"
                                     "}"
                                 "}"
                                 "return null;"
                             "}"
                             "%@",
                             body];
}

- (NSString *)hoverStateJavaScriptBody {
    return @"var candidate = interactiveElement || resolvedElement;"
            "while (candidate) {"
                "if (candidate.matches && candidate.matches(interactiveSelector)) { return 'true'; }"
                "candidate = candidate.parentElement;"
            "}"
            "return 'false';";
}

- (void)evaluateHoverStateAtCursorOrigin:(CGPoint)cursorOrigin
                                  inView:(UIView *)containerView
                                 webView:(BrowserWebView *)webView
                              completion:(void (^)(NSString *))completion {
    if (webView == nil) {
        completion(@"false");
        return;
    }

    __weak BrowserWebView *weakWebView = webView;
    [self DOMPointForCursorOrigin:cursorOrigin inView:containerView webView:webView completion:^(CGPoint domPoint) {
        BrowserWebView *strongWebView = weakWebView;
        if (strongWebView == nil) {
            completion(@"");
            return;
        }
        [self evaluateResolvedElementJavaScriptAtPoint:domPoint
                                               webView:strongWebView
                                                  body:[self hoverStateJavaScriptBody]
                                            completion:completion];
    }];
}

// Converts a cursor origin to page (DOM) coordinates, scaling by the page's innerWidth.
- (void)DOMPointForCursorOrigin:(CGPoint)cursorOrigin
                         inView:(UIView *)containerView
                        webView:(BrowserWebView *)webView
                     completion:(void (^)(CGPoint point))completion {
    CGPoint point = [containerView convertPoint:cursorOrigin toView:webView];
    if (webView == nil || point.y < 0.0) {
        completion(point);
        return;
    }

    CGFloat webViewWidth = CGRectGetWidth([webView frame]);
    [webView evaluateJavaScriptString:@"window.innerWidth" completion:^(NSString *widthResult) {
        CGPoint domPoint = point;
        NSInteger displayWidth = [widthResult integerValue];
        CGFloat scale = displayWidth > 0 ? webViewWidth / (CGFloat)displayWidth : 0.0;
        if (scale > 0.0) {
            domPoint.x /= scale;
            domPoint.y /= scale;
        }
        completion(domPoint);
    }];
}

- (NSString *)javaScriptEscapedString:(NSString *)string {
    NSString *escapedString = string ?: @"";
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    return escapedString;
}

- (void)videoInfoAtDOMPoint:(CGPoint)point
                    webView:(BrowserWebView *)webView
                 completion:(void (^)(NSDictionary *videoInfo))completion {
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                            webView:webView
                                               body:@"function browserAbsoluteURL(url) {"
                                                    "if (!url) { return ''; }"
                                                    "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                    "}"
                                                    "function browserVideoContainsPoint(video) {"
                                                        "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                        "var rect = video.getBoundingClientRect();"
                                                        "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                    "}"
                                                    "function browserResolveVideoElement() {"
                                                        "var candidate = resolvedElement;"
                                                        "while (candidate) {"
                                                            "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                            "candidate = candidate.parentElement;"
                                                        "}"
                                                        "var videos = document.querySelectorAll('video');"
                                                        "for (var i = 0; i < videos.length; i++) {"
                                                            "if (browserVideoContainsPoint(videos[i])) { return videos[i]; }"
                                                        "}"
                                                        "var bestVideo = null;"
                                                        "var bestScore = null;"
                                                        "for (var j = 0; j < videos.length; j++) {"
                                                            "var video = videos[j];"
                                                            "if (!video || typeof video.getBoundingClientRect !== 'function') { continue; }"
                                                            "var rect = video.getBoundingClientRect();"
                                                            "var visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));"
                                                            "var visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));"
                                                            "if (visibleWidth * visibleHeight <= 0) { continue; }"
                                                            // Several players on one page (e.g. three live streams): playing beats paused,
                                                            // then the one nearest the point (a control bar just below its own video).
                                                            "var dx = Math.max(rect.left - x, 0, x - rect.right);"
                                                            "var dy = Math.max(rect.top - y, 0, y - rect.bottom);"
                                                            "var playing = !video.paused && !video.ended && video.readyState >= 2;"
                                                            "var score = (playing ? 0 : 1e9) + Math.sqrt(dx * dx + dy * dy);"
                                                            "if (bestScore === null || score < bestScore) {"
                                                                "bestScore = score;"
                                                                "bestVideo = video;"
                                                            "}"
                                                        "}"
                                                        "return bestVideo;"
                                                    "}"
                                                    "function browserResolvePrimarySource(video) {"
                                                        "if (!video) { return ''; }"
                                                        "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                        "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                        "var sources = video.querySelectorAll('source');"
                                                        "for (var i = 0; i < sources.length; i++) {"
                                                            "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                            "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                        "}"
                                                        "return '';"
                                                    "}"
                                                    "function browserResolveSourceList(video) {"
                                                        "var values = [];"
                                                        "if (!video) { return values; }"
                                                        "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                        "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                        "var sources = video.querySelectorAll('source');"
                                                        "for (var i = 0; i < sources.length; i++) {"
                                                            "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                            "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                            "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                        "}"
                                                        "return values;"
                                                    "}"
                                                    "var video = browserResolveVideoElement();"
                                                    "if (!video) { return ''; }"
                                                    "return JSON.stringify({"
                                                        "src: browserResolvePrimarySource(video),"
                                                        "sources: browserResolveSourceList(video),"
                                                        "poster: browserAbsoluteURL(video.poster || ''),"
                                                        "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                        "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                        "paused: !!video.paused"
                                                    "});"
                                      completion:^(NSString *result) {
        completion([self JSONObjectFromJavaScriptString:result]);
    }];
}

- (NSDictionary *)linkInfoAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserAbsoluteURL(url) {"
                                                                       "if (!url) { return ''; }"
                                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                                       "}"
                                                                       "var element = interactiveElement || resolvedElement;"
                                                                       "if (!element) { return ''; }"
                                                                       "var link = null;"
                                                                       "if (element.closest) {"
                                                                           "link = element.closest('a[href]');"
                                                                       "}"
                                                                       "if (!link && element.tagName && element.tagName.toLowerCase() === 'a') {"
                                                                           "link = element;"
                                                                       "}"
                                                                       "if (!link) { return ''; }"
                                                                       "var href = link.href || (link.getAttribute ? (link.getAttribute('href') || '') : '');"
                                                                       "if (!href) { return ''; }"
                                                                       "var target = link.getAttribute ? (link.getAttribute('target') || '') : '';"
                                                                       "return JSON.stringify({"
                                                                           "href: browserAbsoluteURL(href),"
                                                                           "target: String(target || '').toLowerCase()"
                                                                       "});"];
    return [self JSONObjectFromJavaScriptString:result];
}

- (void)directVideoInfoAtDOMPoint:(CGPoint)point
                          webView:(BrowserWebView *)webView
                       completion:(void (^)(NSDictionary *videoInfo))completion {
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                            webView:webView
                                               body:@"function browserAbsoluteURL(url) {"
                                                    "if (!url) { return ''; }"
                                                    "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                    "}"
                                                    "function browserVideoContainsPoint(video) {"
                                                        "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                        "var rect = video.getBoundingClientRect();"
                                                        "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                    "}"
                                                    "function browserResolveDirectVideoElement() {"
                                                        "var candidate = resolvedElement;"
                                                        "while (candidate) {"
                                                            "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                            "candidate = candidate.parentElement;"
                                                        "}"
                                                        "var videos = document.querySelectorAll('video');"
                                                        "for (var i = 0; i < videos.length; i++) {"
                                                            "if (browserVideoContainsPoint(videos[i])) { return videos[i]; }"
                                                        "}"
                                                        "return null;"
                                                    "}"
                                                    "function browserResolvePrimarySource(video) {"
                                                        "if (!video) { return ''; }"
                                                        "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                        "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                        "var sources = video.querySelectorAll('source');"
                                                        "for (var i = 0; i < sources.length; i++) {"
                                                            "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                            "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                        "}"
                                                        "return '';"
                                                    "}"
                                                    "function browserResolveSourceList(video) {"
                                                        "var values = [];"
                                                        "if (!video) { return values; }"
                                                        "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                        "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                        "var sources = video.querySelectorAll('source');"
                                                        "for (var i = 0; i < sources.length; i++) {"
                                                            "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                            "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                            "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                        "}"
                                                        "return values;"
                                                    "}"
                                                    "var video = browserResolveDirectVideoElement();"
                                                    "if (!video) { return ''; }"
                                                    "return JSON.stringify({"
                                                        "src: browserResolvePrimarySource(video),"
                                                        "sources: browserResolveSourceList(video),"
                                                        "poster: browserAbsoluteURL(video.poster || ''),"
                                                        "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                        "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                        "paused: !!video.paused"
                                                    "});"
                                      completion:^(NSString *result) {
        completion([self JSONObjectFromJavaScriptString:result]);
    }];
}

- (void)isVideoActivationTargetAtDOMPoint:(CGPoint)point
                                   webView:(BrowserWebView *)webView
                                completion:(void (^)(BOOL isTarget))completion {
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                            webView:webView
                                               body:@"function browserVideoContainsPoint(video) {"
                                                    "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                    "var rect = video.getBoundingClientRect();"
                                                    "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                    "}"
                                                    "function browserLooksLikeDismissControl(element) {"
                                                        "if (!element) { return false; }"
                                                        "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                        "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                        "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                            "(typeof element.onclick === 'function') ||"
                                                            "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                        "if (!isButtonLike) { return false; }"
                                                        "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                        "var shortText = text.length <= 3 ? text : '';"
                                                        "var label = ["
                                                            "element.id || '',"
                                                            "element.className || '',"
                                                            "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                            "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                            "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                            "shortText"
                                                        "].join(' ').toLowerCase();"
                                                        "if (!label) { return false; }"
                                                        "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                            "label.indexOf('modal-close') !== -1 ||"
                                                            "label.indexOf('icon-close') !== -1) {"
                                                            "return true;"
                                                        "}"
                                                        "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                            "return true;"
                                                        "}"
                                                        "return false;"
                                                    "}"
                                                    "function browserMatchesVideoIntent(element) {"
                                                        "if (!element) { return false; }"
                                                        "if (browserLooksLikeDismissControl(element)) { return false; }"
                                                        "var value = ["
                                                            "element.id || '',"
                                                            "element.className || '',"
                                                            "element.getAttribute ? (element.getAttribute('role') || '') : '',"
                                                            "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                            "element.getAttribute ? (element.getAttribute('aria-description') || '') : '',"
                                                            "element.getAttribute ? (element.getAttribute('title') || '') : ''"
                                                        "].join(' ').toLowerCase();"
                                                        "if (!value) { return false; }"
                                                        "var hasPlayWord = (/(^|[^a-z])(play|watch|resume|trailer)([^a-z]|$)/).test(value);"
                                                        "var hasControlWord = value.indexOf('ytp-') !== -1 || value.indexOf('video-play') !== -1 || value.indexOf('play-button') !== -1;"
                                                        "return hasPlayWord || hasControlWord;"
                                                    "}"
                                                    "function browserContainsVideoAncestor(element) {"
                                                        "var candidate = element;"
                                                        "var depth = 0;"
                                                        "while (candidate && depth < 10) {"
                                                            "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return true; }"
                                                            "candidate = candidate.parentElement;"
                                                            "depth += 1;"
                                                        "}"
                                                        "return false;"
                                                    "}"
                                                    "function browserLooksLikeNavigationTarget(element) {"
                                                        "if (!element) { return false; }"
                                                        "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                        "if (tagName !== 'a' && tagName !== 'button') { return false; }"
                                                        "if (element.closest && element.closest('nav, header, [role=\"navigation\"], .ac-gn, .ac-gn-content, .ac-gn-list, .globalnav')) { return true; }"
                                                        "if (tagName === 'a') {"
                                                            "var href = (element.getAttribute ? (element.getAttribute('href') || '') : '').trim().toLowerCase();"
                                                            "if (href && href !== '#' && href.indexOf('javascript:') !== 0 && href.indexOf('mailto:') !== 0 && href.indexOf('tel:') !== 0) {"
                                                                "return true;"
                                                            "}"
                                                        "}"
                                                        "return false;"
                                                    "}"
                                                    "if (browserLooksLikeNavigationTarget(interactiveElement) &&"
                                                        "!browserContainsVideoAncestor(interactiveElement) &&"
                                                        "!browserMatchesVideoIntent(interactiveElement)) {"
                                                        "return 'false';"
                                                    "}"
                                                    "var candidate = resolvedElement;"
                                                    "var candidateDepth = 0;"
                                                    "while (candidate && candidateDepth < 10) {"
                                                        "if (browserLooksLikeDismissControl(candidate)) { return 'false'; }"
                                                        "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return 'true'; }"
                                                        "if (browserMatchesVideoIntent(candidate)) { return 'true'; }"
                                                        "candidate = candidate.parentElement;"
                                                        "candidateDepth += 1;"
                                                    "}"
                                                    "var videos = document.querySelectorAll('video');"
                                                    "for (var i = 0; i < videos.length; i++) {"
                                                        "if (browserVideoContainsPoint(videos[i])) {"
                                                            "if (browserLooksLikeNavigationTarget(interactiveElement) && !browserContainsVideoAncestor(interactiveElement)) { return 'false'; }"
                                                            "if (browserLooksLikeDismissControl(interactiveElement) || browserLooksLikeDismissControl(resolvedElement)) { return 'false'; }"
                                                            "return 'true';"
                                                        "}"
                                                    "}"
                                                    "return 'false';"
                                      completion:^(NSString *result) {
        completion([result isEqualToString:@"true"]);
    }];
}

- (void)isVideoDismissTargetAtDOMPoint:(CGPoint)point
                                webView:(BrowserWebView *)webView
                             completion:(void (^)(BOOL isTarget))completion {
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                            webView:webView
                                               body:@"function browserLooksLikeDismissControl(element) {"
                                                    "if (!element) { return false; }"
                                                    "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                    "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                    "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                        "(typeof element.onclick === 'function') ||"
                                                        "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                    "if (!isButtonLike) { return false; }"
                                                    "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                    "var shortText = text.length <= 3 ? text : '';"
                                                    "var label = ["
                                                        "element.id || '',"
                                                        "element.className || '',"
                                                        "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                        "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                        "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                        "shortText"
                                                    "].join(' ').toLowerCase();"
                                                    "if (!label) { return false; }"
                                                    "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                        "label.indexOf('modal-close') !== -1 ||"
                                                        "label.indexOf('icon-close') !== -1) {"
                                                        "return true;"
                                                    "}"
                                                    "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                        "return true;"
                                                    "}"
                                                    "return false;"
                                                "}"
                                                "var candidate = interactiveElement || resolvedElement;"
                                                "while (candidate) {"
                                                    "if (browserLooksLikeDismissControl(candidate)) { return 'true'; }"
                                                    "candidate = candidate.parentElement;"
                                                "}"
                                                "return 'false';"
                                      completion:^(NSString *result) {
        completion([result isEqualToString:@"true"]);
    }];
}

- (void)primedVideoInfoAtDOMPoint:(CGPoint)point
                          webView:(BrowserWebView *)webView
                       completion:(void (^)(NSDictionary *videoInfo))completion {
    if (webView == nil) {
        completion(nil);
        return;
    }

    __weak BrowserWebView *weakWebView = webView;
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                           webView:webView
                                              body:@"window.__browserPrimedVideoInfo = '';"
                                                   "function browserAbsoluteURL(url) {"
                                                       "if (!url) { return ''; }"
                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                   "}"
                                                   "function browserVideoContainsPoint(video) {"
                                                       "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                       "var rect = video.getBoundingClientRect();"
                                                       "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                   "}"
                                                   "function browserResolveVideoElement() {"
                                                       "var candidate = resolvedElement;"
                                                       "while (candidate) {"
                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                           "candidate = candidate.parentElement;"
                                                       "}"
                                                       "var videos = document.querySelectorAll('video');"
                                                       "for (var i = 0; i < videos.length; i++) {"
                                                           "if (browserVideoContainsPoint(videos[i])) { return videos[i]; }"
                                                       "}"
                                                       "var bestVideo = null;"
                                                       "var bestScore = null;"
                                                       "for (var j = 0; j < videos.length; j++) {"
                                                           "var video = videos[j];"
                                                           "if (!video || typeof video.getBoundingClientRect !== 'function') { continue; }"
                                                           "var rect = video.getBoundingClientRect();"
                                                           "var visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));"
                                                           "var visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));"
                                                           "if (visibleWidth * visibleHeight <= 0) { continue; }"
                                                           // Several players on one page (e.g. three live streams): playing beats paused,
                                                           // then the one nearest the point (a control bar just below its own video).
                                                           "var dx = Math.max(rect.left - x, 0, x - rect.right);"
                                                           "var dy = Math.max(rect.top - y, 0, y - rect.bottom);"
                                                           "var playing = !video.paused && !video.ended && video.readyState >= 2;"
                                                           "var score = (playing ? 0 : 1e9) + Math.sqrt(dx * dx + dy * dy);"
                                                           "if (bestScore === null || score < bestScore) {"
                                                               "bestScore = score;"
                                                               "bestVideo = video;"
                                                           "}"
                                                       "}"
                                                       "return bestVideo;"
                                                   "}"
                                                   "function browserResolvePrimarySource(video) {"
                                                       "if (!video) { return ''; }"
                                                       "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                       "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                       "var sources = video.querySelectorAll('source');"
                                                       "for (var i = 0; i < sources.length; i++) {"
                                                           "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                           "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                       "}"
                                                       "return '';"
                                                   "}"
                                                   "function browserResolveSourceList(video) {"
                                                       "var values = [];"
                                                       "if (!video) { return values; }"
                                                       "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                       "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                       "var sources = video.querySelectorAll('source');"
                                                       "for (var i = 0; i < sources.length; i++) {"
                                                           "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                           "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                           "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                       "}"
                                                       "return values;"
                                                   "}"
                                                   "function browserStoreVideoInfo(video) {"
                                                       "if (!video) { return; }"
                                                       "window.__browserPrimedVideoInfo = JSON.stringify({"
                                                           "src: browserResolvePrimarySource(video),"
                                                           "sources: browserResolveSourceList(video),"
                                                           "poster: browserAbsoluteURL(video.poster || ''),"
                                                           "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                           "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                           "paused: !!video.paused"
                                                       "});"
                                                   "}"
                                                   "var video = browserResolveVideoElement();"
                                                   "if (!video) { return 'no-video'; }"
                                                   "try { if (video.focus) { video.focus(); } } catch (error) {}"
                                                   "var finish = function() {"
                                                       "try { if (video.pause) { video.pause(); } } catch (error) {}"
                                                       "browserStoreVideoInfo(video);"
                                                   "};"
                                                   "try {"
                                                       "var playResult = video.play ? video.play() : null;"
                                                       "if (playResult && typeof playResult.then === 'function') {"
                                                           "playResult.then(function() { setTimeout(finish, 0); }).catch(function() { setTimeout(finish, 0); });"
                                                       "} else {"
                                                           "setTimeout(finish, 0);"
                                                       "}"
                                                   "} catch (error) {"
                                                       "setTimeout(finish, 0);"
                                                   "}"
                                                   "return 'started';"
                                      completion:^(__unused NSString *startResult) {
        CFTimeInterval deadline = CACurrentMediaTime() + 0.75;
        [self pollPrimedVideoInfoInWebView:weakWebView deadline:deadline completion:completion];
    }];
}

// Polls (without blocking) for the info the primed-play script stores asynchronously.
- (void)pollPrimedVideoInfoInWebView:(BrowserWebView *)webView
                            deadline:(CFTimeInterval)deadline
                          completion:(void (^)(NSDictionary *videoInfo))completion {
    if (webView == nil) {
        completion(nil);
        return;
    }
    __weak BrowserWebView *weakWebView = webView;
    [webView evaluateJavaScriptString:@"window.__browserPrimedVideoInfo || ''" completion:^(NSString *result) {
        NSDictionary *videoInfo = [self JSONObjectFromJavaScriptString:result];
        if (videoInfo.count > 0) {
            completion(videoInfo);
            return;
        }
        if (CACurrentMediaTime() >= deadline) {
            completion(nil);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self pollPrimedVideoInfoInWebView:weakWebView deadline:deadline completion:completion];
        });
    }];
}

- (void)activateVideoTargetAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(NSDictionary *videoInfo))completion {
    if (webView == nil) {
        completion(nil);
        return;
    }

    NSTimeInterval effectiveTimeout = timeout > 0.0 ? timeout : 1.5;
    __weak BrowserWebView *weakWebView = webView;
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                           webView:webView
                                              body:@"function browserMatchesVideoIntent(element) {"
                                                   "if (!element) { return false; }"
                                                   "if (browserLooksLikeDismissControl(element)) { return false; }"
                                                   "var value = ["
                                                       "element.id || '',"
                                                       "element.className || '',"
                                                       "element.getAttribute ? (element.getAttribute('role') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-description') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('title') || '') : ''"
                                                   "].join(' ').toLowerCase();"
                                                   "if (!value) { return false; }"
                                                   "var hasPlayWord = (/(^|[^a-z])(play|watch|resume|trailer)([^a-z]|$)/).test(value);"
                                                   "var hasControlWord = value.indexOf('ytp-') !== -1 || value.indexOf('video-play') !== -1 || value.indexOf('play-button') !== -1;"
                                                   "return hasPlayWord || hasControlWord;"
                                               "}"
                                               "function browserLooksLikeDismissControl(element) {"
                                                   "if (!element) { return false; }"
                                                   "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                   "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                   "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                       "(typeof element.onclick === 'function') ||"
                                                       "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                   "if (!isButtonLike) { return false; }"
                                                   "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                   "var shortText = text.length <= 3 ? text : '';"
                                                   "var label = ["
                                                       "element.id || '',"
                                                       "element.className || '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                       "shortText"
                                                   "].join(' ').toLowerCase();"
                                                   "if (!label) { return false; }"
                                                   "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                       "label.indexOf('modal-close') !== -1 ||"
                                                       "label.indexOf('icon-close') !== -1) {"
                                                       "return true;"
                                                   "}"
                                                   "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                       "return true;"
                                                   "}"
                                                   "return false;"
                                               "}"
                                               "function browserActivationTarget() {"
                                                   "function browserContainsVideoAncestor(element) {"
                                                       "var candidate = element;"
                                                       "var depth = 0;"
                                                       "while (candidate && depth < 10) {"
                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return true; }"
                                                           "candidate = candidate.parentElement;"
                                                           "depth += 1;"
                                                       "}"
                                                       "return false;"
                                                   "}"
                                                   "function browserLooksLikeNavigationTarget(element) {"
                                                       "if (!element) { return false; }"
                                                       "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                       "if (tagName !== 'a' && tagName !== 'button') { return false; }"
                                                       "if (element.closest && element.closest('nav, header, [role=\"navigation\"], .ac-gn, .ac-gn-content, .ac-gn-list, .globalnav')) { return true; }"
                                                       "if (tagName === 'a') {"
                                                           "var href = (element.getAttribute ? (element.getAttribute('href') || '') : '').trim().toLowerCase();"
                                                           "if (href && href !== '#' && href.indexOf('javascript:') !== 0 && href.indexOf('mailto:') !== 0 && href.indexOf('tel:') !== 0) {"
                                                               "return true;"
                                                           "}"
                                                       "}"
                                                       "return false;"
                                                   "}"
                                                   "var candidate = interactiveElement || resolvedElement;"
                                                   "if (browserLooksLikeNavigationTarget(candidate) &&"
                                                       "!browserContainsVideoAncestor(candidate) &&"
                                                       "!browserMatchesVideoIntent(candidate)) {"
                                                       "return null;"
                                                   "}"
                                                   "var depth = 0;"
                                                   "while (candidate && depth < 10) {"
                                                       "if (browserLooksLikeDismissControl(candidate)) { return null; }"
                                                       "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                       "if (browserMatchesVideoIntent(candidate)) { return candidate; }"
                                                       "candidate = candidate.parentElement;"
                                                       "depth += 1;"
                                                   "}"
                                                   "return interactiveElement || resolvedElement || null;"
                                               "}"
                                               "function dispatchPointerLikeEvent(target, type, constructorName) {"
                                                   "if (!target) { return; }"
                                                   "try {"
                                                       "var Constructor = window[constructorName];"
                                                       "if (Constructor) {"
                                                           "var event = new Constructor(type, { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse' });"
                                                           "target.dispatchEvent(event);"
                                                           "return;"
                                                       "}"
                                                   "} catch (error) {}"
                                                   "var mouseEvent = document.createEvent('MouseEvents');"
                                                   "mouseEvent.initMouseEvent(type, true, true, window, 1, x, y, x, y, false, false, false, false, 0, null);"
                                                   "target.dispatchEvent(mouseEvent);"
                                               "}"
                                               "var target = browserActivationTarget();"
                                               "if (!target) { return 'no-target'; }"
                                               "try { if (target.focus) { target.focus(); } } catch (error) {}"
                                               "dispatchPointerLikeEvent(target, 'pointerdown', 'PointerEvent');"
                                               "dispatchPointerLikeEvent(target, 'mousedown', 'MouseEvent');"
                                               "dispatchPointerLikeEvent(target, 'pointerup', 'PointerEvent');"
                                               "dispatchPointerLikeEvent(target, 'mouseup', 'MouseEvent');"
                                               "if (typeof target.click === 'function') { target.click(); }"
                                               "else { dispatchPointerLikeEvent(target, 'click', 'MouseEvent'); }"
                                               "return 'clicked';"
                                      completion:^(__unused NSString *clickResult) {
        CFTimeInterval deadline = CACurrentMediaTime() + effectiveTimeout;
        [self pollActivatedVideoInfoAtDOMPoint:point
                                       webView:weakWebView
                                      deadline:deadline
                                 lastVideoInfo:nil
                                    completion:completion];
    }];
}

// After the synthetic click, poll (without blocking) until the page exposes a video
// source at the point, or the deadline passes (then report the last partial info).
- (void)pollActivatedVideoInfoAtDOMPoint:(CGPoint)point
                                 webView:(BrowserWebView *)webView
                                deadline:(CFTimeInterval)deadline
                           lastVideoInfo:(NSDictionary *)lastVideoInfo
                              completion:(void (^)(NSDictionary *videoInfo))completion {
    if (webView == nil) {
        completion(lastVideoInfo);
        return;
    }
    __weak BrowserWebView *weakWebView = webView;
    [self directVideoInfoAtDOMPoint:point webView:webView completion:^(NSDictionary *directVideoInfo) {
        NSString *directSrc = [directVideoInfo[@"src"] isKindOfClass:[NSString class]] ? directVideoInfo[@"src"] : @"";
        NSArray *directSources = [directVideoInfo[@"sources"] isKindOfClass:[NSArray class]] ? directVideoInfo[@"sources"] : @[];
        if (directSrc.length > 0 || directSources.count > 0) {
            completion(directVideoInfo);
            return;
        }

        BrowserWebView *strongWebView = weakWebView;
        if (strongWebView == nil) {
            completion(lastVideoInfo);
            return;
        }
        [self videoInfoAtDOMPoint:point webView:strongWebView completion:^(NSDictionary *videoInfo) {
            NSDictionary *latestVideoInfo = lastVideoInfo;
            if (videoInfo.count > 0) {
                latestVideoInfo = videoInfo;
                NSString *videoSrc = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
                NSArray *videoSources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
                if (videoSrc.length > 0 || videoSources.count > 0) {
                    completion(videoInfo);
                    return;
                }
            }

            if (CACurrentMediaTime() >= deadline) {
                completion(latestVideoInfo);
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self pollActivatedVideoInfoAtDOMPoint:point
                                               webView:weakWebView
                                              deadline:deadline
                                         lastVideoInfo:latestVideoInfo
                                            completion:completion];
            });
        }];
    }];
}

- (NSDictionary *)JSONObjectFromJavaScriptString:(NSString *)string {
    if (string.length == 0) {
        return nil;
    }

    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    return object;
}

@end
