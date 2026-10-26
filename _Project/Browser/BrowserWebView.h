#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserWebViewDelegate <NSObject>

@optional
- (BOOL)webView:(id _Nonnull)webView shouldStartLoadWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (BOOL)webView:(id _Nonnull)webView shouldCreateNewTabWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
// When implemented and returning YES, the host takes over the new-tab request:
// it confirms with the user and opens the tab itself (createWebView returns
// nil immediately, the decision is async).
- (BOOL)webView:(id _Nonnull)webView wantsConfirmationForNewTabRequest:(NSURLRequest * _Nonnull)request navigationType:(NSInteger)navigationType;
- (void)webViewDidStartLoad:(id _Nonnull)webView;
- (void)webViewDidFinishLoad:(id _Nonnull)webView;
- (void)webView:(id _Nonnull)webView didFailLoadWithError:(NSError * _Nonnull)error;
// JavaScript panels (alert/confirm/prompt) ready to be presented by the host.
- (void)webView:(id _Nonnull)webView requestsPresentingAlertController:(UIAlertController * _Nonnull)alertController;
// The page requested video fullscreen (info keys: src, time, title).
- (void)webView:(id _Nonnull)webView didRequestFullscreenWithVideoInfo:(NSDictionary * _Nonnull)videoInfo;
// A media probe report showed an embed-like frame transitioning a video from
// paused to playing (the streameast-family takeover prompt trigger).
- (void)webView:(id _Nonnull)webView didDetectPlayingEmbedVideoReport:(NSDictionary * _Nonnull)report;
// ForceNativePresentOnPlay (default-NO launch flag): the first probe report
// with a playing video in any frame; once per document. The host presents the
// native fullscreen player automatically (automated testing).
- (void)webViewWantsForcedNativePresentation:(id _Nonnull)webView;

@end

@interface BrowserWebView : UIView

@property (nullable, nonatomic, weak) id<BrowserWebViewDelegate> delegate;
@property (nullable, nonatomic, readonly, strong) NSURLRequest *request;
@property (nullable, nonatomic, readonly, strong) UIScrollView *scrollView;
@property (nullable, nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=canGoBack) BOOL canGoBack;
@property (nonatomic, readonly, getter=canGoForward) BOOL canGoForward;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic) BOOL scalesPageToFit;

- (instancetype)initWithUserAgent:(NSString * _Nullable)userAgent
      allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback NS_DESIGNATED_INITIALIZER;

- (void)loadRequest:(NSURLRequest * _Nullable)request;
- (void)reload;
- (void)goBack;
- (void)goForward;
- (nullable NSString *)stringByEvaluatingJavaScriptFromString:(NSString * _Nonnull)script;
// Fire-and-forget variant: does not block the main thread; use when the result is unused.
- (void)evaluateJavaScriptStringAsync:(NSString * _Nonnull)script;
// Async variant with the evaluation result (delivered on the WebKit callback
// queue; hop to main yourself when touching UI).
- (void)evaluateJavaScriptStringAsync:(NSString * _Nonnull)script
                           completion:(void (^ _Nullable)(id _Nullable result))completion;
- (NSString * _Nonnull)runtimeMediaPreferenceReport;
- (void)setUserAgent:(NSString * _Nullable)userAgent;
- (void)pauseAllMediaPlayback;
// Per-frame media reports posted by the media-engine user script through the
// browserMediaProbe message channel (every frame incl. cross-origin iframes).
// Payload copies (pageURL/videos/captured) sorted newest-first; entries older
// than 30s are dropped on read.
- (NSArray<NSDictionary *> * _Nonnull)freshMediaProbeReportsYoungerThan:(NSTimeInterval)age;
// Evaluate the script directly in the document of every frame that reported a
// media probe (incl. cross-origin embeds top-document JS cannot reach), via
// the public per-frame WKWebView evaluation. Entries older than the probe
// freshness window are pruned before dispatch; dead frames no-op. Returns the
// number of frames targeted.
- (NSUInteger)evaluateJavaScriptOnRecentProbeFrames:(NSString * _Nonnull)javaScript;
- (void)resetMediaProbeReports;
// Popups the user script blocked ({url, timestamp} newest-last, capped).
@property (nonatomic, readonly) NSArray<NSDictionary *> * _Nonnull blockedPopups;

+ (nullable NSData *)cookieDataRepresentation;
+ (NSArray<NSHTTPCookie *> * _Nonnull)allCookies;
+ (void)restoreCookiesFromData:(NSData * _Nullable)cookieData;
+ (void)clearCachedDataWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
