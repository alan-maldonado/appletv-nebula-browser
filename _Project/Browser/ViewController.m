//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "BrowserMenuCoordinator.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserFavoritesStore.h"
#import "BrowserRemoteServer.h"
#import "BrowserRemoteState.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

static UIColor *kTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

#pragma mark - URL / search input (keyboard only, no visible modal)

@interface BrowserURLInputViewController : UIViewController
@property (nonatomic, copy) NSString *initialText;
@property (nonatomic, copy) void (^submitHandler)(NSString *text);
@property (nonatomic) UITextField *textField;
@property (nonatomic) BOOL didCommit;
@end

@implementation BrowserURLInputViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Transparent: the system keyboard is the only thing the user sees.
    self.view.backgroundColor = UIColor.clearColor;

    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectZero];
    // URL-optimized keyboard: dedicated "." and "/" keys, no autocorrect/caps.
    textField.keyboardType = UIKeyboardTypeURL;
    textField.textContentType = UITextContentTypeURL;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.spellCheckingType = UITextSpellCheckingTypeNo;
    if (@available(tvOS 11.0, *)) {
        textField.smartQuotesType = UITextSmartQuotesTypeNo;
        textField.smartDashesType = UITextSmartDashesTypeNo;
        textField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    }
    textField.placeholder = @"Enter URL or Search Terms";
    textField.returnKeyType = UIReturnKeyGo;
    textField.text = self.initialText;
    textField.hidden = YES; // The tvOS keyboard shows its own text preview.
    [textField addTarget:self action:@selector(handleSubmit:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [textField addTarget:self action:@selector(handleEditingEnded:) forControlEvents:UIControlEventEditingDidEnd];
    [self.view addSubview:textField];
    self.textField = textField;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.textField becomeFirstResponder];
}

- (void)handleSubmit:(UITextField *)textField {
    self.didCommit = YES;
    NSString *text = textField.text;
    void (^handler)(NSString *) = self.submitHandler;
    [self dismissViewControllerAnimated:NO completion:^{
        if (handler != nil) {
            handler(text);
        }
    }];
}

- (void)handleEditingEnded:(UITextField *)textField {
    // Fires for both commit (Go) and cancel (Menu dismisses the keyboard). On a
    // plain cancel, tear down this invisible controller so one Back exits.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.didCommit && self.presentingViewController != nil) {
            [self dismissViewControllerAnimated:NO completion:nil];
        }
    });
}

@end

#pragma mark - Usage Guide (scrollable)

@interface BrowserUsageGuideViewController : UIViewController
@property (nonatomic, copy) NSString *guideText;
@property (nonatomic, copy) void (^dismissHandler)(void);
@property (nonatomic) UITextView *textView;
@end

@implementation BrowserUsageGuideViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 24.0;
    panel.layer.masksToBounds = YES;
    [self.view addSubview:panel];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Usage Guide";
    title.font = [UIFont boldSystemFontOfSize:40.0];
    title.textColor = UIColor.whiteColor;
    [panel.contentView addSubview:title];

    UITextView *textView = [UITextView new];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.backgroundColor = UIColor.clearColor;
    textView.scrollEnabled = YES;
    textView.showsVerticalScrollIndicator = YES;
    textView.userInteractionEnabled = YES;
    textView.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    textView.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightRegular];
    textView.text = self.guideText;
    // tvOS: lets the remote scroll the text and focus the view.
    if (@available(tvOS 11.0, *)) {
        textView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [panel.contentView addSubview:textView];
    self.textView = textView;

    UILabel *footer = [UILabel new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.text = @"Press Menu to close";
    footer.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
    footer.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    footer.textAlignment = NSTextAlignmentCenter;
    [panel.contentView addSubview:footer];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [panel.widthAnchor constraintEqualToConstant:980.0],
        [panel.heightAnchor constraintEqualToConstant:760.0],

        [title.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:48.0],
        [title.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:60.0],

        [textView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24.0],
        [textView.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:56.0],
        [textView.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-56.0],
        [textView.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-16.0],

        [footer.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:60.0],
        [footer.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-60.0],
        [footer.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-40.0],
    ]];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.textView != nil ? @[self.textView] : [super preferredFocusEnvironments];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        void (^handler)(void) = self.dismissHandler;
        [self dismissViewControllerAnimated:YES completion:^{
            if (handler != nil) {
                handler();
            }
        }];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

