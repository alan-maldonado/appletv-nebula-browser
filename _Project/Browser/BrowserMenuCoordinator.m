#import "BrowserMenuCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"

#import <objc/message.h>
#import <objc/runtime.h>

// setAlternateIconName: presents a system "You have changed the icon" alert that
// can't be disabled by API. While this flag is set (briefly around an icon
// change), swallow UIAlertController presentations so that alert never appears.
static BOOL sBrowserSuppressIconChangeAlert = NO;

@implementation UIViewController (BrowserIconAlertSuppression)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(presentViewController:animated:completion:));
        Method replacement = class_getInstanceMethod(self, @selector(browser_presentViewController:animated:completion:));
        if (original != NULL && replacement != NULL) {
            method_exchangeImplementations(original, replacement);
        }
    });
}

- (void)browser_presentViewController:(UIViewController *)viewControllerToPresent
                             animated:(BOOL)animated
                           completion:(void (^)(void))completion {
    if (sBrowserSuppressIconChangeAlert && [viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        NSLog(@"[Theme] suppressed icon-change system alert");
        if (completion != nil) {
            completion();
        }
        return;
    }
    [self browser_presentViewController:viewControllerToPresent animated:animated completion:completion];
}

@end

static UIColor *MenuTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

static NSString * const kBrowserMediaDiagnosticsLogPrefix = @"[MediaDiagnostics]";
static NSString * const kBrowserWebKitMediaPrefsLogPrefix = @"[WebKitMediaPrefs]";

typedef void (^BrowserAdvancedMenuItemHandler)(void);
// Adjustable settings: applies a left(-1)/right(+1) change in place and returns
// the row's new title — without dismissing the menu.
typedef NSString * _Nullable (^BrowserAdvancedMenuItemAdjustHandler)(NSInteger direction);

@interface BrowserAdvancedMenuItem : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic) UIAlertActionStyle style;
@property (nonatomic, copy) BrowserAdvancedMenuItemHandler handler;
@property (nonatomic, copy) BrowserAdvancedMenuItemAdjustHandler adjustHandler;
// Optional: name of an image to preview beside the menu while this row is
// focused (re-queried after every adjustment).
@property (nonatomic, copy) NSString * _Nullable (^previewImageNameProvider)(void);
// Optional: explanatory text shown beside the menu while this row is focused.
@property (nonatomic, copy) NSString *explanation;

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler;

@end

@implementation BrowserAdvancedMenuItem

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler {
    BrowserAdvancedMenuItem *item = [BrowserAdvancedMenuItem new];
    item.title = title ?: @"";
    item.style = style;
    item.handler = handler;
    return item;
}

@end

@interface BrowserAdvancedMenuSection : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuItem *> *items;

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items;

@end

@implementation BrowserAdvancedMenuSection

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items {
    BrowserAdvancedMenuSection *section = [BrowserAdvancedMenuSection new];
    section.title = title ?: @"";
    section.items = [items copy] ?: @[];
    return section;
}

@end

@interface BrowserAdvancedMenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText;

@end

@interface BrowserAdvancedMenuViewController ()

@property (nonatomic, copy) NSString *menuTitle;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuSection *> *sections;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) NSLayoutConstraint *panelTrailingConstraint;
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) BOOL didAnimateIn;
@property (nonatomic) BOOL dismissalInProgress;
@property (nonatomic) BOOL usingNativeGlassEffect;
@property (nonatomic) UIImageView *previewImageView;
@property (nonatomic) UIVisualEffectView *explanationCardView;
@property (nonatomic) UILabel *explanationLabel;

@end

@implementation BrowserAdvancedMenuViewController

