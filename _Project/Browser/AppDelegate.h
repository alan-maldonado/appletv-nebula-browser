//
//  AppDelegate.h
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

- (void)restoreCookiesFromDefaults;
- (void)saveCookiesToDefaults;

@end

// tvOS 27 traps at launch for apps built against its SDK without UIScene adoption.
// The window comes from UISceneStoryboardFile in Info.plist.
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow *window;

@end

