#import <Foundation/Foundation.h>

@class BrowserViewModel;
@class BrowserNavigationService;

@interface BrowserSessionStore : NSObject

- (BOOL)restoreSessionIntoViewModel:(BrowserViewModel *)viewModel;
- (void)saveSessionForViewModel:(BrowserViewModel *)viewModel;
- (void)clearSavedSession;
- (nullable NSURLRequest *)consumeSavedURLToReopenRequestWithNavigationService:(BrowserNavigationService *)navigationService;

@end
