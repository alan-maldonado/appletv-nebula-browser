#import "BrowserFavoritesHomeController.h"

#import "BrowserFavoritesStore.h"

// Panel geometry matches the tab overview so both screens feel like one family.
static CGFloat const kFavoritesHomePanelHorizontalInset = 40.0;
static CGFloat const kFavoritesHomePanelMaxWidth = 1760.0;
static CGFloat const kFavoritesHomePanelCornerRadius = 43.0;
static CGFloat const kFavoritesHomePanelTopInset = 120.0;
static CGFloat const kFavoritesHomePanelBottomInset = 88.0;
static CGFloat const kFavoritesHomePanelSideInset = 54.0;
static CGFloat const kFavoritesHomeHeaderTopInset = 34.0;
static CGFloat const kFavoritesHomeTitleHeight = 64.0;
static CGFloat const kFavoritesHomeSubtitleTop = 94.0;
static CGFloat const kFavoritesHomeSubtitleHeight = 36.0;
static CGFloat const kFavoritesHomeContentTopInset = 160.0;
static CGFloat const kFavoritesHomeFooterHeight = 28.0;
static NSInteger const kFavoritesHomeColumns = 4;
static CGFloat const kFavoritesHomeCardHeight = 300.0;
static CGFloat const kFavoritesHomeCardSpacing = 44.0;
static CGFloat const kFavoritesHomeCardGlowInset = 24.0;
static CGFloat const kFavoritesHomeIconSize = 120.0;
static CGFloat const kFavoritesHomeIconTop = 34.0;

static NSString *BrowserFavoritesHomeHost(NSString *URLString) {
    NSString *host = [NSURL URLWithString:URLString].host.lowercaseString ?: @"";
    return [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
}

#pragma mark - Site icons

// Each site's own apple-touch-icon (no third-party favicon service). Misses are
// cached too, as NSNull, so a site without one is asked only once per launch.
static NSCache<NSString *, id> *BrowserFavoritesHomeIconCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
    });
    return cache;
}

static void BrowserFavoritesHomeLoadIcon(NSString *URLString, void (^completion)(UIImage * _Nullable image)) {
    NSURL *URL = [NSURL URLWithString:URLString];
    NSString *key = URL.host.lowercaseString;
    if (key.length == 0 || !([URL.scheme isEqualToString:@"https"] || [URL.scheme isEqualToString:@"http"])) {
        completion(nil);
        return;
    }
    id cached = [BrowserFavoritesHomeIconCache() objectForKey:key];
    if (cached != nil) {
        completion([cached isKindOfClass:[UIImage class]] ? cached : nil);
        return;
    }
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = URL.scheme;
    components.host = URL.host;
    components.port = URL.port;
    components.path = @"/apple-touch-icon.png";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL
                                                           cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                       timeoutInterval:8.0];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = (error == nil && status == 200 && data.length > 0) ? [UIImage imageWithData:data] : nil;
        // Tiny images are usually tracking pixels or placeholders, not icons.
        if (image.size.width < 32.0) {
            image = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [BrowserFavoritesHomeIconCache() setObject:image ?: (id)NSNull.null forKey:key];
            completion(image);
        });
    }] resume];
}

#pragma mark - Card

@interface BrowserFavoritesHomeCell : UICollectionViewCell

- (void)configureWithFavorite:(NSDictionary<NSString *, NSString *> *)favorite accentColor:(UIColor *)accentColor;

@end

@interface BrowserFavoritesHomeCell ()

@property (nonatomic) UIView *cardBackgroundView;
@property (nonatomic) UIView *iconTileView;
@property (nonatomic) UILabel *monogramLabel;
@property (nonatomic) UIImageView *iconImageView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *domainLabel;
@property (nonatomic) UIColor *accentColor;
@property (nonatomic, copy) NSString *URLString;

@end

@implementation BrowserFavoritesHomeCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _cardBackgroundView = [[UIView alloc] initWithFrame:self.contentView.bounds];
        _cardBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cardBackgroundView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
        _cardBackgroundView.layer.cornerRadius = 30.0;
        _cardBackgroundView.clipsToBounds = YES;
        [self.contentView addSubview:_cardBackgroundView];

        _iconTileView = [UIView new];
        _iconTileView.layer.cornerRadius = 28.0;
        _iconTileView.clipsToBounds = YES;
        [_cardBackgroundView addSubview:_iconTileView];

        _monogramLabel = [UILabel new];
        _monogramLabel.textColor = UIColor.whiteColor;
        _monogramLabel.font = [UIFont systemFontOfSize:60.0 weight:UIFontWeightBold];
        _monogramLabel.textAlignment = NSTextAlignmentCenter;
        [_iconTileView addSubview:_monogramLabel];

        _iconImageView = [UIImageView new];
        _iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        _iconImageView.hidden = YES;
        [_iconTileView addSubview:_iconImageView];

        _titleLabel = [UILabel new];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [_cardBackgroundView addSubview:_titleLabel];

        _domainLabel = [UILabel new];
        _domainLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        _domainLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _domainLabel.textAlignment = NSTextAlignmentCenter;
        _domainLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_cardBackgroundView addSubview:_domainLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    self.iconTileView.frame = CGRectMake((width - kFavoritesHomeIconSize) / 2.0, kFavoritesHomeIconTop, kFavoritesHomeIconSize, kFavoritesHomeIconSize);
    self.monogramLabel.frame = self.iconTileView.bounds;
    self.iconImageView.frame = self.iconTileView.bounds;
    CGFloat textTop = kFavoritesHomeIconTop + kFavoritesHomeIconSize + 26.0;
    self.titleLabel.frame = CGRectMake(24.0, textTop, width - 48.0, 40.0);
    self.domainLabel.frame = CGRectMake(24.0, textTop + 44.0, width - 48.0, 30.0);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.transform = CGAffineTransformIdentity;
    self.iconImageView.image = nil;
    self.iconImageView.hidden = YES;
}

- (void)configureWithFavorite:(NSDictionary<NSString *, NSString *> *)favorite accentColor:(UIColor *)accentColor {
    NSString *URLString = favorite[@"url"] ?: @"";
    NSString *host = BrowserFavoritesHomeHost(URLString);
    NSString *title = favorite[@"title"].length > 0 ? favorite[@"title"] : (host.length > 0 ? host : URLString);
    self.URLString = URLString;
    self.accentColor = accentColor;
    self.titleLabel.text = title;
    self.domainLabel.text = host.length > 0 ? host : URLString;
    self.iconTileView.backgroundColor = accentColor;
    self.monogramLabel.text = title.length > 0 ? [[title substringToIndex:[title rangeOfComposedCharacterSequenceAtIndex:0].length] uppercaseString] : @"?";

    __weak typeof(self) weakSelf = self;
    BrowserFavoritesHomeLoadIcon(URLString, ^(UIImage *image) {
        // The cell may have been reused for another favorite while the icon loaded.
        if (image == nil || ![weakSelf.URLString isEqualToString:URLString]) {
            return;
        }
        weakSelf.iconImageView.image = image;
        weakSelf.iconImageView.hidden = NO;
    });
    [self updateAppearance];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearance];
    } completion:nil];
}

- (void)updateAppearance {
    BOOL focused = self.isFocused;
    self.cardBackgroundView.backgroundColor = [UIColor colorWithWhite:focused ? 0.22 : 0.14 alpha:1.0];
    self.layer.shadowColor = (self.accentColor ?: UIColor.whiteColor).CGColor;
    self.layer.shadowOffset = CGSizeZero;
    self.layer.shadowOpacity = focused ? 0.78 : 0.0;
    self.layer.shadowRadius = 18.0;
    self.transform = focused ? CGAffineTransformMakeScale(1.06, 1.06) : CGAffineTransformIdentity;
}

@end

#pragma mark - Screen

@interface BrowserFavoritesHomeController ()

@property (nonatomic, weak) id<BrowserFavoritesHomeControllerHost> host;
@property (nonatomic, readwrite, getter=isVisible) BOOL visible;
@property (nonatomic) BOOL cursorModeBeforeShowing;
@property (nonatomic, weak) UIViewController *presentedHomeViewController;

- (void)openFavorite:(NSDictionary<NSString *, NSString *> *)favorite inNewTab:(BOOL)newTab;
- (void)homeViewControllerDidDisappear:(UIViewController *)viewController;

@end

@interface BrowserFavoritesHomeViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>

- (instancetype)initWithHomeController:(BrowserFavoritesHomeController *)homeController accentColor:(UIColor *)accentColor;

@end

@interface BrowserFavoritesHomeViewController ()

@property (nonatomic, weak) BrowserFavoritesHomeController *homeController;
@property (nonatomic) UIColor *accentColor;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *favorites;
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) UILabel *subtitleLabel;
@property (nonatomic) UILabel *emptyLabel;
@property (nonatomic) UILabel *footerLabel;