- (UIVisualEffect *)panelEffect {
    Class glassEffectClass = NSClassFromString(@"UIGlassEffect");
    if (glassEffectClass != Nil) {
        id effect = [[glassEffectClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
}

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _menuTitle = [title copy] ?: @"Menu";
        _sections = [sections copy] ?: @[];
        _footerText = [footerText copy] ?: @"";
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.38, 480.0), 700.0);
    self.usingNativeGlassEffect = (NSClassFromString(@"UIGlassEffect") != Nil);

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    dimView.alpha = 0.0;
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[self panelEffect]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.backgroundColor = UIColor.clearColor;
    panelView.layer.cornerRadius = 28.0;
    panelView.layer.masksToBounds = YES;
    panelView.layer.borderWidth = self.usingNativeGlassEffect ? 0.0 : 1.0;
    panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    [self.view addSubview:panelView];
    self.panelView = panelView;

    UIView *panelTint = [UIView new];
    panelTint.translatesAutoresizingMaskIntoConstraints = NO;
    panelTint.backgroundColor = self.usingNativeGlassEffect ? [UIColor colorWithWhite:0.0 alpha:0.4] : [UIColor colorWithWhite:0.0 alpha:0.55];
    [panelView.contentView addSubview:panelTint];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.menuTitle;
    titleLabel.font = [UIFont boldSystemFontOfSize:34.0];
    titleLabel.textAlignment = NSTextAlignmentLeft;
    titleLabel.textColor = UIColor.whiteColor;
    [panelView.contentView addSubview:titleLabel];

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(tvOS 13.0, *)) {
        separator.backgroundColor = UIColor.separatorColor;
    } else {
        separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
    [panelView.contentView addSubview:separator];

    UILabel *footerLabel = [UILabel new];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.text = self.footerText;
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    [panelView.contentView addSubview:footerLabel];

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.rowHeight = 68.0;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.preservesSuperviewLayoutMargins = NO;
    tableView.layoutMargins = UIEdgeInsetsZero;
    if (@available(tvOS 11.0, *)) {
        tableView.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
        tableView.insetsLayoutMarginsFromSafeArea = NO;
    }
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.clipsToBounds = NO;
    tableView.layer.cornerRadius = 0.0;
    tableView.remembersLastFocusedIndexPath = YES;
    tableView.contentInset = UIEdgeInsetsZero;
    tableView.showsVerticalScrollIndicator = NO;
    if (@available(tvOS 11.0, *)) {
        tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        tableView.insetsContentViewsToSafeArea = NO;
    }
    [panelView.contentView addSubview:tableView];
    self.tableView = tableView;

    self.panelTrailingConstraint = [panelView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                                                             constant:self.panelWidth + 32.0];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0],
        [panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0],
        self.panelTrailingConstraint,

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:32.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-32.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.topAnchor constant:26.0],

        [separator.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:20.0],
        [separator.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-20.0],
        [separator.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:20.0],
        [separator.heightAnchor constraintEqualToConstant:1.0],

        [tableView.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:12.0],
        [tableView.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:16.0],
        [tableView.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-16.0],
        [tableView.bottomAnchor constraintEqualToAnchor:footerLabel.topAnchor constant:-8.0],

        [footerLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:24.0],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-24.0],
        [footerLabel.bottomAnchor constraintEqualToAnchor:panelView.bottomAnchor constant:-12.0],
    ]];
    if (panelTint != nil) {
        [constraints addObject:[panelTint.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor]];
        [constraints addObject:[panelTint.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor]];
        [constraints addObject:[panelTint.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor]];
        [constraints addObject:[panelTint.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAnimateIn) {
        return;
    }
    self.didAnimateIn = YES;
    self.panelTrailingConstraint.constant = -16.0;
    [UIView animateWithDuration:0.28
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.dimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (!self.isBeingDismissed || self.dismissalInProgress) {
        return;
    }

    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator != nil) {
        [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimView.alpha = 0.0;
            [self.view layoutIfNeeded];
        } completion:nil];
        return;
    }

    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)dismissMenuWithCompletion:(void (^)(void))completion {
    if (self.dismissalInProgress) {
        return;
    }
    self.dismissalInProgress = YES;
    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return 0;
    }
    return (NSInteger)self.sections[(NSUInteger)section].items.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return nil;
    }
    return self.sections[(NSUInteger)section].title;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kCellIdentifier = @"BrowserAdvancedMenuCell";
    static NSInteger const kMenuTitleLabelTag = 9191;
    static NSInteger const kMenuFocusBackgroundTag = 9292;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.clipsToBounds = NO;
        cell.contentView.clipsToBounds = NO;
        cell.preservesSuperviewLayoutMargins = NO;
        cell.layoutMargins = UIEdgeInsetsZero;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell respondsToSelector:@selector(setFocusStyle:)]) {
            [cell setValue:@(1) forKey:@"focusStyle"]; // UITableViewCellFocusStyleCustom
        }

        UIView *focusBackgroundView = [UIView new];
        focusBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
        focusBackgroundView.tag = kMenuFocusBackgroundTag;
        focusBackgroundView.layer.cornerRadius = 12.0;
        focusBackgroundView.layer.borderWidth = 2.0;
        focusBackgroundView.alpha = 0.0;
        [cell.contentView addSubview:focusBackgroundView];

        UILabel *titleLabel = [UILabel new];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.tag = kMenuTitleLabelTag;
        titleLabel.font = [UIFont systemFontOfSize:31.0 weight:UIFontWeightRegular];
        titleLabel.textAlignment = NSTextAlignmentLeft;
        titleLabel.numberOfLines = 1;
        [cell.contentView addSubview:titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [focusBackgroundView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:0.0],
            [focusBackgroundView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:0.0],
            [focusBackgroundView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:2.0],
            [focusBackgroundView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-2.0],

            [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:24.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-24.0],
            [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    UILabel *titleLabel = (UILabel *)[cell.contentView viewWithTag:kMenuTitleLabelTag];
    UIView *focusBackgroundView = [cell.contentView viewWithTag:kMenuFocusBackgroundTag];
    titleLabel.text = [self displayTitleForItem:item];
    UIColor *titleColor = (item.style == UIAlertActionStyleDestructive) ? UIColor.redColor : UIColor.whiteColor;
    titleLabel.textColor = titleColor;
    // Re-apply the accent every time (cells are reused): keeps all rows in sync
    // with the current theme even after scrolling.
    UIColor *accentColor = [[BrowserPreferencesStore new] themeAccentColor];
    focusBackgroundView.backgroundColor = [accentColor colorWithAlphaComponent:0.5];
    focusBackgroundView.layer.borderColor = [accentColor colorWithAlphaComponent:0.9].CGColor;
    focusBackgroundView.alpha = cell.isFocused ? 1.0 : 0.0;
    return cell;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *previousIndexPath = context.previouslyFocusedIndexPath;
    NSIndexPath *nextIndexPath = context.nextFocusedIndexPath;

    UITableViewCell *previousCell = previousIndexPath ? [tableView cellForRowAtIndexPath:previousIndexPath] : nil;
    UITableViewCell *nextCell = nextIndexPath ? [tableView cellForRowAtIndexPath:nextIndexPath] : nil;

    [coordinator addCoordinatedAnimations:^{
        UIView *previousFocusBackground = [previousCell.contentView viewWithTag:9292];
        previousFocusBackground.alpha = 0.0;

        UIView *nextFocusBackground = [nextCell.contentView viewWithTag:9292];
        nextFocusBackground.alpha = 1.0;
    } completion:nil];

    [self updatePreviewForItemAtIndexPath:nextIndexPath];
}

// Floating preview card (left of the panel) for rows that provide one, e.g. the
// theme row showing the app icon that will be applied.
- (void)updatePreviewForItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserAdvancedMenuItem *item = nil;
    if (indexPath != nil &&
        (NSUInteger)indexPath.section < self.sections.count &&
        (NSUInteger)indexPath.row < self.sections[(NSUInteger)indexPath.section].items.count) {
        item = self.sections[(NSUInteger)indexPath.section].items[(NSUInteger)indexPath.row];
    }

    [self updateExplanationForItem:item];

    NSString *imageName = item.previewImageNameProvider != nil ? item.previewImageNameProvider() : nil;
    UIImage *previewImage = imageName.length > 0 ? [UIImage imageNamed:imageName] : nil;
    if (previewImage == nil) {
        [UIView animateWithDuration:0.2 animations:^{
            self.previewImageView.alpha = 0.0;
        }];
        return;
    }

    if (self.previewImageView == nil) {
        UIImageView *imageView = [[UIImageView alloc] init];
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.layer.cornerRadius = 18.0;
        imageView.layer.masksToBounds = YES;
        imageView.layer.borderWidth = 1.0;
        imageView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        imageView.alpha = 0.0;
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view insertSubview:imageView belowSubview:self.panelView];
        [NSLayoutConstraint activateConstraints:@[
            [imageView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [imageView.centerXAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:560.0],
            [imageView.widthAnchor constraintEqualToConstant:560.0],
            [imageView.heightAnchor constraintEqualToConstant:336.0],
        ]];
        self.previewImageView = imageView;
    }

    self.previewImageView.image = previewImage;
    [UIView animateWithDuration:0.2 animations:^{
        self.previewImageView.alpha = 1.0;
    }];
}

