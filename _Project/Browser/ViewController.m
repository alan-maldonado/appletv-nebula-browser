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
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

// ForceNativePresentOnPlay: a launch modal routinely covers the page when the
// web view reports a playing video, so the presentation is retried on a timer
// until it lands or the attempt cap is reached.
static const NSTimeInterval kForceNativePresentRetryInterval = 1.5;
static const NSUInteger kForceNativePresentMaxRetries = 8;

// Auto-fullscreen suppression window after a native-player dismissal (or a
// "Keep playing here" choice): the embed watchdog reloads the player iframe
// the moment we leave, its video replays, and the probes report again within
// seconds; without a window the dismissed player re-presents forever.
static const NSTimeInterval kNativePlayerDismissSuppressionInterval = 180.0;
// The suppression is checked on every probe report; keep the log to once
// per window instead of spamming each probe.
static const NSTimeInterval kNativePlayerDismissSuppressionLogInterval = 10.0;

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

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
// ForceNativePresentOnPlay: deferred retry state while a launch modal is up.
@property (nonatomic) BOOL forceNativePresentRetryPending;
@property (nonatomic) NSUInteger forceNativePresentRetryAttempt;
// CFAbsoluteTimeGetCurrent of the latest native-player dismissal / "Keep
// playing here" choice; opens the auto-fullscreen suppression window.
@property (nonatomic) NSTimeInterval lastNativePlayerDismissUptime;
// Rate limiter for the "suppressed after dismissal" log (probe reports
// arrive every couple of seconds inside the window).
@property (nonatomic) NSTimeInterval lastDismissSuppressionLogUptime;
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleNativeVideoPlayerDidDismissNotification:)
                                                 name:kBrowserNativeVideoPlayerDidDismissNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleTestForceSecondPresentNotification:)
                                                 name:kBrowserTestForceSecondPresentNotification
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
        // Asking for no launch hints covers the support screen too; the menu's
        // "Support Nebula" entry is unaffected.
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DontShowHintsOnLaunch"]) {
            return;
        }
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
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self applyExitPrivacyActions];
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self hidePrivacyCover];
}

// The native player's view disappeared (Menu dismissal, close, ...): open the
// auto-fullscreen suppression window so the embed watchdog's iframe reload
// cannot immediately re-present the player the user just dismissed.
- (void)handleNativeVideoPlayerDidDismissNotification:(NSNotification *)notification {
    (void)notification;
    self.lastNativePlayerDismissUptime = CFAbsoluteTimeGetCurrent();
}

// Test-only path (kBrowserTestForceSecondPresentNotification): re-present the
// native player from the media probes. Deliberately no modal guard: an
// automated run schedules this right after a dismissal to exercise a second
// presentation, so any alert/modal in the way must not block it. The run
// drives this after the player just played (probe silenced while the native
// player owns playback), so accept probes up to 600s old like a user hold.
- (void)handleTestForceSecondPresentNotification:(NSNotification *)notification {
    (void)notification;
    [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbesSilentlyAllowingReportAge:600.0];
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

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:[self.remoteInputController cursorAimPoint]
                                                        inView:self.view
                                                       webView:self.webview];
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

    [alertController addAction:[UIAlertAction actionWithTitle:[self popupBlockerToggleTitle]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self togglePopupBlockerPreference];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:[self autoFullscreenPromptToggleTitle]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self toggleAutoFullscreenPromptPreference];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:[self nativeVideoModeToggleTitle]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self toggleNativeVideoModePreference];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:[self autoFullscreenToggleTitle]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self toggleAutoFullscreenPreference];
    }]];

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

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
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
    // Cursor path first (unchanged behavior); when it finds nothing playable
    // under the cursor, fall back to the per-frame media probes so videos
    // inside cross-origin player iframes can still be reached.
    if (![self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable]) {
        [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbes];
    }
}

#pragma mark - Popup blocker / auto-fullscreen prompt toggles

// Both toggles flip (default-NO) NSUserDefaults keys read when a web view is
// created, so they apply to pages opened from now on; the confirmation alert
// makes that scope explicit on the TV (no way to see a settings checkmark).
- (NSString *)popupBlockerToggleTitle {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"PopupBlockerDisabled"] ? @"Popup Blocker Off" : @"Popup Blocker On";
}

