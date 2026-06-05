#import "BrowserNavigationService.h"

#import "BrowserPreferencesStore.h"
#import "BrowserTabViewModel.h"

static NSString * const kHistoryDefaultsKey = @"HISTORY";
static NSUInteger const kMaximumHistoryCount = 100;

@interface BrowserNavigationService ()

@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

@implementation BrowserNavigationService

- (instancetype)init {
    return [self initWithPreferencesStore:[BrowserPreferencesStore new]];
}

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (NSURLRequest *)homePageRequest {
    NSString *homePageURLString = self.preferencesStore.homePageURLString;
    if (homePageURLString.length == 0) {
        homePageURLString = @"http://www.google.com";
    }
    return [self requestForURLString:homePageURLString];
}

- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString {
    NSString *trimmedAddress = [self trimmedString:addressString];
    if (trimmedAddress.length == 0) {
        return nil;
    }
    
    if (![trimmedAddress hasPrefix:@"http://"] && ![trimmedAddress hasPrefix:@"https://"]) {
        trimmedAddress = [@"http://" stringByAppendingString:trimmedAddress];
    }
    return [self requestForURLString:trimmedAddress];
}

- (BOOL)inputLooksLikeURL:(NSString *)input {
    NSString *trimmed = [self trimmedString:input];
    if (trimmed.length == 0) {
        return NO;
    }
    // Explicit scheme is unambiguous.
    if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"]) {
        return YES;
    }
    // Any whitespace means it's almost certainly a search query.
    if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) {
        return NO;
    }
    // localhost / host:port.
    NSString *host = [[trimmed componentsSeparatedByString:@"/"] firstObject];
    if ([host.lowercaseString hasPrefix:@"localhost"]) {
        return YES;
    }
    // Must contain a dot to be a bare domain (a path-only token isn't a URL).
    NSString *hostWithoutPort = [[host componentsSeparatedByString:@":"] firstObject];
    NSArray<NSString *> *labels = [hostWithoutPort componentsSeparatedByString:@"."];
    if (labels.count < 2) {
        return NO;
    }
    NSString *tld = labels.lastObject;
    if (tld.length < 2) {
        return NO;
    }
    // All-numeric labels → looks like an IPv4 address (a.b.c.d).
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    BOOL allNumeric = YES;
    for (NSString *label in labels) {
        if (label.length == 0 || [label rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) {
            allNumeric = NO;
            break;
        }
    }
    if (allNumeric) {
        return labels.count == 4;
    }
    // Otherwise treat as a domain only if the TLD is alphabetic (e.g. .com, .io).
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    return [tld rangeOfCharacterFromSet:letters.invertedSet].location == NSNotFound;
}

- (NSURLRequest *)requestForURLOrSearchString:(NSString *)input {
    NSString *trimmed = [self trimmedString:input];
    if (trimmed.length == 0) {
        return nil;
    }
    if ([self inputLooksLikeURL:trimmed]) {
        return [self requestForEnteredAddressString:trimmed];
    }
    return [self googleSearchRequestForQuery:trimmed];
}

- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query {
    NSString *sanitizedQuery = [self sanitizedSearchQuery:query];
    if (sanitizedQuery.length == 0) {
        return nil;
    }

    NSString *format = self.preferencesStore.searchQueryURLFormat ?: @"https://www.google.com/search?q=%@";
    NSString *searchURLString = [NSString stringWithFormat:format, sanitizedQuery];
    return [self requestForURLString:searchURLString];
}

- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString {
    NSString *searchQuery = [self trimmedString:requestURLString];
    if (searchQuery.length == 0) {
        return nil;
    }
    
    if ([searchQuery hasSuffix:@"/"]) {
        searchQuery = [searchQuery substringToIndex:searchQuery.length - 1];
    }
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"http://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"www." withString:@""];
    
    return [self googleSearchRequestForQuery:searchQuery];
}

- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString {
    if (tab == nil) {
        return;
    }
    
    NSString *safeTitle = pageTitle ?: @"";
    NSString *safeURLString = currentURLString ?: @"";
    tab.title = safeTitle.length > 0 ? safeTitle : @"New Tab";
    tab.URLString = safeURLString;
    
    [self persistHistoryItemWithURLString:safeURLString title:safeTitle];
}

- (BOOL)shouldIgnoreLoadError:(NSError *)error {
    NSInteger errorCode = error.code;
    return errorCode == 999 || errorCode == 204;
}

- (NSURLRequest *)requestForURLString:(NSString *)URLString {
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    return request;
}

- (NSString *)trimmedString:(NSString *)string {
    if (string == nil) {
        return @"";
    }
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)sanitizedSearchQuery:(NSString *)query {
    NSString *trimmedQuery = [self trimmedString:query];
    if (trimmedQuery.length == 0) {
        return @"";
    }
    
    NSString *searchQuery = [trimmedQuery stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"." withString:@"+"];
    while ([searchQuery containsString:@"++"]) {
        searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"++" withString:@"+"];
    }
    
    return [searchQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

- (void)persistHistoryItemWithURLString:(NSString *)URLString title:(NSString *)title {
    if (URLString.length == 0) {
        return;
    }
    
    NSArray *historyItem = @[URLString, title ?: @""];
    NSMutableArray *historyItems = [NSMutableArray arrayWithObject:historyItem];
    NSArray *storedHistory = [[NSUserDefaults standardUserDefaults] arrayForKey:kHistoryDefaultsKey];
    if (storedHistory.count > 0) {
        NSArray *latestItem = storedHistory.firstObject;
        if ([latestItem isKindOfClass:[NSArray class]] && latestItem.count > 0 && [latestItem[0] isEqualToString:URLString]) {
            [historyItems removeObjectAtIndex:0];
        }
        [historyItems addObjectsFromArray:storedHistory];
    }
    
    while (historyItems.count > kMaximumHistoryCount) {
        [historyItems removeLastObject];
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:historyItems forKey:kHistoryDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
