#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

static NSString * const kWKProofOfConceptURLString = @"https://youtube.com";

@interface BrowserWKWebViewProofOfConceptViewController : UIViewController

@property (nonatomic, strong) UIView *webView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicatorView;

@end

@implementation BrowserWKWebViewProofOfConceptViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"WKWebView Proof of Concept";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];

    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.text = @"Trying to resolve WKWebView at runtime.";
    self.detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    self.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.detailLabel.textAlignment = NSTextAlignmentCenter;
    self.detailLabel.numberOfLines = 0;
    [self.view addSubview:self.detailLabel];

    self.activityIndicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.activityIndicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicatorView.hidesWhenStopped = YES;
    [self.activityIndicatorView startAnimating];
    [self.view addSubview:self.activityIndicatorView];

    UILabel *dismissHintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    dismissHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    dismissHintLabel.text = @"Press Menu or Play/Pause to dismiss";
    dismissHintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    dismissHintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    dismissHintLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:dismissHintLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:36.0],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:60.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-60.0],

        [self.activityIndicatorView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicatorView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:28.0],

        [self.detailLabel.topAnchor constraintEqualToAnchor:self.activityIndicatorView.bottomAnchor constant:28.0],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:120.0],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-120.0],

        [dismissHintLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24.0],
        [dismissHintLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:60.0],
        [dismissHintLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-60.0],
    ]];

    [self attemptWKWebViewLoad];
}

- (void)attemptWKWebViewLoad {
    [self loadWebKitFrameworkIfPossible];

    Class configurationClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    if (configurationClass == Nil || webViewClass == Nil) {
        [self.activityIndicatorView stopAnimating];
        self.detailLabel.text = @"Runtime could not resolve WKWebView or WKWebViewConfiguration.\n\nThis proof of concept depends on a private WebKit runtime being present on the device.";
        return;
    }

    id configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(new));
    if (configuration == nil) {
        [self.activityIndicatorView stopAnimating];
        self.detailLabel.text = @"WKWebViewConfiguration exists but could not be instantiated.";
        return;
    }

    SEL inlineMediaPlaybackSelector = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if ([configuration respondsToSelector:inlineMediaPlaybackSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, inlineMediaPlaybackSelector, YES);
    }

    id webViewObject = ((id (*)(id, SEL))objc_msgSend)((id)webViewClass, @selector(alloc));
    SEL initializer = NSSelectorFromString(@"initWithFrame:configuration:");
    webViewObject = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webViewObject, initializer, self.view.bounds, configuration);
    if (webViewObject == nil) {
        [self.activityIndicatorView stopAnimating];
        self.detailLabel.text = @"WKWebView class resolved, but initWithFrame:configuration: failed.";
        return;
    }

    self.webView = (UIView *)webViewObject;
    self.webView.frame = self.view.bounds;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = UIColor.blackColor;

    SEL setNavigationDelegateSelector = NSSelectorFromString(@"setNavigationDelegate:");
    if ([webViewObject respondsToSelector:setNavigationDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, setNavigationDelegateSelector, self);
    }

    [self.view insertSubview:self.webView atIndex:0];
    self.detailLabel.text = [NSString stringWithFormat:@"Resolved WKWebView. Loading %@.", kWKProofOfConceptURLString];

    NSURL *URL = [NSURL URLWithString:kWKProofOfConceptURLString];
    NSURLRequest *request = [NSURLRequest requestWithURL:URL];
    if (request == nil) {
        [self.activityIndicatorView stopAnimating];
        self.detailLabel.text = @"The proof-of-concept URL is invalid.";
        return;
    }

    SEL loadRequestSelector = NSSelectorFromString(@"loadRequest:");
    if ([webViewObject respondsToSelector:loadRequestSelector]) {
        ((id (*)(id, SEL, id))objc_msgSend)(webViewObject, loadRequestSelector, request);
    } else {
        [self.activityIndicatorView stopAnimating];
        self.detailLabel.text = @"WKWebView resolved, but loadRequest: is unavailable.";
    }
}

- (void)loadWebKitFrameworkIfPossible {
    if (NSClassFromString(@"WKWebView") != Nil) {
        return;
    }

    NSArray<NSString *> *candidatePaths = @[
        @"/System/Library/Frameworks/WebKit.framework/WebKit",
        @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
        @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
    ];

    for (NSString *candidatePath in candidatePaths) {
        if (dlopen(candidatePath.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(@"WKWebView") != Nil) {
            self.detailLabel.text = [NSString stringWithFormat:@"Loaded WebKit runtime from %@.", candidatePath];
            return;
        }
    }
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.activityIndicatorView stopAnimating];
    NSString *URLString = [self currentURLStringForWebView:webView];
    self.detailLabel.text = URLString.length > 0 ? [NSString stringWithFormat:@"Finished loading %@.", URLString] : @"Finished loading the proof-of-concept page.";
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self handleLoadFailureForWebView:webView error:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self handleLoadFailureForWebView:webView error:error];
}

- (void)handleLoadFailureForWebView:(id)webView error:(NSError *)error {
    [self.activityIndicatorView stopAnimating];
    NSString *URLString = [self currentURLStringForWebView:webView];
    if (URLString.length > 0) {
        self.detailLabel.text = [NSString stringWithFormat:@"Failed to load %@.\n\n%@", URLString, error.localizedDescription ?: @"Unknown error."];
    } else {
        self.detailLabel.text = [NSString stringWithFormat:@"WKWebView load failed.\n\n%@", error.localizedDescription ?: @"Unknown error."];
    }
}

- (NSString *)currentURLStringForWebView:(id)webView {
    SEL URLSelector = NSSelectorFromString(@"URL");
    if (webView == nil || ![webView respondsToSelector:URLSelector]) {
        return @"";
    }

    NSURL *URL = ((id (*)(id, SEL))objc_msgSend)(webView, URLSelector);
    return URL.absoluteString ?: @"";
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    [super pressesEnded:presses withEvent:event];
}

@end
