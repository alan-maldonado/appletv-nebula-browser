#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BrowserTopBarAction) {
    BrowserTopBarActionBack = 0,
    BrowserTopBarActionRefresh,
    BrowserTopBarActionForward,
    BrowserTopBarActionHome,
    BrowserTopBarActionTabs,
    BrowserTopBarActionURL,
    BrowserTopBarActionFullscreen,
    BrowserTopBarActionMenu
};

@class BrowserTopBarView;

@protocol BrowserTopBarViewDelegate <NSObject>

- (void)browserTopBarView:(BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action;

@end

@interface BrowserTopBarView : UIVisualEffectView

@property (nonatomic, weak, nullable) id<BrowserTopBarViewDelegate> delegate;
@property (nonatomic, readonly) UIImageView *backImageView;
@property (nonatomic, readonly) UIImageView *refreshImageView;
@property (nonatomic, readonly) UIImageView *forwardImageView;
@property (nonatomic, readonly) UIImageView *homeImageView;
@property (nonatomic, readonly) UIImageView *tabsImageView;
@property (nonatomic, readonly) UIImageView *fullscreenImageView;
@property (nonatomic, readonly) UIImageView *menuImageView;
@property (nonatomic, readonly) UILabel *URLLabel;
@property (nonatomic, readonly) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, readonly, getter=isFocusModeActive) BOOL focusModeActive;

- (CGRect)interactiveFrameForView:(UIView *)view;
- (void)setFocusModeActive:(BOOL)focusModeActive;
- (nullable UIView *)preferredFocusItem;
// Cursor-mode click: triggers the button under the given point (in this view's
// coordinates). Returns NO if no button is there.
- (BOOL)handleCursorClickAtPoint:(CGPoint)pointInView;

@end

NS_ASSUME_NONNULL_END
