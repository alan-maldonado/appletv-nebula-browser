//
//  AppDelegate.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "AppDelegate.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)restoreCookiesFromDefaults {
    NSData *cookieData = [[NSUserDefaults standardUserDefaults] objectForKey:@"ApplicationCookie"];
    if (cookieData.length == 0) {
        return;
    }

    [BrowserWebView restoreCookiesFromData:cookieData];
}

- (void)saveCookiesToDefaults {
    NSData *cookieData = [BrowserWebView cookieDataRepresentation];
    if (cookieData == nil) {
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:@"ApplicationCookie"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	// Override point for customization after application launch.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"MobileMode"]) {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.mobileUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    else {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.desktopUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [self restoreCookiesFromDefaults];
	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
	// Called when the application is about to terminate. Save data if appropriate. See also sceneDidEnterBackground:.
    [self saveCookiesToDefaults];
}

@end

@implementation SceneDelegate

// With UIScene adoption the app-level active/background callbacks are no longer sent
// to the app delegate; the scene equivalents drive the same cookie persistence.

- (AppDelegate *)appDelegate {
    return (AppDelegate *)[UIApplication sharedApplication].delegate;
}

- (void)sceneWillResignActive:(UIScene *)scene {
    [[self appDelegate] saveCookiesToDefaults];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    [[self appDelegate] saveCookiesToDefaults];
}

// Cookies are restored once at launch (didFinishLaunching). While the process lives,
// WKWebsiteDataStore already holds them, so re-restoring on every foreground/activate
// only re-applied stale copies and blocked the main thread (up to 2 s each) on resume.

@end