#pragma mark - Support / Donate

@interface BrowserDonateViewController : UIViewController
@end

@implementation BrowserDonateViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 28.0;
    panel.layer.masksToBounds = YES;
    [self.view addSubview:panel];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Support Nebula Browser";
    title.font = [UIFont boldSystemFontOfSize:46.0];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    [panel.contentView addSubview:title];

    UILabel *message = [UILabel new];
    message.translatesAutoresizingMaskIntoConstraints = NO;
    message.numberOfLines = 0;
    message.text = @"Nebula Browser is free and open source. If you enjoy it, scan the code to support ongoing development and the features the community wants most. Thank you!";
    message.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightRegular];
    message.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    message.textAlignment = NSTextAlignmentCenter;
    [panel.contentView addSubview:message];

    UIImageView *qr = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"DonateQR"]];
    qr.translatesAutoresizingMaskIntoConstraints = NO;
    qr.contentMode = UIViewContentModeScaleAspectFit;
    qr.layer.cornerRadius = 12.0;
    qr.layer.masksToBounds = YES;
    [panel.contentView addSubview:qr];

    UILabel *urlLabel = [UILabel new];
    urlLabel.translatesAutoresizingMaskIntoConstraints = NO;
    urlLabel.text = @"ko-fi.com/nebulabrowser";
    urlLabel.font = [UIFont monospacedDigitSystemFontOfSize:28.0 weight:UIFontWeightSemibold];
    urlLabel.textColor = UIColor.whiteColor;
    urlLabel.textAlignment = NSTextAlignmentCenter;
    [panel.contentView addSubview:urlLabel];

    UILabel *footer = [UILabel new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.text = @"Press Menu to close";
    footer.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
    footer.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    footer.textAlignment = NSTextAlignmentCenter;
    [panel.contentView addSubview:footer];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [panel.widthAnchor constraintEqualToConstant:760.0],

        [title.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:48.0],
        [title.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:48.0],
        [title.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-48.0],

        [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:20.0],
        [message.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:60.0],
        [message.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-60.0],

        [qr.topAnchor constraintEqualToAnchor:message.bottomAnchor constant:36.0],
        [qr.centerXAnchor constraintEqualToAnchor:panel.contentView.centerXAnchor],
        [qr.widthAnchor constraintEqualToConstant:360.0],
        [qr.heightAnchor constraintEqualToConstant:360.0],

        [urlLabel.topAnchor constraintEqualToAnchor:qr.bottomAnchor constant:24.0],
        [urlLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:48.0],
        [urlLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-48.0],

        [footer.topAnchor constraintEqualToAnchor:urlLabel.bottomAnchor constant:32.0],
        [footer.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:48.0],
        [footer.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-48.0],
        [footer.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-44.0],
    ]];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypeSelect || press.type == UIPressTypePlayPause)) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserRemoteServerDelegate, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserRemoteServer *remoteServer;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
