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
#import <mach/mach.h>

@interface AppDelegate ()
@property (nonatomic, strong) dispatch_source_t memoryDiagnosticTimer;
@end

@implementation AppDelegate

// DIAGNOSTIC(webshim): temporary telemetry for the SIGKILL (jetsam?) repro on google.com.
// A 5s heartbeat records this process's dirty memory to a file; the next launch logs the
// last value before the kill. Memory warnings are logged as they arrive.
- (NSString *)memoryHeartbeatPath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"webshim_mem_heartbeat.txt"];
}

- (double)currentFootprintMB {
    struct task_vm_info vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) != KERN_SUCCESS) {
        return -1;
    }
    return (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
}

- (void)startMemoryDiagnostics {
    NSString *heartbeat = [NSString stringWithContentsOfFile:[self memoryHeartbeatPath] encoding:NSUTF8StringEncoding error:NULL];
    if (heartbeat.length > 0) {
        NSLog(@"[MemDiag] previous session last heartbeat before exit: %@", heartbeat);
    }

    __block NSInteger tick = 0;
    self.memoryDiagnosticTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.memoryDiagnosticTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC * 5, NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.memoryDiagnosticTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        double footprint = [strongSelf currentFootprintMB];
        NSString *entry = [NSString stringWithFormat:@"%.0fMB @ %.0f", footprint, [NSDate date].timeIntervalSince1970];
        [entry writeToFile:[strongSelf memoryHeartbeatPath] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        tick += 1;
        if (tick % 2 == 0) {
            NSLog(@"[MemDiag] footprint=%.0fMB", footprint);
        }
    });
    dispatch_resume(self.memoryDiagnosticTimer);
}

// Remote diagnostics toggles: the tester cannot edit preferences on the TV, so
// flags arrive as launch arguments ("-Key YES" / "-Key NO") and are written
// into NSUserDefaults at startup. An argument overrides the stored value only
// when present; an absent argument leaves the stored value alone.
- (void)applyDiagnosticLaunchArguments {
    // Feature toggles default OFF (registered here so a fresh install has an
    // explicit NO); launch arguments can flip them for remote bisect.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"PopupBlockerDisabled": @NO,
        @"VisibilitySpoofDisabled": @NO,
        @"NativeAutoFullscreenPromptDisabled": @NO,
        @"NativeVideoModeDisabled": @NO,
        @"NativeAutoFullscreenDisabled": @YES,
        @"NativePlayerCustomTransportEnabled": @NO,
        // Autoresume-friendly default: pages may start media without a user
        // gesture (a launch arg can still flip it back to NO).
        @"WebViewAutoPlayAll": @YES,
        @"ForcePlayOnLaunch": @NO,
        // Default YES: the native player builds its asset as a plain
        // AVURLAsset with HTTP header options; a launch arg re-enables the
        // custom resource-loader path.
        @"NativePlayerLoaderDisabled": @YES,
        // Debug flag: auto-present the native player once per document as
        // soon as a video reports playing (automated testing).
        @"ForceNativePresentOnPlay": @NO,
        @"PlaylistNoCacheResponseEnabled": @NO,
        // Test-only: auto-dismiss the native player after N seconds (0 = off).
        @"NativePresentAutoDismissSeconds": @0,
        // Test-only: re-present the native player N seconds after its first
        // dismissal (0 = off).
        @"NativePresentSecondPresentSeconds": @0,
    }];

    NSArray<NSString *> *diagnosticKeys = @[
        @"MediaEngineHooksDisabled",
        @"MediaEngineHlsFlagDisabled",
        @"MediaEngineNetFlagDisabled",
        @"MediaEngineSrcFlagDisabled",
        @"MediaEngineProbeFlagDisabled",
        @"MemDiagDisabled",
        @"PopupBlockerDisabled",
        @"VisibilitySpoofDisabled",
        @"NativeAutoFullscreenPromptDisabled",
        @"NativeVideoModeDisabled",
        @"NativeAutoFullscreenDisabled",
        @"WebViewAutoPlayAll",
        @"ForcePlayOnLaunch",
        @"NativePlayerLoaderDisabled",
        @"ForceNativePresentOnPlay"
    ];

    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    for (NSString *key in diagnosticKeys) {
        NSString *flag = [NSString stringWithFormat:@"-%@", key];
        for (NSUInteger i = 0; i < arguments.count; i++) {
            if (![arguments[i] isEqualToString:flag]) {
                continue;
            }
            NSString *value = (i + 1 < arguments.count) ? arguments[i + 1] : nil;
            if ([value isEqualToString:@"YES"]) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:key];
            }
            else if ([value isEqualToString:@"NO"]) {
                [[NSUserDefaults standardUserDefaults] setBool:NO forKey:key];
            }
            break;
        }
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    NSLog(@"[MemDiag] MEMORY WARNING footprint=%.0fMB", [self currentFootprintMB]);
}

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
    [self applyDiagnosticLaunchArguments];
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
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"MemDiagDisabled"]) {
        [self startMemoryDiagnostics];
    }
	return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
	// Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
	// Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    [self saveCookiesToDefaults];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	// Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
	// If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    [self saveCookiesToDefaults];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	// Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    [self restoreCookiesFromDefaults];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	// Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self restoreCookiesFromDefaults];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	// Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [self saveCookiesToDefaults];
}

@end
