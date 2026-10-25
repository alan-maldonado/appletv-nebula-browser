#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserDOMInteractionService : NSObject

- (NSString *)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body;
// Fire-and-forget variant (non-blocking) for side-effect-only scripts.
- (void)dispatchResolvedElementJavaScriptAtPoint:(CGPoint)point
                                          webView:(BrowserWebView *)webView
                                             body:(NSString *)body;
- (NSString *)evaluateEditableElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body;
// Non-blocking hover check from a cursor origin in containerView coordinates
// (converts to a DOM point itself). Completion runs on the main queue.
- (void)evaluateHoverStateAtCursorOrigin:(CGPoint)cursorOrigin
                                  inView:(UIView *)containerView
                                 webView:(BrowserWebView *)webView
                              completion:(void (^)(NSString *state))completion;
- (NSString *)javaScriptEscapedString:(NSString *)string;
- (NSDictionary *)linkInfoAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView;

// Non-blocking variants. Completions run on the main queue; never call the blocking
// JS bridge from event handling (see BrowserWebView's async eval).
- (void)DOMPointForCursorOrigin:(CGPoint)cursorOrigin
                         inView:(UIView *)containerView
                        webView:(BrowserWebView *)webView
                     completion:(void (^)(CGPoint point))completion;
- (void)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                         webView:(BrowserWebView *)webView
                                            body:(NSString *)body
                                      completion:(void (^)(NSString *result))completion;
- (void)videoInfoAtDOMPoint:(CGPoint)point
                    webView:(BrowserWebView *)webView
                 completion:(void (^)(NSDictionary * _Nullable videoInfo))completion;
- (void)directVideoInfoAtDOMPoint:(CGPoint)point
                          webView:(BrowserWebView *)webView
                       completion:(void (^)(NSDictionary * _Nullable videoInfo))completion;
- (void)isVideoActivationTargetAtDOMPoint:(CGPoint)point
                                   webView:(BrowserWebView *)webView
                                completion:(void (^)(BOOL isTarget))completion;
- (void)isVideoDismissTargetAtDOMPoint:(CGPoint)point
                                webView:(BrowserWebView *)webView
                             completion:(void (^)(BOOL isTarget))completion;
// Plays then pauses the video to coax the page into exposing its source (≤0.75 s).
- (void)primedVideoInfoAtDOMPoint:(CGPoint)point
                          webView:(BrowserWebView *)webView
                       completion:(void (^)(NSDictionary * _Nullable videoInfo))completion;
// Synthetic click on the video's play control, then waits up to timeout for a source.
- (void)activateVideoTargetAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(NSDictionary * _Nullable videoInfo))completion;

@end

NS_ASSUME_NONNULL_END