@end

@implementation BrowserFavoritesHomeViewController

- (instancetype)initWithHomeController:(BrowserFavoritesHomeController *)homeController accentColor:(UIColor *)accentColor {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _homeController = homeController;
        _accentColor = accentColor;
        _favorites = [[BrowserFavoritesStore standardStore] favorites];
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [self.view addSubview:dimView];

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.alpha = 0.98;
    panelView.layer.cornerRadius = kFavoritesHomePanelCornerRadius;
    panelView.layer.masksToBounds = YES;
    [self.view addSubview:panelView];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Favorites";
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    [panelView.contentView addSubview:titleLabel];

    UILabel *subtitleLabel = [UILabel new];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [panelView.contentView addSubview:subtitleLabel];
    self.subtitleLabel = subtitleLabel;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumLineSpacing = kFavoritesHomeCardSpacing;
    layout.minimumInteritemSpacing = kFavoritesHomeCardSpacing;
    layout.sectionInset = UIEdgeInsetsMake(kFavoritesHomeCardGlowInset, kFavoritesHomeCardGlowInset, kFavoritesHomeCardGlowInset, kFavoritesHomeCardGlowInset);

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.clipsToBounds = NO;
    collectionView.showsVerticalScrollIndicator = NO;
    collectionView.remembersLastFocusedIndexPath = YES;
    collectionView.dataSource = self;
    collectionView.delegate = self;
    [collectionView registerClass:[BrowserFavoritesHomeCell class] forCellWithReuseIdentifier:@"FavoriteCard"];
    [panelView.contentView addSubview:collectionView];
    self.collectionView = collectionView;

    UILabel *emptyLabel = [UILabel new];
    emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    emptyLabel.text = @"No favorites yet.\nAdd the current page from Settings → Favorites, or from Nebula Remote.";
    emptyLabel.numberOfLines = 0;
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    emptyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    [panelView.contentView addSubview:emptyLabel];
    self.emptyLabel = emptyLabel;

    UILabel *footerLabel = [UILabel new];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    footerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    footerLabel.textAlignment = NSTextAlignmentCenter;
    [panelView.contentView addSubview:footerLabel];
    self.footerLabel = footerLabel;

    CGFloat panelWidth = MAX(MIN(CGRectGetWidth(self.view.bounds) - (kFavoritesHomePanelHorizontalInset * 2.0), kFavoritesHomePanelMaxWidth), 860.0);
    CGFloat panelHeight = MAX(CGRectGetHeight(self.view.bounds) - kFavoritesHomePanelTopInset - kFavoritesHomePanelBottomInset, 760.0);
    [NSLayoutConstraint activateConstraints:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kFavoritesHomePanelTopInset],
        [panelView.widthAnchor constraintEqualToConstant:panelWidth],
        [panelView.heightAnchor constraintEqualToConstant:panelHeight],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kFavoritesHomePanelSideInset],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor constant:kFavoritesHomeHeaderTopInset],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:panelView.contentView.trailingAnchor constant:-kFavoritesHomePanelSideInset],
        [titleLabel.heightAnchor constraintEqualToConstant:kFavoritesHomeTitleHeight],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kFavoritesHomePanelSideInset],
        [subtitleLabel.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor constant:kFavoritesHomeSubtitleTop],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor constant:-kFavoritesHomePanelSideInset],
        [subtitleLabel.heightAnchor constraintEqualToConstant:kFavoritesHomeSubtitleHeight],

        [collectionView.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kFavoritesHomePanelSideInset - kFavoritesHomeCardGlowInset],
        [collectionView.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor constant:-(kFavoritesHomePanelSideInset - kFavoritesHomeCardGlowInset)],
        [collectionView.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor constant:kFavoritesHomeContentTopInset],
        [collectionView.bottomAnchor constraintEqualToAnchor:footerLabel.topAnchor constant:-18.0],

        [emptyLabel.centerXAnchor constraintEqualToAnchor:collectionView.centerXAnchor],
        [emptyLabel.centerYAnchor constraintEqualToAnchor:collectionView.centerYAnchor],
        [emptyLabel.widthAnchor constraintLessThanOrEqualToConstant:1100.0],

        [footerLabel.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kFavoritesHomePanelSideInset],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor constant:-kFavoritesHomePanelSideInset],
        [footerLabel.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor constant:-24.0],
        [footerLabel.heightAnchor constraintEqualToConstant:kFavoritesHomeFooterHeight],
    ]];

    // Favorites edited from Nebula Remote while this is up show right away.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(favoritesDidChange:)
                                                 name:BrowserFavoritesStoreDidChangeNotification
                                               object:nil];
    [self updateLabels];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.homeController homeViewControllerDidDisappear:self];
}

