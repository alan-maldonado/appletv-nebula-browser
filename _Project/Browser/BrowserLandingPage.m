#import "BrowserLandingPage.h"

static NSString * const kFavoritesDefaultsKey = @"FAVORITES";

// The five XML-significant characters, ampersand first so the entity
// replacements it introduces are not escaped again.
static NSString *BrowserLandingHTMLEscape(NSString *input) {
    if (input.length == 0) {
        return @"";
    }
    NSMutableString *escaped = [input mutableCopy];
    NSArray<NSArray<NSString *> *> *replacements = @[
        @[ @"&", @"&amp;" ],
        @[ @"<", @"&lt;" ],
        @[ @">", @"&gt;" ],
        @[ @"\"", @"&quot;" ],
        @[ @"'", @"&#39;" ],
    ];
    for (NSArray<NSString *> *pair in replacements) {
        [escaped replaceOccurrencesOfString:pair[0]
                                 withString:pair[1]
                                    options:0
                                      range:NSMakeRange(0, escaped.length)];
    }
    return escaped;
}

// Lowercased host of the URL (no www. prefix) for the small domain line; the
// raw string back when it does not parse as a URL.
static NSString *BrowserLandingDomainForURLString(NSString *URLString) {
    NSString *host = [NSURL URLWithString:URLString ?: @""].host;
    if (host.length == 0) {
        return URLString ?: @"";
    }
    if ([host.lowercaseString hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host.lowercaseString;
}

// Uppercased first character of the title (falling back to the domain) used
// as the tile avatar glyph.
static NSString *BrowserLandingInitialForTitle(NSString *title, NSString *URLString) {
    NSString *source = title.length > 0 ? title : BrowserLandingDomainForURLString(URLString);
    if (source.length == 0) {
        return @"";
    }
    NSRange range = [source rangeOfComposedCharacterSequenceAtIndex:0];
    return [[source substringWithRange:range] uppercaseString];
}

static NSString *BrowserLandingDocumentHead(void) {
    return @"<!DOCTYPE html>\n"
           @"<html>\n"
           @"<head>\n"
           @"<meta charset=\"utf-8\">\n"
           @"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
           @"<title>Favorites</title>\n"
           @"<style>\n"
           @"body { margin:0; background:#0f1115; color:#e8ebf0; font-family:-apple-system,sans-serif; }\n"
           @"h1 { margin:0; padding:32px 32px 0 32px; font-size:42px; font-weight:700; }\n"
           @".grid { display:grid; grid-template-columns:repeat(5, 1fr); gap:16px; padding:32px; max-width:94%; margin:0 auto; }\n"
           @".empty { display:flex; justify-content:center; padding:32px; }\n"
           @"a.tile { display:block; background:#1b1f27; border-radius:14px; padding:20px; text-decoration:none; color:#e8ebf0; }\n"
           @"a.tile:focus { outline:3px solid #7aa2ff; transform:scale(1.04); }\n"
           @"a.tile:hover { outline:3px solid #7aa2ff; transform:scale(1.04); }\n"
           @".avatar { width:84px; height:84px; border-radius:42px; background:#262c38; color:#aeb8cc; display:flex; align-items:center; justify-content:center; font-size:39px; font-weight:700; margin-bottom:14px; }\n"
           @".title { font-weight:700; font-size:24px; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; text-overflow:ellipsis; }\n"
           @".domain { color:#8b93a3; font-size:19.5px; margin-top:6px; overflow:hidden; white-space:nowrap; text-overflow:ellipsis; }\n"
           @"</style>\n"
           @"</head>\n";
}

@implementation BrowserLandingPage

+ (NSString *)landingHTML {
    NSMutableArray<NSString *> *tiles = [NSMutableArray array];
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesDefaultsKey];
    for (NSArray *entry in favorites) {
        if (![entry isKindOfClass:[NSArray class]] || entry.count == 0) {
            continue;
        }
        NSString *URLString = [entry[0] isKindOfClass:[NSString class]] ? entry[0] : @"";
        if (URLString.length == 0) {
            continue;
        }
        NSString *title = (entry.count > 1 && [entry[1] isKindOfClass:[NSString class]]) ? entry[1] : @"";
        NSString *displayTitle = title.length > 0 ? title : BrowserLandingDomainForURLString(URLString);
        NSString *initial = BrowserLandingHTMLEscape(BrowserLandingInitialForTitle(title, URLString));
        NSString *escapedTitle = BrowserLandingHTMLEscape(displayTitle);
        NSString *escapedDomain = BrowserLandingHTMLEscape(BrowserLandingDomainForURLString(URLString));
        NSString *escapedURL = BrowserLandingHTMLEscape(URLString);
        [tiles addObject:[NSString stringWithFormat:
            @"<a class=\"tile\" href=\"%@\" target=\"_self\">"
            @"<div class=\"avatar\">%@</div>"
            @"<div class=\"title\">%@</div>"
            @"<div class=\"domain\">%@</div>"
            @"</a>",
            escapedURL, initial, escapedTitle, escapedDomain]];
    }

    if (tiles.count == 0) {
        return [self fallbackHTMLIfEmpty];
    }

    return [NSString stringWithFormat:
        @"%@<body>\n<h1>Favorites</h1>\n<div class=\"grid\">%@</div>\n</body>\n</html>",
        BrowserLandingDocumentHead(), [tiles componentsJoinedByString:@"\n"]];
}

+ (NSString *)fallbackHTMLIfEmpty {
    NSString *hint = BrowserLandingHTMLEscape(@"No favorites yet — open the menu to add one");
    return [NSString stringWithFormat:
        @"%@<body>\n<h1>Favorites</h1>\n<div class=\"empty\"><div class=\"tile\" style=\"text-align:center\">%@</div></div>\n</body>\n</html>",
        BrowserLandingDocumentHead(), hint];
}

@end
