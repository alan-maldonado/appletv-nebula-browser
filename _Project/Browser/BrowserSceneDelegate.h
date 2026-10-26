//
//  BrowserSceneDelegate.h
//  Browser
//
//  Window-attach bridge: apps linked against the tvOS 27 SDK must adopt the
//  UIScene lifecycle on the simulator. All app logic stays in AppDelegate;
//  this class only re-attaches the AppDelegate-created window to the scene.
//

#import <UIKit/UIKit.h>

@interface BrowserSceneDelegate : NSObject <UIWindowSceneDelegate>

@property (nonatomic, strong) UIWindow *window;

@end