- (NSString *)autoFullscreenPromptToggleTitle {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"NativeAutoFullscreenPromptDisabled"] ? @"Auto Fullscreen Prompt Off" : @"Auto Fullscreen Prompt On";
}

// Native Video Mode (default ON): MSE is killed so embeds fall back to a
// native <video src=m3u8> AVPlayer can play. Turning it OFF re-enables MSE
// and needs a fresh web view, so it goes through the same recreate flow the
// User-Agent toggle uses.
- (NSString *)nativeVideoModeToggleTitle {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"NativeVideoModeDisabled"] ? @"Native Video Mode Off" : @"Native Video Mode On";
}

// With Native Video Mode on, an embed video that starts playing is taken
// over by the native player automatically; this toggle suppresses that.
- (NSString *)autoFullscreenToggleTitle {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"NativeAutoFullscreenDisabled"] ? @"Auto Fullscreen Off" : @"Auto Fullscreen On";
}

- (void)togglePopupBlockerPreference {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL disabled = ![defaults boolForKey:@"PopupBlockerDisabled"];
    [defaults setBool:disabled forKey:@"PopupBlockerDisabled"];
    [defaults synchronize];
    [self presentToggleConfirmationMessage:[NSString stringWithFormat:@"Popup Blocker is now %@. It applies to pages opened from now on.", disabled ? @"OFF" : @"ON"]];
}

- (void)toggleAutoFullscreenPromptPreference {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL disabled = ![defaults boolForKey:@"NativeAutoFullscreenPromptDisabled"];
    [defaults setBool:disabled forKey:@"NativeAutoFullscreenPromptDisabled"];
    [defaults synchronize];
    [self presentToggleConfirmationMessage:[NSString stringWithFormat:@"Auto Fullscreen Prompt is now %@. It applies to pages opened from now on.", disabled ? @"OFF" : @"ON"]];
}

- (void)toggleNativeVideoModePreference {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL disabled = ![defaults boolForKey:@"NativeVideoModeDisabled"];
    [defaults setBool:disabled forKey:@"NativeVideoModeDisabled"];
    [defaults synchronize];
    if (disabled && self.webview != nil) {
        // MSE comes back with the mode off: rebuild the web view (the same
        // flow the User-Agent toggle uses) so the new media preferences and
        // user scripts apply to the current page right away.
        [self.tabCoordinator captureSnapshotForCurrentTab];
        [self browserRecreateActiveWebViewPreservingCurrentURL];
        [self browserBringCursorToFront];
    }
    else {
        [self presentToggleConfirmationMessage:[NSString stringWithFormat:@"Native Video Mode is now %@. It applies to pages opened from now on.", disabled ? @"OFF" : @"ON"]];
    }
}

- (void)toggleAutoFullscreenPreference {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL disabled = ![defaults boolForKey:@"NativeAutoFullscreenDisabled"];
    [defaults setBool:disabled forKey:@"NativeAutoFullscreenDisabled"];
    [defaults synchronize];
    [self presentToggleConfirmationMessage:[NSString stringWithFormat:@"Auto Fullscreen is now %@. It applies to pages opened from now on.", disabled ? @"OFF" : @"ON"]];
}