// Explanatory card (left of the menu) for rows that carry an explanation.
- (void)updateExplanationForItem:(BrowserAdvancedMenuItem *)item {
    NSString *text = item.explanation;
    if (text.length == 0) {
        [UIView animateWithDuration:0.2 animations:^{
            self.explanationCardView.alpha = 0.0;
        }];
        return;
    }

    if (self.explanationCardView == nil) {
        UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.layer.cornerRadius = 24.0;
        card.layer.masksToBounds = YES;
        card.alpha = 0.0;
        [self.view insertSubview:card belowSubview:self.panelView];

        UIView *tint = [[UIView alloc] init];
        tint.translatesAutoresizingMaskIntoConstraints = NO;
        tint.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        [card.contentView addSubview:tint];

        // Theme-colored accent bar down the left edge.
        UIView *accentBar = [[UIView alloc] init];
        accentBar.translatesAutoresizingMaskIntoConstraints = NO;
        accentBar.backgroundColor = [[BrowserPreferencesStore new] themeAccentColor];
        [card.contentView addSubview:accentBar];

        UILabel *heading = [[UILabel alloc] init];
        heading.translatesAutoresizingMaskIntoConstraints = NO;
        heading.text = @"ABOUT THIS SETTING";
        heading.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
        heading.textColor = [[BrowserPreferencesStore new] themeAccentColor];
        [card.contentView addSubview:heading];

        UILabel *label = [[UILabel alloc] init];
        label.numberOfLines = 0;
        label.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightRegular];
        label.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [card.contentView addSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [tint.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
            [tint.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
            [tint.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
            [tint.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],

            [accentBar.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
            [accentBar.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
            [accentBar.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
            [accentBar.widthAnchor constraintEqualToConstant:6.0],

            [heading.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:34.0],
            [heading.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:36.0],
            [heading.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-32.0],

            [label.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:16.0],
            [label.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:36.0],
            [label.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-32.0],
            [label.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-34.0],
        ]];

        [NSLayoutConstraint activateConstraints:@[
            [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:90.0],
            [card.widthAnchor constraintEqualToConstant:600.0],
        ]];
        self.explanationCardView = card;
        self.explanationLabel = label;
    }

    self.explanationLabel.text = text;
    [UIView animateWithDuration:0.2 animations:^{
        self.explanationCardView.alpha = 1.0;
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    if (item.adjustHandler != nil) {
        // Adjustable settings cycle in place; the menu stays open.
        [self adjustItemAtIndexPath:indexPath direction:1];
        return;
    }
    BrowserAdvancedMenuItemHandler handler = item.handler;
    [self dismissMenuWithCompletion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.tableView];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self dismissMenuWithCompletion:nil];
        return;
    }
    if (press != nil && (press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow)) {
        if ([self adjustFocusedItemInDirection:(press.type == UIPressTypeRightArrow ? 1 : -1)]) {
            return;
        }
    }
    [super pressesEnded:presses withEvent:event];
}

// Adjustable rows are flagged with ‹ › so users know Left/Right changes them.
- (NSString *)displayTitleForItem:(BrowserAdvancedMenuItem *)item {
    return item.adjustHandler != nil ? [NSString stringWithFormat:@"‹ %@ ›", item.title] : item.title;
}

// Left/right on an adjustable row changes the setting in place (the menu stays
// open so the change is visible immediately).
- (BOOL)adjustFocusedItemInDirection:(NSInteger)direction {
    NSIndexPath *focusedIndexPath = nil;
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (cell.isFocused) {
            focusedIndexPath = indexPath;
            break;
        }
    }
    if (focusedIndexPath == nil) {
        return NO;
    }
    return [self adjustItemAtIndexPath:focusedIndexPath direction:direction];
}

- (BOOL)adjustItemAtIndexPath:(NSIndexPath *)indexPath direction:(NSInteger)direction {
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    if (item.adjustHandler == nil) {
        return NO;
    }

    NSString *newTitle = item.adjustHandler(direction);
    if (newTitle.length > 0) {
        item.title = newTitle;
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        UILabel *titleLabel = (UILabel *)[cell.contentView viewWithTag:9191];
        titleLabel.text = [self displayTitleForItem:item];
    }
    [self refreshAccentColorsOnVisibleCells];
    [self updatePreviewForItemAtIndexPath:indexPath];
    return YES;
}

// Live theme preview: re-tint the focus highlights of the cells already on
// screen (they are colored at creation time otherwise).
- (void)refreshAccentColorsOnVisibleCells {
    UIColor *accentColor = [[BrowserPreferencesStore new] themeAccentColor];
    [UIView animateWithDuration:0.2 animations:^{
        for (UITableViewCell *cell in self.tableView.visibleCells) {
            UIView *focusBackgroundView = [cell.contentView viewWithTag:9292];
            focusBackgroundView.backgroundColor = [accentColor colorWithAlphaComponent:0.5];
            focusBackgroundView.layer.borderColor = [accentColor colorWithAlphaComponent:0.9].CGColor;
        }
    }];
}

@end

@interface BrowserMenuCoordinator ()

@property (nonatomic, weak) id<BrowserMenuCoordinatorHost> host;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

@implementation BrowserMenuCoordinator

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _host = host;
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (void)showAdvancedMenu {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    NSString *menuTitle = [self stringHasVisibleContent:version]
        ? [NSString stringWithFormat:@"Nebula Browser %@", version]
        : @"Nebula Browser";
    BrowserAdvancedMenuViewController *menuViewController = [[BrowserAdvancedMenuViewController alloc] initWithTitle:menuTitle
                                                                                                            sections:[self advancedMenuSections]
                                                                                                          footerText:[self advancedMenuFooterText]];
    [self.host browserPresentViewController:menuViewController];
}

- (void)showFavoritesMenu {
    [self presentFavoritesMenu];
}

- (void)showHistoryMenu {
    [self presentHistoryMenu];
}

- (UIAlertController *)browserAlertControllerWithTitle:(NSString *)title message:(NSString *)message {
    return [UIAlertController alertControllerWithTitle:title
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
}

- (UIAlertAction *)browserActionWithTitle:(NSString *)title
                                    style:(UIAlertActionStyle)style
                                  handler:(void (^ __nullable)(UIAlertAction *action))handler {
    return [UIAlertAction actionWithTitle:title style:style handler:handler];
}

- (BrowserAdvancedMenuItem *)advancedMenuItemWithTitle:(NSString *)title
                                                  style:(UIAlertActionStyle)style
                                                handler:(BrowserAdvancedMenuItemHandler)handler {
    return [BrowserAdvancedMenuItem itemWithTitle:title style:style handler:handler];
}

- (UIAlertAction *)browserCancelAction {
    return [self browserActionWithTitle:nil style:UIAlertActionStyleCancel handler:nil];
}

- (BOOL)stringHasVisibleContent:(NSString *)string {
    NSString *trimmedString = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmedString.length > 0;
}

- (NSString *)displayTitleForStoredTitle:(NSString *)storedTitle
                               URLString:(NSString *)URLString
                              includeURL:(BOOL)includeURL {
    NSString *displayTitle = [self stringHasVisibleContent:storedTitle] ? storedTitle : URLString;
    if (includeURL && [self stringHasVisibleContent:storedTitle] && [self stringHasVisibleContent:URLString]) {
        return [NSString stringWithFormat:@"%@ - %@", storedTitle, URLString];
    }
    return displayTitle ?: @"";
}

- (void)loadStoredURLString:(NSString *)URLString {
    if (![self stringHasVisibleContent:URLString]) {
        return;
    }
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    [[self.host browserWebView] loadRequest:request];
}

- (void)saveFavoritesArray:(NSArray *)favorites {
    [[NSUserDefaults standardUserDefaults] setObject:favorites forKey:@"FAVORITES"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)presentDeleteFavoriteMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Delete a Favorite"
                                                                       message:@"Select a Favorite to Delete"];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        if (![weakSelf stringHasVisibleContent:URLString]) {
            return;
        }
        
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            NSMutableArray *updatedFavorites = [favorites mutableCopy];
            [updatedFavorites removeObjectAtIndex:index];
            [weakSelf saveFavoritesArray:updatedFavorites];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentAddFavoritePrompt {
    NSString *pageTitle = [[self.host browserWebView] title];
    NSURLRequest *request = [[self.host browserWebView] request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Name New Favorite"
                                                                       message:currentURL];
    __weak typeof(self) weakSelf = self;
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.placeholder = @"Name New Favorite";
        textField.text = pageTitle;
        textField.textColor = MenuTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];
    
    [alertController addAction:[self browserActionWithTitle:@"Save"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        UITextField *titleTextField = alertController.textFields.firstObject;
        NSString *savedTitle = titleTextField.text;
        if (![weakSelf stringHasVisibleContent:savedTitle]) {
            savedTitle = currentURL;
        }
        
        NSArray *favoriteEntry = @[currentURL, savedTitle ?: @""];
        NSMutableArray *favorites = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"] mutableCopy];
        if (favorites == nil) {
            favorites = [NSMutableArray array];
        }
        [favorites addObject:favoriteEntry];
        [weakSelf saveFavoritesArray:favorites];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Favorites" message:@""];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    if (favorites.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Delete a Favorite"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentDeleteFavoriteMenu];
        }]];
    }
    
    [alertController addAction:[self browserActionWithTitle:@"Add Current Page to Favorites"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentAddFavoritePrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentHistoryMenu {
    NSArray *historyEntries = [[NSUserDefaults standardUserDefaults] arrayForKey:@"HISTORY"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"History" message:@""];
    __weak typeof(self) weakSelf = self;
    
    if (historyEntries.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Clear History"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"HISTORY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];
    }
    
    [historyEntries enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:YES];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)applyUserAgent:(NSString *)userAgent mobileMode:(BOOL)mobileMode {
    self.preferencesStore.userAgent = userAgent;
    self.preferencesStore.mobileModeEnabled = mobileMode;
    
    NSURLRequest *request = [[self.host browserWebView] request];
    if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
        [self.host browserCaptureSnapshotForCurrentTab];
    }
    
    __weak typeof(self) weakSelf = self;
    [BrowserWebView resetWebsiteDataWithCompletion:^{
        [weakSelf.host browserRecreateActiveWebViewPreservingCurrentURL];
        [weakSelf.host browserBringCursorToFront];
    }];
}

- (void)setPageScalingEnabled:(BOOL)enabled {
    self.preferencesStore.scalePagesToFit = enabled;
    [[self.host browserWebView] setScalesPageToFit:enabled];
    if (enabled) {
        [[self.host browserWebView] setContentMode:UIViewContentModeScaleAspectFit];
    }
    [[self.host browserWebView] reload];
}

- (void)clearCacheAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCachedDataWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (void)clearCookiesAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCookiesWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (NSString *)mediaDiagnosticsJavaScript {
    return @"(function(){"
            "function canPlay(type){"
                "try {"
                    "var video=document.createElement('video');"
                    "if (!video || typeof video.canPlayType!=='function') { return 'n/a'; }"
                    "var value=video.canPlayType(type);"
                    "return value ? String(value) : '';"
                "} catch (error) { return 'error'; }"
            "}"
            "function mse(type){"
                "try {"
                    "if (typeof MediaSource==='undefined' || typeof MediaSource.isTypeSupported!=='function') { return 'n/a'; }"
                    "return MediaSource.isTypeSupported(type) ? 'yes' : 'no';"
                "} catch (error) { return 'error'; }"
            "}"
            "function probeGlobal(name){"
                "try {"
                    "var value=window[name];"
                    "if (typeof value==='undefined') { return 'undefined'; }"
                    "if (value === null) { return 'null'; }"
                    "return typeof value;"
                "} catch (error) { return 'error'; }"
            "}"
            "var video=document.querySelector('video');"
            "var result={"
                "href:(window.location && window.location.href) ? String(window.location.href) : '',"
                "title:(document && document.title) ? String(document.title) : '',"
                "userAgent:(navigator && navigator.userAgent) ? String(navigator.userAgent) : '',"
                "platform:(navigator && navigator.platform) ? String(navigator.platform) : '',"
                "mediaSource:(typeof MediaSource!=='undefined') ? 'yes' : 'no',"
                "managedMediaSource:(typeof ManagedMediaSource!=='undefined') ? 'yes' : 'no',"
                "mediaCapabilities:(typeof navigator.mediaCapabilities!=='undefined') ? 'yes' : 'no',"
                "videoElement:video ? 'yes' : 'no',"
                "videoSrc:video ? String(video.currentSrc||video.src||'') : '',"
                "globalMediaSource:probeGlobal('MediaSource'),"
                "globalManagedMediaSource:probeGlobal('ManagedMediaSource'),"
                "globalWebKitMediaSource:probeGlobal('WebKitMediaSource'),"
                "globalSourceBuffer:probeGlobal('SourceBuffer'),"
                "globalManagedSourceBuffer:probeGlobal('ManagedSourceBuffer'),"
                "globalWebKitSourceBuffer:probeGlobal('WebKitSourceBuffer'),"
                "hls:canPlay('application/vnd.apple.mpegurl'),"
                "mp4H264:canPlay('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mp4Hevc:canPlay('video/mp4; codecs=\"hvc1.1.6.L93.B0, mp4a.40.2\"'),"
                "webmVp9:canPlay('video/webm; codecs=\"vp9\"'),"
                "mp4Av1:canPlay('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "webmAv1:canPlay('video/webm; codecs=\"av01.0.05M.08\"'),"
                "mseMp4H264:mse('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mseWebmVp9:mse('video/webm; codecs=\"vp9\"'),"
                "mseMp4Av1:mse('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "mseWebmAv1:mse('video/webm; codecs=\"av01.0.05M.08\"')"
            "};"
            "return JSON.stringify(result);"
           "})()";
}

- (NSDictionary *)mediaDiagnosticsDictionary {
    NSString *resultString = [[self.host browserWebView] stringByEvaluatingJavaScriptFromString:[self mediaDiagnosticsJavaScript]];
    if (![self stringHasVisibleContent:resultString]) {
        return nil;
    }

    NSData *resultData = [resultString dataUsingEncoding:NSUTF8StringEncoding];
    if (resultData == nil) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:resultData options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return object;
}

- (NSString *)stringValueForDiagnosticsKey:(NSString *)key dictionary:(NSDictionary *)dictionary fallback:(NSString *)fallback {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]] && [self stringHasVisibleContent:value]) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *stringValue = [value stringValue];
        if ([self stringHasVisibleContent:stringValue]) {
            return stringValue;
        }
    }
    return fallback;
}