- (void)favoritesDidChange:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.favorites = [[BrowserFavoritesStore standardStore] favorites];
        [self.collectionView reloadData];
        [self updateLabels];
        [self setNeedsFocusUpdate];
    });
}

- (void)updateLabels {
    NSUInteger count = self.favorites.count;
    self.emptyLabel.hidden = count > 0;
    self.subtitleLabel.text = count == 1 ? @"1 favorite" : [NSString stringWithFormat:@"%lu favorites", (unsigned long)count];
    self.footerLabel.text = count > 0 ? @"Select: Open   Play/Pause: Open in New Tab   Menu: Close" : @"Menu: Close";
}

- (NSInteger)focusedItemIndex {
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        if ([self.collectionView cellForItemAtIndexPath:indexPath].isFocused) {
            return indexPath.item;
        }
    }
    return NSNotFound;
}

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.favorites.count : 0;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserFavoritesHomeCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"FavoriteCard" forIndexPath:indexPath];
    [cell configureWithFavorite:self.favorites[indexPath.item] accentColor:self.accentColor];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(__unused NSIndexPath *)indexPath {
    (void)collectionViewLayout;
    CGFloat available = CGRectGetWidth(collectionView.bounds) - (kFavoritesHomeCardGlowInset * 2.0);
    CGFloat width = floor((available - kFavoritesHomeCardSpacing * (kFavoritesHomeColumns - 1)) / kFavoritesHomeColumns);
    return CGSizeMake(MAX(width, 240.0), kFavoritesHomeCardHeight);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    [self.homeController openFavorite:self.favorites[indexPath.item] inNewTab:NO];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.collectionView];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self.homeController dismiss];
        return;
    }
    if (press != nil && press.type == UIPressTypePlayPause) {
        NSInteger index = [self focusedItemIndex];
        if (index != NSNotFound && index < (NSInteger)self.favorites.count) {
            [self.homeController openFavorite:self.favorites[index] inNewTab:YES];
        }
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@implementation BrowserFavoritesHomeController

- (instancetype)initWithHost:(id<BrowserFavoritesHomeControllerHost>)host {
    self = [super init];
    if (self) {
        _host = host;
    }
    return self;
}

- (void)show {
    if (self.visible) {
        return;
    }
    // Focus engine drives the grid; the cursor comes back as it was on close.
    self.cursorModeBeforeShowing = [self.host browserFavoritesHomeControllerCursorModeEnabled];
    self.visible = YES;
    [self.host browserFavoritesHomeControllerSetCursorModeEnabled:NO];

    BrowserFavoritesHomeViewController *viewController = [[BrowserFavoritesHomeViewController alloc] initWithHomeController:self
                                                                                                                accentColor:[self.host browserFavoritesHomeControllerAccentColor]];
    self.presentedHomeViewController = viewController;
    [self.host browserFavoritesHomeControllerPresentViewController:viewController];
}

- (void)dismiss {
    if (!self.visible) {
        return;
    }
    UIViewController *viewController = self.presentedHomeViewController;
    if (viewController == nil) {
        [self homeViewControllerDidDisappear:nil];
        return;
    }
    [viewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)openFavorite:(NSDictionary<NSString *, NSString *> *)favorite inNewTab:(BOOL)newTab {
    NSString *URLString = favorite[@"url"];
    if (URLString.length == 0) {
        return;
    }
    UIViewController *viewController = self.presentedHomeViewController;
    void (^open)(void) = ^{
        [self.host browserFavoritesHomeControllerOpenURLString:URLString inNewTab:newTab];
    };
    if (viewController == nil) {
        open();
        return;
    }
    [viewController dismissViewControllerAnimated:YES completion:open];
}

- (void)homeViewControllerDidDisappear:(UIViewController *)viewController {
    if (viewController != nil && viewController != self.presentedHomeViewController) {
        return;
    }
    self.presentedHomeViewController = nil;
    if (!self.visible) {
        return;
    }
    self.visible = NO;
    [self.host browserFavoritesHomeControllerSetCursorModeEnabled:self.cursorModeBeforeShowing];
}

@end