- (void)presentToggleConfirmationMessage:(NSString *)message {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Nebula Browser"
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
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

- (BOOL)browserRemoteInputControllerFullscreenVideoAtCursor {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return NO;
    }
    CGPoint domPoint = [self browserDOMPointForCursor];
    if (domPoint.y < 0) {
        return NO; // cursor is over the top bar, not the page
    }
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
    NSString *result = [self.webview stringByEvaluatingJavaScriptFromString:script];
    return [result isEqualToString:@"true"];
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

// Single Play/Pause press: WebKit pauses the page video on the first press and
// it never resumes, so toggle the largest visible <video> (top document and
// same-origin iframes) both ways. With a native video player presented the
// press belongs to it: existing behavior untouched. When no video is found or
// toggled the legacy press behavior (search box / alert dismiss) runs.
- (BOOL)browserRemoteInputControllerHandlePlayPauseToggleInPageVideo {
    UIViewController *presented = self.presentedViewController;
    if (presented != nil) {
        // Native player on screen: its own transport handles Play/Pause.
        // Any other modal (alerts, ...) keeps the legacy press behavior.
        return [presented isKindOfClass:[BrowserNativeVideoPlayerViewController class]];
    }

    static NSString *const kToggleLargestVideoScript =
        @"(function(){"
        "function bestVisibleVideo(doc){"
            "var best=null;var bestArea=-1;"
            "try{"
                "var vids=doc.querySelectorAll('video');"
                "for(var i=0;i<vids.length;i++){"
                    "var v=vids[i];"
                    "try{"
                        "var r=v.getBoundingClientRect();"
                        "var w=r.width||0;var h=r.height||0;"
                        "if(w<2||h<2){continue;}"
                        "var area=w*h;"
                        "if(area>bestArea){bestArea=area;best={video:v,area:area};}"
                    "}catch(e){}"
                "}"
            "}catch(e){}"
            "return best;"
        "}"
        "var best=bestVisibleVideo(document);"
        "try{"
            "var frames=document.querySelectorAll('iframe,frame');"
            "for(var f=0;f<frames.length;f++){"
                "try{"
                    // Cross-origin frames throw on contentDocument access:
                    // the catch keeps us on same-origin frames only.
                    "var d=frames[f].contentDocument;"
                    "if(!d||!d.querySelectorAll){continue;}"
                    "var inner=bestVisibleVideo(d);"
                    "if(inner&&(best===null||inner.area>best.area)){best=inner;}"
                "}catch(e){}"
            "}"
        "}catch(e){}"
        "if(best===null){return false;}"
        "var v=best.video;"
        "try{"
            "if(v.ended===false&&v.paused===true){"
                "var p=v.play();"
                "if(p&&p.catch){p.catch(function(){});}"
                "return true;"
            "}"
            "if(v.paused===false){v.pause();return true;}"
        "}catch(e){}"
        "return false;"
        "})()";

    __weak typeof(self) weakSelf = self;
    [self.webview evaluateJavaScriptStringAsync:kToggleLargestVideoScript completion:^(id result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            BOOL handled = [result isKindOfClass:[NSNumber class]] && [(NSNumber *)result boolValue];
            if (!handled) {
                // No video to toggle: run the legacy press behavior now.
                [strongSelf browserRemoteInputControllerHandlePlayPausePress];
            }
        });
    }];
    return YES;
}

// Hold (long-press) Play/Pause: Tanghulu-style native takeover of the best
// video the page's frames reported (see BrowserVideoPlaybackCoordinator).
- (void)browserRemoteInputControllerHandlePlayPauseHold {
    // With a modal up (player, alerts, ...) the press belongs to it.
    if (self.presentedViewController != nil) {
        return;
    }
    [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbes];
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    [self showAdvancedMenu];
}

- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point {
    // Reflect hover over the top bar (cursor mode) as a button glow.
    CGPoint topBarPoint = [self.view convertPoint:point toView:self.topMenuView];
    CGPoint webPointForBar = [self.view convertPoint:point toView:self.webview];
    if (webPointForBar.y < 0) {
        [self.topMenuView updateCursorHoverAtPoint:topBarPoint];
    } else {
        [self.topMenuView clearCursorHover];
    }

    if (self.webview.request == nil) {
        return @"false";
    }
    CGPoint webPoint = [self.view convertPoint:point toView:self.webview];
    if (webPoint.y < 0) {
        return @"false";
    }
    CGPoint domPoint = [self browserDOMPointForCursor];
    return [self.pageActionCoordinator hoverStateAtDOMPoint:domPoint webView:self.webview];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

// Whether `host` is `potentialParent` itself or a subdomain of it
// (case-insensitive textual descendant). An empty side is never a match.
static BOOL BrowserHostIsTextualDescendantOfHost(NSString *host, NSString *potentialParent) {
    if (host.length == 0 || potentialParent.length == 0) {
        return NO;
    }
    NSString *lowercaseHost = host.lowercaseString;
    NSString *lowercaseParent = potentialParent.lowercaseString;
    return [lowercaseHost isEqualToString:lowercaseParent] ||
           [lowercaseHost hasSuffix:[@"." stringByAppendingString:lowercaseParent]];
}

// New-tab requests (window.open/target=_blank the popup blocker allowed) ask
// the user first: the alert opens the tab itself, so the page's own play
// button can no longer navigate away silently.
- (BOOL)webView:(id)webView wantsConfirmationForNewTabRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    if (self.presentedViewController != nil) {
        // A modal already owns the screen: no alert possible, fall back to
        // the unconfirmed new-tab flow.
        return NO;
    }

    NSString *message = request.URL.absoluteString ?: @"";
    if (message.length > 120) {
        message = [message substringToIndex:120];
    }
    // Cross-site main-frame popups (target host not a textual descendant of
    // the opener page's host) keep the same prompt with an ad warning.
    if (!BrowserHostIsTextualDescendantOfHost(request.URL.host, self.webview.request.URL.host)) {
        message = [@"Possible ad pop-up: " stringByAppendingString:message];
    }
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Open in new tab?"
                                                                            message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Stay on this page"
                                                         style:UIAlertActionStyleCancel
                                                       handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Open in new tab"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        // Same tab-opening flow the handledInTab path uses.
        [weakSelf.tabCoordinator createNewTabWithRequest:request];
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
    return YES;
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

// A streameast-type embed's video started playing in the page. In Native
// Video Mode (default) take over immediately with the native player — no
// alert — unless NativeAutoFullscreenDisabled is set; then (or with the mode
// off) fall back to the legacy confirmation prompt, itself suppressed via
// NativeAutoFullscreenPromptDisabled. Skipped while a player or modal already
// owns the screen — the manual hold-to-enter path on Play/Pause is unchanged
// either way.
- (void)webView:(id)webView didDetectPlayingEmbedVideoReport:(NSDictionary *)report {
    (void)webView;
    (void)report;
    // Dismissal suppression window: any user dismissal (Menu on the native
    // player, "Keep playing here") ends auto-presentation for this embed for
    // a long window; the embed watchdog replays the iframe within seconds.
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval elapsedSinceDismissal = now - self.lastNativePlayerDismissUptime;
    if (self.lastNativePlayerDismissUptime > 0.0 &&
        elapsedSinceDismissal < kNativePlayerDismissSuppressionInterval) {
        if (now - self.lastDismissSuppressionLogUptime >= kNativePlayerDismissSuppressionLogInterval) {
            self.lastDismissSuppressionLogUptime = now;
            NSLog(@"[NativeVideoPlayer] auto-fullscreen suppressed after dismissal (%ld s remaining)",
                  (long)llround(kNativePlayerDismissSuppressionInterval - elapsedSinceDismissal));
        }
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL autoFullscreenEnabled = ![defaults boolForKey:@"NativeVideoModeDisabled"] &&
                                 ![defaults boolForKey:@"NativeAutoFullscreenDisabled"];
    if (autoFullscreenEnabled) {
        if (self.presentedViewController != nil) {
            return;
        }
        // Silent variant: with only a blob:/MSE src and no captured playlist
        // there is nothing AVPlayer can open, so no-op instead of alerting.
        NSLog(@"[NativeVideoPlayer] auto-fullscreen: presenting native player for embed video");
        [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbesSilently];
        return;
    }
    if ([defaults boolForKey:@"NativeAutoFullscreenPromptDisabled"]) {
        return;
    }
    if (self.presentedViewController != nil) {
        return;
    }
    if ([defaults boolForKey:@"ForceNativePresentOnPlay"]) {
        // Unattended force-native-present runs: this very alert would count as
        // a modal and stall the force-retry loop ("modal up"), so skip it and
        // perform the "Play full screen" action directly. That action is
        // inherently deferred (it hops to the next main-queue turn to present),
        // and if a modal is up at that point the existing force-retry loop
        // performs the presentation itself.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbes];
        });
        return;
    }
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Live video detected"
                                                                              message:@"Play full screen?"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
    // Default (focused) action keeps playback in the page: record the same
    // dismissal timestamp (opens the suppression window so the auto path
    // can't immediately counteract the user's choice) and resume the video
    // the page paused while our alert had focus.
    [alertController addAction:[UIAlertAction actionWithTitle:@"Keep playing here"
                                                         style:UIAlertActionStyleCancel
                                                       handler:^(__unused UIAlertAction *action) {
        self.lastNativePlayerDismissUptime = CFAbsoluteTimeGetCurrent();
        [self resumeLargestVisiblePageVideo];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Play full screen"
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbes];
        });
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
}