// Double-back-to-exit: timestamp of the last Menu press at the root of history.
@property (nonatomic) CFAbsoluteTime lastExitBackPressTimestamp;
@property (nonatomic) UILabel *exitHintLabel;
@property (nonatomic) UIView *privacyCoverView;
@property (nonatomic) NSLayoutConstraint *exitHintWidthConstraint;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];
    self.remoteServer = [BrowserRemoteServer new];
    self.remoteServer.delegate = self;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleUserDefaultsDidChange:)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:nil];
    // Reinstalls reset the alternate icon while the theme preference persists.
    [BrowserMenuCoordinator applyAppIconForCurrentTheme];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;

    self.domInteractionService = [BrowserDOMInteractionService new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    // Launch page preference: "Home Page" starts fresh; otherwise restore the last session.
    if (self.preferencesStore.launchPageMode == 1) {
        [self.tabCoordinator startFreshLoadingHomePage];
    } else {
        [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    // Run launch promos once per process: the usage guide takes priority; if it's
    // not showing, occasionally surface the support screen.
    if (!self.displayedHintsOnLaunch) {
        self.displayedHintsOnLaunch = YES;
        if (!self.preferencesStore.dontShowHintsOnLaunch) {
            [self showHintsAlert];
        } else {
            [self maybeShowDonateOnLaunch];
        }
    }
}

// Show the support screen every 10th launch (counter persisted), so it nudges
// without being annoying.
- (void)maybeShowDonateOnLaunch {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger count = [defaults integerForKey:@"NebulaLaunchCount"] + 1;
    [defaults setInteger:count forKey:@"NebulaLaunchCount"];
    if (count % 10 == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.presentedViewController == nil) {
                [self showDonateScreen];
            }
        });
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self applyExitPrivacyActions];
    [self showPrivacyCoverIfNeeded];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self applyExitPrivacyActions];
    [self showPrivacyCoverIfNeeded];
    [self.remoteServer stop];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self applyExitPrivacyActions];
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self hidePrivacyCover];
    if (self.preferencesStore.remoteServerEnabled) {
        [self.remoteServer start];
    }
    [self publishRemoteState];
}

// Persist or wipe browsing state when leaving the app, per privacy preferences.
- (void)applyExitPrivacyActions {
    if (self.preferencesStore.clearHistoryOnExit) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"HISTORY"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [self.tabCoordinator persistSession];
}

// Privacy mode: cover the page so it isn't shown in the tvOS app switcher snapshot.
- (void)showPrivacyCoverIfNeeded {
    if (!self.preferencesStore.privacyModeEnabled) {
        return;
    }
    if (self.privacyCoverView == nil) {
        UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds];
        cover.backgroundColor = UIColor.blackColor;
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        cover.layer.zPosition = 100000.0;

        UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"ThemePreview-Classic"] ?: nil];
        logo.contentMode = UIViewContentModeScaleAspectFit;
        logo.translatesAutoresizingMaskIntoConstraints = NO;
        logo.alpha = 0.5;
        [cover addSubview:logo];
        [NSLayoutConstraint activateConstraints:@[
            [logo.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
            [logo.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
            [logo.widthAnchor constraintEqualToConstant:480.0],
            [logo.heightAnchor constraintEqualToConstant:288.0],
        ]];
        self.privacyCoverView = cover;
    }
    self.privacyCoverView.frame = self.view.bounds;
    [self.view addSubview:self.privacyCoverView];
    [self.view bringSubviewToFront:self.privacyCoverView];
}

- (void)hidePrivacyCover {
    [self.privacyCoverView removeFromSuperview];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    [self.remoteInputController handleGlobalSelectPressEndedNotification];
}