- (void)presentMediaDiagnostics {
    NSDictionary *diagnostics = [self mediaDiagnosticsDictionary];
    if (diagnostics == nil) {
        UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Media Diagnostics"
                                                                           message:@"The page did not return diagnostics data."];
        [alertController addAction:[self browserCancelAction]];
        [self.host browserPresentViewController:alertController];
        return;
    }

    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *message = [NSString stringWithFormat:
                         @"Mode: %@\n"
                          "URL: %@\n"
                          "UA: %@\n\n"
                          "MediaSource: %@\n"
                          "ManagedMediaSource: %@\n"
                          "MediaCapabilities: %@\n"
                          "Video Element: %@\n"
                          "Video Src: %@\n\n"
                          "Global MediaSource: %@\n"
                          "Global ManagedMediaSource: %@\n"
                          "Global WebKitMediaSource: %@\n"
                          "Global SourceBuffer: %@\n"
                          "Global ManagedSourceBuffer: %@\n"
                          "Global WebKitSourceBuffer: %@\n\n"
                          "canPlay HLS: %@\n"
                          "canPlay MP4 H.264: %@\n"
                          "canPlay MP4 HEVC: %@\n"
                          "canPlay WebM VP9: %@\n"
                          "canPlay MP4 AV1: %@\n"
                          "canPlay WebM AV1: %@\n\n"
                          "MSE MP4 H.264: %@\n"
                          "MSE WebM VP9: %@\n"
                          "MSE MP4 AV1: %@\n"
                          "MSE WebM AV1: %@",
                         mobileModeEnabled ? @"Mobile" : @"Desktop",
                         [self stringValueForDiagnosticsKey:@"href" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"userAgent" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"mediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"managedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mediaCapabilities" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoElement" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoSrc" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"globalMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"hls" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Hevc" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmAv1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmAv1" dictionary:diagnostics fallback:@"n/a"]];

    NSLog(@"%@ %@", kBrowserMediaDiagnosticsLogPrefix, message);

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Media Diagnostics"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentWebKitRuntimeMediaPreferences {
    NSString *report = [[self.host browserWebView] runtimeMediaPreferenceReport];
    if (![self stringHasVisibleContent:report]) {
        report = @"No runtime WebKit media preference information was returned.";
    }

    NSLog(@"%@ %@", kBrowserWebKitMediaPrefsLogPrefix, report);

    NSString *message = report;
    if (message.length > 1800) {
        message = [[message substringToIndex:1800] stringByAppendingString:@"\n\nFull report logged to console."];
    }

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"WebKit Media Prefs"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (BrowserAdvancedMenuItem *)topNavigationVisibilityMenuItem {
    NSString *(^titleForState)(BOOL) = ^NSString *(BOOL showing) {
        return showing ? @"Top Navigation Bar: Visible" : @"Top Navigation Bar: Hidden";
    };
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForState(self.host.browserTopMenuShowing)
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        // The bar shows/hides live behind the menu — no confirmation needed.
        if (self.host.browserTopMenuShowing) {
            [self.host browserHideTopNav];
        } else {
            [self.host browserShowTopNav];
        }
        return titleForState(self.host.browserTopMenuShowing);
    };
    item.explanation = @"Show or hide the toolbar at the top of the screen (back, tabs, address bar). When hidden, open this menu by double-tapping Play/Pause.";
    return item;
}