// "Keep playing here": the page paused its own video while our alert had
// focus and never resumes it. Find the largest visible <video> (top document
// and same-origin iframes, the media probes' selection convention) and call
// play() when it sits paused. Fire-and-forget: no new UI.
- (void)resumeLargestVisiblePageVideo {
    static NSString *const kResumeLargestVideoScript =
        @"(function(){"
        "function bestVisibleVideo(doc){"
            "var best=null;var bestArea=-1;"
            "try{"
                "var vids=doc.querySelectorAll('video');"
                "for(var i=0;i<vids.length;i++){"
                    "var v=vids[i];"
                    "try{"
                        "var r=v.getBoundingClientRect();"
                        "var w=r.width||0;var h=r.height||0;"
                        "if(w<2||h<2){continue;}"
                        "var area=w*h;"
                        "if(area>bestArea){bestArea=area;best={video:v,area:area};}"
                    "}catch(e){}"
                "}"
            "}catch(e){}"
            "return best;"
        "}"
        "var best=bestVisibleVideo(document);"
        "try{"
            "var frames=document.querySelectorAll('iframe,frame');"
            "for(var f=0;f<frames.length;f++){"
                "try{"
                    // Cross-origin frames throw on contentDocument access:
                    // the catch keeps us on same-origin frames only.
                    "var d=frames[f].contentDocument;"
                    "if(!d||!d.querySelectorAll){continue;}"
                    "var inner=bestVisibleVideo(d);"
                    "if(inner&&(best===null||inner.area>best.area)){best=inner;}"
                "}catch(e){}"
            "}"
        "}catch(e){}"
        "if(best===null){return false;}"
        "var v=best.video;"
        "try{"
            "if(v.paused===true&&v.ended===false){"
                "var p=v.play();"
                "if(p&&p.catch){p.catch(function(){});}"
                "return true;"
            "}"
        "}catch(e){}"
        "return false;"
        "})()";
    [self.webview evaluateJavaScriptStringAsync:kResumeLargestVideoScript];
}

// ForceNativePresentOnPlay (default-NO launch flag, reported by the web view
// once per document when a probe first shows a playing video): auto-present
// the native fullscreen player through the same entry point the Play/Pause
// HOLD takeover uses, so unattended test runs exercise native presentation.
- (void)webViewWantsForcedNativePresentation:(id)webView {
    (void)webView;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"ForceNativePresentOnPlay"]) {
        return;
    }
    if (self.presentedViewController == nil) {
        [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbes];
        return;
    }
    // A launch modal (the "Support Nebula Browser" donate screen among them)
    // routinely covers the page at this exact moment, and the flag fires once
    // per document, so returning here would drop the presentation for good.
    if (self.forceNativePresentRetryPending == NO) {
        self.forceNativePresentRetryAttempt = 0;
        [self scheduleForcedNativePresentationRetry];
    }
}

// Retry a deferred forced presentation until it lands or the attempt cap is
// reached. Uses the coordinator's silent variant so an attempt that finds only
// a blob:/MSE src with no captured playlist never stacks a "Native Video
// Unavailable" alert. This is the Play/Pause HOLD path: the probe script is
// silent while the native player plays, so accept probes up to 600s old.
- (void)scheduleForcedNativePresentationRetry {
    self.forceNativePresentRetryPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kForceNativePresentRetryInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
        self.forceNativePresentRetryAttempt += 1;
        BOOL presented = NO;
        if (self.presentedViewController != nil) {
            NSLog(@"force-native-present deferred (modal up), retry %lu",
                  (unsigned long)self.forceNativePresentRetryAttempt);
        } else {
            presented = [self.videoPlaybackCoordinator presentNativePlayerFromMediaProbesSilentlyAllowingReportAge:600.0];
        }
        if (presented || self.forceNativePresentRetryAttempt >= kForceNativePresentMaxRetries) {
            self.forceNativePresentRetryPending = NO;
            self.forceNativePresentRetryAttempt = 0;
            return;
        }
        [self scheduleForcedNativePresentationRetry];
    });
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