#pragma mark - Helpers

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    if (self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = YES;
    [self.topMenuView setFocusModeActive:YES];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if (self.webview.canGoBack) {
                [self.webview goBack];
            }
            break;
        case BrowserTopBarActionRefresh:
            [self.webview reload];
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            [self showInputURLorSearchGoogle];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                                         message:@"You can still open the side menu by double-tapping the Play/Pause button."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Hide Bar"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           "var elements = document.querySelectorAll('body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
    [self.webview evaluateJavaScriptStringAsync:jsString];
}

- (void)showInputURLorSearchGoogle {
    BrowserURLInputViewController *inputViewController = [[BrowserURLInputViewController alloc] init];
    inputViewController.modalPresentationStyle = UIModalPresentationOverFullScreen;
    __weak typeof(self) weakSelf = self;
    inputViewController.submitHandler = ^(NSString *text) {
        NSURLRequest *request = [weakSelf.navigationService requestForURLOrSearchString:text];
        if (request != nil) {
            [weakSelf.webview loadRequest:request];
        }
    };
    [self presentViewController:inputViewController animated:NO completion:nil];
}

- (void)requestURLorSearchInput {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Quick Menu"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Go Forward"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Enter URL or Search"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.tabCoordinator.previousURL = @"";
            [self.webview reload];
        }]];
    }

    // "Go to <domain>": jump to the root page of the current site. Only offered
    // when we're somewhere deeper than the site root.
    NSURL *currentURL = self.webview.request.URL;
    if (currentURL.host.length > 0) {
        NSURLComponents *rootComponents = [NSURLComponents new];
        rootComponents.scheme = currentURL.scheme;
        rootComponents.host = currentURL.host;
        rootComponents.port = currentURL.port;
        NSURL *siteRootURL = rootComponents.URL;
        BOOL alreadyAtRoot = (currentURL.path.length == 0 || [currentURL.path isEqualToString:@"/"]) &&
                             currentURL.query == nil &&
                             currentURL.fragment == nil;
        if (siteRootURL != nil && !alreadyAtRoot) {
            [alertController addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Go to %@", currentURL.host]
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(__unused UIAlertAction *action) {
                [self.webview loadRequest:[NSURLRequest requestWithURL:siteRootURL]];
            }]];
        }
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Settings"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showAdvancedMenu];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];

    // When the top bar is hidden, Settings is otherwise hard to find. Surface a
    // one-line tip in the Quick Menu the first few times in that state.
    if (!self.browserTopMenuShowing) {
        NSUInteger shownCount = self.preferencesStore.settingsHintShownCount;
        if (shownCount < 3) {
            alertController.message = @"Tip: open Settings below to show the top bar again or change options.";
            self.preferencesStore.settingsHintShownCount = shownCount + 1;
        }
    }

    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showHintsAlert {
    NSString *guide =
        @"BROWSING\n"
        @"• Double press the touch surface to switch between cursor & scroll mode.\n"
        @"• Press the touch surface in cursor mode to click.\n"
        @"• Back goes to the previous page. Press Back twice to exit the app.\n"
        @"• Arrow keys scroll the page. Up at the top opens the address bar.\n"
        @"\nARROW SHORTCUTS (double press)\n"
        @"• Up: Tabs   • Down: Favorites   • Left: History   • Right: New Tab\n"
        @"\nMENUS\n"
        @"• Play/Pause: Quick Menu (URL & search, reload, go forward, site home).\n"
        @"• Double tap Play/Pause: full menu. Change settings there with Left/Right.\n"
        @"• Tabs view: swipe up on a card to close that tab.\n"
        @"\nVIDEO PLAYER\n"
        @"• Right: fast-forward 2x to 32x. Left: slow down. Play/Pause: resume there.\n"
        @"• Swipe to move through the video; while paused, quick swipes accelerate.\n"
        @"• Back cancels fast-forward or swiping and returns to where you were.\n"
        @"• Videos resume where you left off.";
    BrowserUsageGuideViewController *guideViewController = [[BrowserUsageGuideViewController alloc] init];
    guideViewController.guideText = guide;
    guideViewController.modalPresentationStyle = UIModalPresentationOverFullScreen;
    guideViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:guideViewController animated:YES completion:nil];
}

