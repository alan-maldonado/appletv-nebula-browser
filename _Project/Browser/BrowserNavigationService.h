#import <Foundation/Foundation.h>

@class BrowserTabViewModel;
@class BrowserPreferencesStore;

@interface BrowserNavigationService : NSObject

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (NSURLRequest *)homePageRequest;
- (NSURLRequest *)requestForURLString:(NSString *)URLString;
- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString;
// Decides whether the text is an address or a search query and returns the
// matching request (navigation for URL-like input, Google search otherwise).
- (NSURLRequest *)requestForURLOrSearchString:(NSString *)input;
- (BOOL)inputLooksLikeURL:(NSString *)input;
- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query;
- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString;
- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString;
- (BOOL)shouldIgnoreLoadError:(NSError *)error;

@end
