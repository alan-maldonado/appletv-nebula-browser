#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserWebViewDelegate <NSObject>

@optional
- (BOOL)webView:(id _Nonnull)webView shouldStartLoadWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (BOOL)webView:(id _Nonnull)webView shouldCreateNewTabWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (void)webViewDidStartLoad:(id _Nonnull)webView;
- (void)webViewDidFinishLoad:(id _Nonnull)webView;
- (void)webView:(id _Nonnull)webView didFailLoadWithError:(NSError * _Nonnull)error;
// JavaScript panels (alert/confirm/prompt) ready to be presented by the host.
- (void)webView:(id _Nonnull)webView requestsPresentingAlertController:(UIAlertController * _Nonnull)alertController;
// The page requested video fullscreen (info keys: src, time, title).
- (void)webView:(id _Nonnull)webView didRequestFullscreenWithVideoInfo:(NSDictionary * _Nonnull)videoInfo;
// Nebula Remote: the page's active <video> changed (keys: id, title, time, duration,
// playing, rate; or id + gone). frame is the WKFrameInfo it came from, for
// evaluateJavaScriptStringAsync:inFrame:.
- (void)webView:(id _Nonnull)webView didUpdateMediaState:(NSDictionary * _Nonnull)mediaState frame:(id _Nullable)frame;

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
// Same, inside a specific frame (a WKFrameInfo from a script message); main frame when nil.
- (void)evaluateJavaScriptStringAsync:(NSString * _Nonnull)script inFrame:(id _Nullable)frame;
// Non-blocking variant that delivers the string result on the main queue. Use from
// event-handling paths (touchesMoved, presses): the synchronous variant pumps a nested
// run loop, and UIKit traps if it re-enters -[UIApplication sendEvent:] from there.
- (void)evaluateJavaScriptString:(NSString * _Nonnull)script
                      completion:(void (^ _Nonnull)(NSString * _Nullable result))completion;
- (NSString * _Nonnull)runtimeMediaPreferenceReport;
- (void)setUserAgent:(NSString * _Nullable)userAgent;
- (void)pauseAllMediaPlayback;

+ (nullable NSData *)cookieDataRepresentation;
+ (NSArray<NSHTTPCookie *> * _Nonnull)allCookies;
+ (void)restoreCookiesFromData:(NSData * _Nullable)cookieData;
+ (void)clearCachedDataWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