- (void)browserHandlePrimaryAction {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    CGPoint point = [self.view convertPoint:[self.remoteInputController cursorAimPoint] toView:self.webview];
    if (point.y < 0) {
        // Cursor is over the top bar: click the button under it directly; if
        // there is none, fall back to focus-driven top bar navigation.
        CGPoint topBarPoint = [self.view convertPoint:[self.remoteInputController cursorAimPoint] toView:self.topMenuView];
        if ([self.topMenuView handleCursorClickAtPoint:topBarPoint]) {
            return;
        }
        [self activateTopBarFocusMode];
        return;
    }

    BrowserWebView *webView = self.webview;
    [self browserResolveDOMCursorPointWithCompletion:^(CGPoint domPoint) {
        [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:webView];
    }];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)webView:(id)webView requestsPresentingAlertController:(UIAlertController *)alertController {
    (void)webView;
    // JavaScript panels must always get presented (their completion handler keeps
    // the page's JS waiting), so present on top of whatever is already up.
    UIViewController *presenter = self;
    while (presenter.presentedViewController != nil && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    [presenter presentViewController:alertController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowDonate {
    [self showDonateScreen];
}

- (void)showDonateScreen {
    if ([self.presentedViewController isKindOfClass:[BrowserDonateViewController class]]) {
        return;
    }
    BrowserDonateViewController *donateViewController = [[BrowserDonateViewController alloc] init];
    donateViewController.modalPresentationStyle = UIModalPresentationOverFullScreen;
    donateViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:donateViewController animated:YES completion:nil];
}

- (void)browserShowTabOverview {
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
    // Make the recovery path explicit (the bar that held those controls is gone).
    [self showToastWithText:@"Top bar hidden. Press Play/Pause → Settings to bring it back." width:760.0];
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserDidChangeTheme {
    [self.topMenuView applyThemeAccent];
    [self publishRemoteState];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserResolveDOMCursorPointWithCompletion:(void (^)(CGPoint))completion {
    [self.domInteractionService DOMPointForCursorOrigin:[self.remoteInputController cursorAimPoint]
                                                 inView:self.view
                                                webView:self.webview
                                             completion:completion];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorShowTabOverview {
    [self browserShowTabOverview];
}

- (void)browserTabCoordinatorActiveTabDidRefresh {
    [self publishRemoteState];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator closeTabAtIndex:tabIndex];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (UIView *)browserPageActionCoordinatorContainerView {
    return self.view;
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    return self.presentedViewController;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (void)browserRemoteInputControllerFullscreenVideoAtCursorWithCompletion:(void (^)(BOOL))completion {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        completion(NO);
        return;
    }
    BrowserWebView *webView = self.webview;
    [self browserResolveDOMCursorPointWithCompletion:^(CGPoint domPoint) {
        if (domPoint.y < 0) {
            completion(NO); // cursor is over the top bar, not the page
            return;
        }
        [self fullscreenVideoAtDOMPoint:domPoint webView:webView completion:completion];
    }];
}

- (void)fullscreenVideoAtDOMPoint:(CGPoint)domPoint
                          webView:(BrowserWebView *)webView
                       completion:(void (^)(BOOL))completion {
    // Find a <video> at the cursor (the element, a descendant, or a player
    // ancestor's video) and fullscreen it via the page API — which our
    // fake-fullscreen hook routes to the native player (or CSS fallback).
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        "var x=%ld,y=%ld;"
        "var el=document.elementFromPoint(x,y);"
        "function covers(c){if(!c){return false;}var r=c.getBoundingClientRect();"
            "return x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom&&r.width>0&&r.height>0;}"
        "var v=null,a=el;"
        "while(a){"
            // Only accept a video whose box actually contains the tap point, so
            // double-tapping elsewhere on the page doesn't grab a far-off video.
            "if(a.tagName==='VIDEO'&&covers(a)){v=a;break;}"
            "if(a.querySelector){var q=a.querySelector('video');if(covers(q)){v=q;break;}}"
            "a=a.parentElement;"
        "}"
        "if(!v){return 'false';}"
        "if(v.webkitEnterFullscreen){v.webkitEnterFullscreen();}"
        "else if(v.requestFullscreen){v.requestFullscreen();}"
        "else if(v.webkitRequestFullscreen){v.webkitRequestFullscreen();}"
        "return 'true';"
        "})()",
        (long)llround(domPoint.x), (long)llround(domPoint.y)];
    [webView evaluateJavaScriptString:script completion:^(NSString *result) {
        completion([result isEqualToString:@"true"]);
    }];
}

- (void)browserRemoteInputControllerShowTabOverview {
    [self browserShowTabOverview];
}

- (void)browserRemoteInputControllerShowHistory {
    [self.menuCoordinator showHistoryMenu];
}

- (void)browserRemoteInputControllerShowFavorites {
    [self.menuCoordinator showFavoritesMenu];
}

- (void)browserRemoteInputControllerOpenNewTab {
    [self browserCreateNewTabLoadingHomePage:YES];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.webview.canGoBack) {
        [self.webview goBack];
    } else {
        // No history left: require a second Back press within 2s to exit.
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - self.lastExitBackPressTimestamp <= 2.0) {
            // exit() skips the app lifecycle callbacks (resignActive/background/
            // terminate), so persist the session and cookies here or they'd be lost.
            [self.tabCoordinator persistSession];
            NSData *cookieData = [BrowserWebView cookieDataRepresentation];
            if (cookieData != nil) {
                [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:@"ApplicationCookie"];
            }
            [[NSUserDefaults standardUserDefaults] synchronize];
            exit(EXIT_SUCCESS);
        }
        self.lastExitBackPressTimestamp = now;
        [self showExitHintToast];
    }
}

- (void)showExitHintToast {
    [self showToastWithText:@"Press Back again to exit" width:520.0];
}

- (void)showToastWithText:(NSString *)text width:(CGFloat)width {
    if (self.exitHintLabel == nil) {
        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont systemFontOfSize:29.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.layer.cornerRadius = 10.0;
        label.layer.masksToBounds = YES;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:label];
        self.exitHintWidthConstraint = [label.widthAnchor constraintEqualToConstant:width];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [label.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-60.0],
            self.exitHintWidthConstraint,
            [label.heightAnchor constraintGreaterThanOrEqualToConstant:64.0],
        ]];
        self.exitHintLabel = label;
    }
    self.exitHintLabel.text = text;
    self.exitHintWidthConstraint.constant = width;
    [self.view bringSubviewToFront:self.exitHintLabel];
    [self.exitHintLabel.layer removeAllAnimations];
    self.exitHintLabel.alpha = 1.0;
    self.exitHintLabel.hidden = NO;
    [UIView animateWithDuration:0.3
                          delay:2.4
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.exitHintLabel.alpha = 0.0;
    }
                     completion:^(BOOL finished) {
        if (finished) {
            self.exitHintLabel.hidden = YES;
        }
    }];
}

