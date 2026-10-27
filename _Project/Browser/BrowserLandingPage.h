#import <Foundation/Foundation.h>

// Built-in landing page shown as the default home page: the user's favorites
// rendered as a dark, JS-free grid of tiles. An empty FAVORITES list produces
// a centered hint tile instead (see fallbackHTMLIfEmpty).
@interface BrowserLandingPage : NSObject

// Full HTML document for the favorites grid; internally returns the fallback
// document when there are no favorites.
+ (NSString *)landingHTML;

// The single centered hint-tile document used when there are no favorites.
+ (NSString *)fallbackHTMLIfEmpty;

@end