- (BrowserAdvancedMenuItem *)themeMenuItem {
    NSString *(^titleForTheme)(void) = ^NSString * {
        return [NSString stringWithFormat:@"Theme: %@", [[BrowserPreferencesStore new] themeName]];
    };
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForTheme()
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(NSInteger direction) {
        NSUInteger themeCount = [BrowserPreferencesStore themeNames].count;
        NSInteger nextIndex = ((NSInteger)preferencesStore.themeIndex + direction + (NSInteger)themeCount) % (NSInteger)themeCount;
        preferencesStore.themeIndex = (NSUInteger)nextIndex;
        [BrowserMenuCoordinator applyAppIconForCurrentTheme];
        [self.host browserDidChangeTheme];
        return titleForTheme();
    };
    item.previewImageNameProvider = ^NSString * {
        return [NSString stringWithFormat:@"ThemePreview-%@", [[BrowserPreferencesStore new] themeName]];
    };
    return item;
}

// Swap the home screen icon to the theme's variant (Classic = primary icon).
+ (void)applyAppIconForCurrentTheme {
    UIApplication *application = UIApplication.sharedApplication;
    if (![application supportsAlternateIcons]) {
        return;
    }
    BrowserPreferencesStore *preferencesStore = [BrowserPreferencesStore new];
    NSString *iconName = preferencesStore.themeIndex == 0
        ? nil
        : [NSString stringWithFormat:@"AppIcon-%@", preferencesStore.themeName];
    if ((iconName == nil && application.alternateIconName == nil) ||
        [iconName isEqualToString:application.alternateIconName]) {
        return;
    }
    // setAlternateIconName: presents an undismissable system alert; suppress it
    // via the presentViewController swizzle for a short window around the change.
    sBrowserSuppressIconChangeAlert = YES;
    [application setAlternateIconName:iconName completionHandler:^(NSError *error) {
        if (error != nil) {
            NSLog(@"[Theme] setAlternateIconName %@ failed: %@", iconName ?: @"(primary)", error);
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sBrowserSuppressIconChangeAlert = NO;
    });
}

- (BrowserAdvancedMenuItem *)homePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Go To Home Page"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserLoadHomePage];
    }];
}