- (void)browserHandleGlobalMenuPress {
    // Single deterministic entry point for Menu when nothing is presented
    // (called from the UIApplication sendEvent: interception so the press can
    // never fall through to the system and suspend the app).
    if (self.isTopBarFocusActive) {
        [self browserRemoteInputControllerDeactivateTopBarFocus];
        return;
    }
    if ([self browserRemoteInputControllerTabOverviewVisible]) {
        [self browserRemoteInputControllerDismissTabOverview];
        return;
    }
    // In scroll mode, Back returns to cursor mode instead of navigating.
    if (!self.remoteInputController.cursorModeEnabled) {
        [self.remoteInputController setCursorModeEnabled:YES];
        return;
    }
    [self browserRemoteInputControllerHandleMenuPress];
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self requestURLorSearchInput];
    }
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    [self showAdvancedMenu];
}

- (void)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point
                                                 completion:(void (^)(NSString *))completion {
    // Reflect hover over the top bar (cursor mode) as a button glow.
    CGPoint topBarPoint = [self.view convertPoint:point toView:self.topMenuView];
    CGPoint webPointForBar = [self.view convertPoint:point toView:self.webview];
    if (webPointForBar.y < 0) {
        [self.topMenuView updateCursorHoverAtPoint:topBarPoint];
    } else {
        [self.topMenuView clearCursorHover];
    }

    if (self.webview.request == nil) {
        completion(@"false");
        return;
    }
    CGPoint webPoint = [self.view convertPoint:point toView:self.webview];
    if (webPoint.y < 0) {
        completion(@"false");
        return;
    }
    // Called from touchesMoved: must not block (see BrowserWebView's async eval).
    [self.domInteractionService evaluateHoverStateAtCursorOrigin:[self.remoteInputController cursorAimPoint]
                                                          inView:self.view
                                                         webView:self.webview
                                                      completion:completion];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

#pragma mark - Nebula Remote settings

- (void)browserRemoteServerPreferenceDidChange {
    if (self.preferencesStore.remoteServerEnabled) {
        [self.remoteServer start];
    } else {
        [self.remoteServer stop];
    }
}

- (NSString *)browserRemoteServerURLString {
    if (self.remoteServer.port == 0) {
        return nil;
    }
    // Bonjour name of this device, e.g. Alans-Apple-TV-4K.local.
    NSString *host = NSProcessInfo.processInfo.hostName;
    if (host.length == 0 || [host isEqualToString:@"localhost"]) {
        return nil;
    }
    if (![host hasSuffix:@".local"]) {
        host = [host stringByAppendingString:@".local"];
    }
    return [NSString stringWithFormat:@"http://%@:%u", host, self.remoteServer.port];
}

#pragma mark - BrowserRemoteServerDelegate

- (NSInteger)remoteServer:(BrowserRemoteServer *)server
            performAction:(NSString *)action
                  payload:(NSDictionary *)payload
                 response:(NSDictionary **)outResponse {
    if ([action hasPrefix:@"tabs/"]) {
        return [self performRemoteTabAction:action payload:payload response:outResponse];
    }
    *outResponse = @{@"error": @"invalid-request"};
    return 400;
}

- (NSInteger)performRemoteTabAction:(NSString *)action payload:(NSDictionary *)payload response:(NSDictionary **)outResponse {
    if ([action isEqualToString:@"tabs/new"]) {
        if (self.viewModel.tabs.count >= [BrowserViewModel maximumTabCount]) {
            *outResponse = @{@"error": @"max-tabs"};
            return 409; // the panel reports it; no alert on the TV
        }
        [self.pageActionCoordinator discardActiveEditableField];
        [self.tabCoordinator createNewTabLoadingHomePage:YES];
        return 200;
    }

    NSInteger index = [self.tabCoordinator indexOfTabWithIdentifier:payload[@"id"]];
    if (index == NSNotFound) {
        *outResponse = @{@"error": @"tab-not-found"};
        return 404;
    }
    [self.pageActionCoordinator discardActiveEditableField];
    if ([action isEqualToString:@"tabs/switch"]) {
        [self.tabCoordinator switchToTabAtIndex:index];
    } else {
        [self.tabCoordinator closeTabAtIndex:index];
    }
    return 200;
}

- (void)remoteServer:(BrowserRemoteServer *)server openText:(NSString *)text inNewTab:(BOOL)newTab {
    NSURLRequest *request = [self.navigationService requestForURLOrSearchString:text];
    if (request == nil) {
        return;
    }
    [self.pageActionCoordinator discardActiveEditableField];
    if (newTab) {
        [self.tabCoordinator createNewTabWithRequest:request];
    } else {
        [self.webview loadRequest:request];
    }
}

- (BOOL)remoteServer:(BrowserRemoteServer *)server submitFieldText:(NSString *)text fieldID:(NSString *)fieldID submitForm:(BOOL)submitForm {
    return [self.pageActionCoordinator commitRemoteText:text forFieldID:fieldID submitForm:submitForm];
}

- (void)browserPageActionCoordinatorActiveFieldDidChange:(NSDictionary<NSString *, NSString *> *)field {
    NSUInteger previousVersion = self.remoteServer.state.version;
    [self.remoteServer.state updateField:field];
    if (self.remoteServer.state.version != previousVersion) {
        [self.remoteServer stateDidChange];
    }
}

// Rebuilds every panel section from the live app state; long-polls wake only if something changed.
- (void)publishRemoteState {
    BrowserRemoteState *state = self.remoteServer.state;
    NSUInteger previousVersion = state.version;

    BrowserTabViewModel *activeTab = self.tabCoordinator.activeTab;
    NSString *pageURLString = activeTab.URLString.length > 0 ? activeTab.URLString : (self.webview.request.URL.absoluteString ?: @"");
    NSString *pageTitle = self.webview.title.length > 0 ? self.webview.title : (activeTab.title ?: @"");
    [state updatePageTitle:pageTitle URLString:pageURLString];

    NSMutableArray<NSDictionary *> *tabs = [NSMutableArray array];
    [self.viewModel.tabs enumerateObjectsUsingBlock:^(BrowserTabViewModel *tab, NSUInteger index, __unused BOOL *stop) {
        NSString *URLString = tab.URLString.length > 0 ? tab.URLString : (tab.requestURL ?: @"");
        [tabs addObject:@{
            @"id": tab.identifier ?: @"",
            @"title": tab.title ?: @"",
            @"url": URLString,
            @"active": @((BOOL)((NSInteger)index == self.viewModel.activeTabIndex)),
        }];
    }];
    [state updateTabs:tabs];
    [state updateFavorites:[[BrowserFavoritesStore standardStore] favorites]];
    [state updateHome:@{
        @"url": self.preferencesStore.homePageURLString ?: @"",
        @"launch": self.preferencesStore.launchPageMode == 1 ? @"home-page" : @"last-session",
    }];

    // The panel follows the TV's theme accent; light accents (Classic, Gold, Sky) get dark text.
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    [self.preferencesStore.themeAccentColor getRed:&red green:&green blue:&blue alpha:&alpha];
    NSString *accentHex = [NSString stringWithFormat:@"#%02X%02X%02X",
                           (int)lround(red * 255.0), (int)lround(green * 255.0), (int)lround(blue * 255.0)];
    CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    [state updateTheme:@{@"accent": accentHex, @"onAccent": luminance > 0.6 ? @"#14102A" : @"#FFFFFF"}];

    if (state.version != previousVersion) {
        [self.remoteServer stateDidChange];
    }
}

- (void)handleUserDefaultsDidChange:(NSNotification *)notification {
    // Favorites, home page and theme all live in NSUserDefaults; may be posted off-main.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self publishRemoteState];
    });
}

