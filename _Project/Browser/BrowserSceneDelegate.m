//
//  BrowserSceneDelegate.m
//  Browser
//

#import "BrowserSceneDelegate.h"
#import "AppDelegate.h"

@implementation BrowserSceneDelegate

- (AppDelegate *)appDelegate {
    return (AppDelegate *)UIApplication.sharedApplication.delegate;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;

    // The app delegate (via the main storyboard / didFinishLaunching, which
    // runs BEFORE willConnect) already owns the app's window. Adopt it into
    // the scene instead of building a parallel hierarchy.
    AppDelegate *appDelegate = [self appDelegate];
    UIWindow *window = appDelegate.window;
    if (window == nil) {
        // Pure storyboard app: with a scene manifest UIKit no longer creates
        // the Main-storyboard window on its own, so create it here — exactly
        // the hierarchy the pre-scene app had.
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:NSBundle.mainBundle];
        UIViewController *rootViewController = [storyboard instantiateInitialViewController];
        if (rootViewController == nil) {
            NSLog(@"[SceneBridge] no window and no Main storyboard root");
            return;
        }
        window = [[UIWindow alloc] initWithWindowScene:windowScene];
        window.rootViewController = rootViewController;
        appDelegate.window = window;
        NSLog(@"[SceneBridge] created storyboard window");
    }

    // Keep a strong reference here too so UIKit does not tear the window down
    // when the app delegate releases it, then attach it to this scene.
    self.window = window;
    window.windowScene = windowScene;
    [window makeKeyAndVisible];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneMemoryWarning:)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)sceneMemoryWarning:(NSNotification *)notification {
    AppDelegate *appDelegate = [self appDelegate];
    if ([appDelegate respondsToSelector:@selector(applicationDidReceiveMemoryWarning:)]) {
        [appDelegate applicationDidReceiveMemoryWarning:UIApplication.sharedApplication];
    }
}

#pragma mark - Lifecycle mirroring

- (void)sceneDidBecomeActive:(UIScene *)scene {
    AppDelegate *appDelegate = [self appDelegate];
    if ([appDelegate respondsToSelector:@selector(applicationDidBecomeActive:)]) {
        [appDelegate applicationDidBecomeActive:UIApplication.sharedApplication];
    }
}

- (void)sceneWillResignActive:(UIScene *)scene {
    AppDelegate *appDelegate = [self appDelegate];
    if ([appDelegate respondsToSelector:@selector(applicationWillResignActive:)]) {
        [appDelegate applicationWillResignActive:UIApplication.sharedApplication];
    }
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    AppDelegate *appDelegate = [self appDelegate];
    if ([appDelegate respondsToSelector:@selector(applicationDidEnterBackground:)]) {
        [appDelegate applicationDidEnterBackground:UIApplication.sharedApplication];
    }
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    AppDelegate *appDelegate = [self appDelegate];
    if ([appDelegate respondsToSelector:@selector(applicationWillEnterForeground:)]) {
        [appDelegate applicationWillEnterForeground:UIApplication.sharedApplication];
    }
}

@end