- (BrowserAdvancedMenuItem *)setCurrentPageAsHomePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Set Current Page As Home Page"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        NSURLRequest *request = [[self.host browserWebView] request];
        if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
            self.preferencesStore.homePageURLString = request.URL.absoluteString;
        }
    }];
}

- (BrowserAdvancedMenuItem *)searchEngineMenuItem {
    NSString *(^titleForEngine)(void) = ^NSString * {
        return [NSString stringWithFormat:@"Search Engine: %@", [[BrowserPreferencesStore new] searchEngineName]];
    };
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForEngine()
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(NSInteger direction) {
        NSUInteger engineCount = [BrowserPreferencesStore searchEngineNames].count;
        NSInteger nextIndex = ((NSInteger)preferencesStore.searchEngineIndex + direction + (NSInteger)engineCount) % (NSInteger)engineCount;
        preferencesStore.searchEngineIndex = (NSUInteger)nextIndex;
        return titleForEngine();
    };
    item.explanation = @"Which search engine to use when you type words instead of a web address in the address bar.";
    return item;
}

- (BrowserAdvancedMenuItem *)supportMenuItem {
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:@"Support Nebula ♥"
                                                              style:UIAlertActionStyleDefault
                                                            handler:^{
        [self.host browserShowDonate];
    }];
    item.explanation = @"Nebula Browser is free and open source. If you'd like to support its ongoing development and help shape new features, this opens a code you can scan to contribute. Thank you!";
    return item;
}

- (BrowserAdvancedMenuItem *)usageGuideMenuItem {
    return [self advancedMenuItemWithTitle:@"Usage Guide"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowHints];
    }];
}

- (BrowserAdvancedMenuItem *)showGuideOnLaunchMenuItem {
    NSString *(^titleForState)(BOOL) = ^NSString *(BOOL showOnLaunch) {
        return showOnLaunch ? @"Show Guide On Launch: On" : @"Show Guide On Launch: Off";
    };
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForState(!preferencesStore.dontShowHintsOnLaunch)
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        preferencesStore.dontShowHintsOnLaunch = !preferencesStore.dontShowHintsOnLaunch;
        return titleForState(!preferencesStore.dontShowHintsOnLaunch);
    };
    return item;
}

- (UIAlertAction *)wkWebViewProofOfConceptAction {
    return [self browserActionWithTitle:@"Open WKWebView PoC"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        Class proofOfConceptControllerClass = NSClassFromString(@"BrowserWKWebViewProofOfConceptViewController");
        UIViewController *viewController = nil;
        if (proofOfConceptControllerClass != Nil) {
            viewController = [proofOfConceptControllerClass new];
            viewController.modalPresentationStyle = UIModalPresentationFullScreen;
        } else {
            viewController = [UIAlertController alertControllerWithTitle:@"WKWebView PoC Missing"
                                                                 message:@"The proof-of-concept controller was not compiled into this build."
                                                          preferredStyle:UIAlertControllerStyleAlert];
            [(UIAlertController *)viewController addAction:[self browserCancelAction]];
        }
        [self.host browserPresentViewController:viewController];
    }];
}