- (NSData *)remoteServerTouchIconPNG:(BrowserRemoteServer *)server {
    // The planet + ring of the active theme's preview art (800x480; "WEB BROWSER" text sits
    // below y≈360), centered on a square filled with the art's flat background color.
    NSString *assetName = [@"ThemePreview-" stringByAppendingString:self.preferencesStore.themeName];
    UIImage *preview = [UIImage imageNamed:assetName] ?: [UIImage imageNamed:@"ThemePreview-Nebula"];
    if (preview.CGImage == NULL) {
        return nil;
    }
    CGFloat scale = preview.scale;
    CGRect artRect = CGRectMake(200.0, 20.0, 400.0, 330.0);
    CGImageRef crop = CGImageCreateWithImageInRect(preview.CGImage, CGRectMake(CGRectGetMinX(artRect) * scale, CGRectGetMinY(artRect) * scale,
                                                                               CGRectGetWidth(artRect) * scale, CGRectGetHeight(artRect) * scale));
    CGImageRef corner = CGImageCreateWithImageInRect(preview.CGImage, CGRectMake(0.0, 0.0, 1.0, 1.0));
    if (crop == NULL || corner == NULL) {
        CGImageRelease(crop);
        CGImageRelease(corner);
        return nil;
    }
    UIImage *art = [UIImage imageWithCGImage:crop];
    UIImage *background = [UIImage imageWithCGImage:corner];
    CGImageRelease(crop);
    CGImageRelease(corner);

    CGFloat side = 180.0;
    CGFloat artHeight = side * CGRectGetHeight(artRect) / CGRectGetWidth(artRect);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [background drawInRect:CGRectMake(0.0, 0.0, side, side)];
        [art drawInRect:CGRectMake(0.0, (side - artHeight) / 2.0, side, artHeight)];
    }];
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webView:(id)webView didRequestFullscreenWithVideoInfo:(NSDictionary *)videoInfo {
    (void)webView;
    // Page fullscreen button pressed (fake-fullscreen user script bridge):
    // open our native player instead of WebKit's broken tvOS fullscreen.
    [self.videoPlaybackCoordinator handlePageFullscreenRequestWithInfo:videoInfo];
}

- (void)webViewDidStartLoad:(id)webView {
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab == self.tabCoordinator.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }
    if (tab != self.tabCoordinator.activeTab) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Could Not Load Webpage"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Google This Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Enter a URL or Search"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf requestURLorSearchInput];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end