- (BrowserAdvancedMenuItem *)showTabsMenuItem {
    return [self advancedMenuItemWithTitle:@"Show Tabs"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowTabOverview];
    }];
}

- (BrowserAdvancedMenuItem *)newTabMenuItem {
    return [self advancedMenuItemWithTitle:@"Open New Tab"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserCreateNewTabLoadingHomePage:YES];
    }];
}

- (BrowserAdvancedMenuItem *)favoritesMenuItem {
    return [self advancedMenuItemWithTitle:@"Favorites"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentFavoritesMenu];
    }];
}

- (BrowserAdvancedMenuItem *)historyMenuItem {
    return [self advancedMenuItemWithTitle:@"History"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentHistoryMenu];
    }];
}

- (BrowserAdvancedMenuItem *)userAgentModeMenuItem {
    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *title = mobileModeEnabled ? @"Switch To Desktop User Agent" : @"Switch To Mobile User Agent";
    NSString *userAgent = mobileModeEnabled ? BrowserPreferencesStore.desktopUserAgent : BrowserPreferencesStore.mobileUserAgent;
    BOOL mobileMode = !mobileModeEnabled;
    
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self applyUserAgent:userAgent mobileMode:mobileMode];
    }];
}

- (BrowserAdvancedMenuItem *)pageScalingMenuItem {
    BOOL scalesPageToFit = [[self.host browserWebView] scalesPageToFit];
    NSString *title = scalesPageToFit ? @"Stop Scaling Pages to Fit" : @"Scale Pages to Fit";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self setPageScalingEnabled:!scalesPageToFit];
    }];
}

- (UIAlertAction *)playVideoUnderCursorAction {
    return [self browserActionWithTitle:@"Play Active Video"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.host browserPlayVideoUnderCursorIfAvailable];
        });
    }];
}

- (BrowserAdvancedMenuItem *)fullscreenVideoPlaybackToggleMenuItem {
    NSString *(^titleForState)(BOOL) = ^NSString *(BOOL enabled) {
        return enabled ? @"Full Screen Player: On" : @"Full Screen Player: Off";
    };
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForState(self.host.browserFullscreenVideoPlaybackEnabled)
                                                              style:UIAlertActionStyleDefault
                                                            handler:^{
        self.host.browserFullscreenVideoPlaybackEnabled = !self.host.browserFullscreenVideoPlaybackEnabled;
    }];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        BOOL next = !self.host.browserFullscreenVideoPlaybackEnabled;
        self.host.browserFullscreenVideoPlaybackEnabled = next;
        return titleForState(next);
    };
    item.explanation = @"When On, tapping a video opens it in the built-in full screen player (with its own controls). When Off, videos play inline on the page — double-tap a video to go full screen.";
    return item;
}

- (BrowserAdvancedMenuItem *)videoHUDTimeDisplayToggleMenuItem {
    NSString *(^titleForState)(BOOL) = ^NSString *(BOOL showsTotal) {
        return showsTotal ? @"Player Time: Total Duration" : @"Player Time: Remaining";
    };
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForState(preferencesStore.videoHUDShowsTotalDuration)
                                                              style:UIAlertActionStyleDefault
                                                            handler:^{
        preferencesStore.videoHUDShowsTotalDuration = !preferencesStore.videoHUDShowsTotalDuration;
    }];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        BOOL next = !preferencesStore.videoHUDShowsTotalDuration;
        preferencesStore.videoHUDShowsTotalDuration = next;
        return titleForState(next);
    };
    item.explanation = @"What the right side of the video progress bar shows: the time remaining (e.g. -3:20) or the video's total duration (e.g. 12:45).";
    return item;
}

// Confirmation alert for the NSUserDefaults-backed toggles; the values apply
// to web views created from now on, which the alert states explicitly.
- (void)presentToggleConfirmationMessage:(NSString *)message {
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Nebula Browser" message:message];
    [alertController addAction:[self browserActionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (BrowserAdvancedMenuItem *)popupBlockerToggleMenuItem {
    BOOL enabled = ![[NSUserDefaults standardUserDefaults] boolForKey:@"PopupBlockerDisabled"];
    NSString *title = enabled ? @"Popup Blocker: On — Turn Off" : @"Popup Blocker: Off — Turn On";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL disabled = ![defaults boolForKey:@"PopupBlockerDisabled"];
        [defaults setBool:disabled forKey:@"PopupBlockerDisabled"];
        [defaults synchronize];
        [self presentToggleConfirmationMessage:[NSString stringWithFormat:@"Popup Blocker is now %@. It applies to pages opened from now on.", disabled ? @"OFF" : @"ON"]];
    }];
}

- (BrowserAdvancedMenuItem *)autoFullscreenPromptToggleMenuItem {
    BOOL enabled = ![[NSUserDefaults standardUserDefaults] boolForKey:@"NativeAutoFullscreenPromptDisabled"];
    NSString *title = enabled ? @"Auto Fullscreen Prompt: On — Turn Off" : @"Auto Fullscreen Prompt: Off — Turn On";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL disabled = ![defaults boolForKey:@"NativeAutoFullscreenPromptDisabled"];
        [defaults setBool:disabled forKey:@"NativeAutoFullscreenPromptDisabled"];
        [defaults synchronize];
        [self presentToggleConfirmationMessage:[NSString stringWithFormat:@"Auto Fullscreen Prompt is now %@. It applies to pages opened from now on.", disabled ? @"OFF" : @"ON"]];
    }];
}

- (BrowserAdvancedMenuItem *)arrowShortcutsToggleMenuItem {
    NSString *(^titleForState)(BOOL) = ^NSString *(BOOL enabled) {
        return enabled ? @"Arrow Double-Press Shortcuts: On" : @"Arrow Double-Press Shortcuts: Off";
    };
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForState(preferencesStore.arrowDoubleTapShortcutsEnabled)
                                                              style:UIAlertActionStyleDefault
                                                            handler:^{
        preferencesStore.arrowDoubleTapShortcutsEnabled = !preferencesStore.arrowDoubleTapShortcutsEnabled;
    }];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        BOOL next = !preferencesStore.arrowDoubleTapShortcutsEnabled;
        preferencesStore.arrowDoubleTapShortcutsEnabled = next;
        return titleForState(next);
    };
    item.explanation = @"Double-press a direction to jump:\n\n• Up — Tabs\n• Down — Favorites\n• Left — History\n• Right — New Tab\n\nTurn off if you only want the arrows to scroll.";
    return item;
}

- (BrowserAdvancedMenuItem *)fontSizeAdjustableMenuItem {
    NSString *(^titleForValue)(NSUInteger) = ^NSString *(NSUInteger fontSize) {
        return [NSString stringWithFormat:@"Font Size: %lu%%", (unsigned long)fontSize];
    };
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForValue(self.host.browserTextFontSize)
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(NSInteger direction) {
        // Clamp before assigning: the property is unsigned and the store clamps
        // 50-200, so an underflow would wrap around to the maximum.
        NSInteger newFontSize = (NSInteger)self.host.browserTextFontSize + direction * 5;
        newFontSize = MIN(MAX(newFontSize, 50), 200);
        self.host.browserTextFontSize = (NSUInteger)newFontSize;
        [self.host browserUpdateTextFontSize];
        return titleForValue(self.host.browserTextFontSize);
    };
    return item;
}

#pragma mark - Privacy menu items

- (BrowserAdvancedMenuItem *)launchPageMenuItem {
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    NSString *(^titleForMode)(void) = ^NSString * {
        return [NSString stringWithFormat:@"On Launch: %@", preferencesStore.launchPageModeName];
    };
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForMode()
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        preferencesStore.launchPageMode = preferencesStore.launchPageMode == 1 ? 0 : 1;
        return titleForMode();
    };
    item.explanation = @"What to open when you launch the browser:\n\n• Last Session — reopen the tabs you had open.\n• Home Page — start fresh on your home page.";
    return item;
}

- (BrowserAdvancedMenuItem *)clearHistoryOnExitMenuItem {
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    NSString *(^titleForState)(BOOL) = ^NSString *(BOOL on) {
        return on ? @"Clear History On Exit: On" : @"Clear History On Exit: Off";
    };
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForState(preferencesStore.clearHistoryOnExit)
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        BOOL next = !preferencesStore.clearHistoryOnExit;
        preferencesStore.clearHistoryOnExit = next;
        return titleForState(next);
    };
    item.explanation = @"When you close the app, erase your browsing history automatically. Favorites and settings are kept.";
    return item;
}

- (BrowserAdvancedMenuItem *)privacyModeMenuItem {
    BrowserPreferencesStore *preferencesStore = self.preferencesStore;
    NSString *(^titleForState)(BOOL) = ^NSString *(BOOL on) {
        return on ? @"Privacy Mode: On" : @"Privacy Mode: Off";
    };
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:titleForState(preferencesStore.privacyModeEnabled)
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil];
    item.adjustHandler = ^NSString *(__unused NSInteger direction) {
        BOOL next = !preferencesStore.privacyModeEnabled;
        preferencesStore.privacyModeEnabled = next;
        return titleForState(next);
    };
    item.explanation = @"Hide the page when you switch between Apple TV apps, so your browsing isn't shown in the app switcher preview.";
    return item;
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    BrowserAdvancedMenuItem *mediaDiagnosticsItem = [self advancedMenuItemWithTitle:@"Media Diagnostics"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        [self presentMediaDiagnostics];
    }];
    BrowserAdvancedMenuItem *webkitMediaPrefsItem = [self advancedMenuItemWithTitle:@"Inspect WebKit Media Prefs"
                                                                                style:UIAlertActionStyleDefault
                                                                              handler:^{
        [self presentWebKitRuntimeMediaPreferences];
    }];
    BrowserAdvancedMenuItem *clearCacheItem = [self advancedMenuItemWithTitle:@"Clear Cache"
                                                                         style:UIAlertActionStyleDestructive
                                                                       handler:^{
        [self clearCacheAndReload];
    }];
    BrowserAdvancedMenuItem *clearCookiesItem = [self advancedMenuItemWithTitle:@"Clear Cookies"
                                                                           style:UIAlertActionStyleDestructive
                                                                         handler:^{
        [self clearCookiesAndReload];
    }];

    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Navigation"
                                               items:@[
            [self homePageMenuItem],
            [self setCurrentPageAsHomePageMenuItem],
            [self favoritesMenuItem],
            [self historyMenuItem],
            [self showTabsMenuItem],
            [self newTabMenuItem],
            [self arrowShortcutsToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Appearance"
                                               items:@[
            [self themeMenuItem],
            [self topNavigationVisibilityMenuItem],
            [self pageScalingMenuItem],
            [self fontSizeAdjustableMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Video Playback"
                                               items:@[
            [self fullscreenVideoPlaybackToggleMenuItem],
            [self videoHUDTimeDisplayToggleMenuItem],
            [self autoFullscreenPromptToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Search"
                                               items:@[
            [self searchEngineMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Privacy"
                                               items:@[
            [self launchPageMenuItem],
            [self clearHistoryOnExitMenuItem],
            [self privacyModeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Compatibility"
                                               items:@[
            [self userAgentModeMenuItem],
            [self popupBlockerToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Diagnostics"
                                               items:@[
            mediaDiagnosticsItem,
            webkitMediaPrefsItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Maintenance"
                                               items:@[
            clearCacheItem,
            clearCookiesItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Help"
                                               items:@[
            [self usageGuideMenuItem],
            [self showGuideOnLaunchMenuItem],
            [self supportMenuItem],
        ]],
    ];
}

- (NSString *)advancedMenuFooterText {
    NSString *adjustHint = @"Settings marked ‹ › change with the Left/Right keys.";
    NSDictionary *infoDictionary = NSBundle.mainBundle.infoDictionary;
    NSString *version = infoDictionary[@"CFBundleShortVersionString"];
    BOOL hasVersion = [self stringHasVisibleContent:version];

    if (hasVersion) {
        return [NSString stringWithFormat:@"%@\nVersion %@", adjustHint, version];
    }
    return adjustHint;
}

@end
