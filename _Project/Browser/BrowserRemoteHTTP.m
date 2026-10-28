#import "BrowserRemoteHTTP.h"

@interface BrowserRemoteRequest ()

@property (nonatomic, readwrite) NSString *method;
@property (nonatomic, readwrite) NSString *path;
@property (nonatomic, readwrite) NSDictionary<NSString *, NSString *> *query;
@property (nonatomic, readwrite) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, readwrite) NSData *body;

@end

@implementation BrowserRemoteRequest

- (id)JSONBody {
    if (self.body.length == 0) {
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:self.body options:0 error:nil];
}

@end

static NSDictionary<NSString *, NSString *> *BrowserRemoteQueryFromTarget(NSString *target) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"http://localhost" stringByAppendingString:target]];
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        query[item.name] = item.value ?: @"";
    }
    return query;
}

BrowserRemoteParseStatus BrowserRemoteParseRequest(NSData *buffer, BrowserRemoteRequest **outRequest) {
    if (outRequest != NULL) {
        *outRequest = nil;
    }

    NSData *terminator = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSRange headerEnd = [buffer rangeOfData:terminator options:0 range:NSMakeRange(0, buffer.length)];
    if (headerEnd.location == NSNotFound) {
        return buffer.length > kBrowserRemoteMaxHeaderBytes ? BrowserRemoteParseStatusTooLarge : BrowserRemoteParseStatusIncomplete;
    }
    if (headerEnd.location > kBrowserRemoteMaxHeaderBytes) {
        return BrowserRemoteParseStatusTooLarge;
    }

    NSString *headerText = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, headerEnd.location)]
                                                 encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (requestLine.count != 3 || ![requestLine[1] hasPrefix:@"/"] || ![requestLine[2] hasPrefix:@"HTTP/1."]) {
        return BrowserRemoteParseStatusInvalid;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSRange colon = [lines[index] rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            return BrowserRemoteParseStatusInvalid;
        }
        NSString *name = [[lines[index] substringToIndex:colon.location] lowercaseString];
        NSString *value = [[lines[index] substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        headers[name] = value;
    }

    NSInteger contentLength = 0;
    if (headers[@"content-length"] != nil) {
        NSScanner *scanner = [NSScanner scannerWithString:headers[@"content-length"]];
        if (![scanner scanInteger:&contentLength] || !scanner.isAtEnd || contentLength < 0) {
            return BrowserRemoteParseStatusInvalid;
        }
    }
    if ((NSUInteger)contentLength > kBrowserRemoteMaxBodyBytes) {
        return BrowserRemoteParseStatusTooLarge;
    }

    NSUInteger bodyStart = NSMaxRange(headerEnd);
    if (buffer.length - bodyStart < (NSUInteger)contentLength) {
        return BrowserRemoteParseStatusIncomplete;
    }

    NSString *target = requestLine[1];
    NSRange queryMark = [target rangeOfString:@"?"];
    BrowserRemoteRequest *request = [BrowserRemoteRequest new];
    request.method = requestLine[0];
    request.path = queryMark.location == NSNotFound ? target : [target substringToIndex:queryMark.location];
    request.query = BrowserRemoteQueryFromTarget(target);
    request.headers = headers;
    request.body = [buffer subdataWithRange:NSMakeRange(bodyStart, (NSUInteger)contentLength)];
    if (outRequest != NULL) {
        *outRequest = request;
    }
    return BrowserRemoteParseStatusComplete;
}

BOOL BrowserRemoteRequestHasTrustedHost(BrowserRemoteRequest *request) {
    NSString *host = [request.headers[@"host"] lowercaseString];
    if (host.length == 0) {
        return NO;
    }
    if ([host hasPrefix:@"["]) {
        return [host containsString:@"]"]; // IPv6 literal, e.g. [fe80::1]:8080
    }
    NSRange colon = [host rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        host = [host substringToIndex:colon.location];
    }
    if ([host isEqualToString:@"localhost"] || [host hasSuffix:@".local"]) {
        return YES;
    }
    // Names served by the LAN reverse proxy (nginx on zima).
    if ([host hasSuffix:@".lan"] || [host hasSuffix:@".orbitware.app"]) {
        return YES;
    }
    NSCharacterSet *notIPv4 = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
    return [host rangeOfCharacterFromSet:notIPv4].location == NSNotFound && [host componentsSeparatedByString:@"."].count == 4;
}

BOOL BrowserRemoteRequestHasJSONContentType(BrowserRemoteRequest *request) {
    NSString *contentType = [request.headers[@"content-type"] lowercaseString];
    NSString *mediaType = [[contentType componentsSeparatedByString:@";"].firstObject
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [mediaType isEqualToString:@"application/json"];
}

static NSString *BrowserRemoteReasonPhrase(NSInteger status) {
    switch (status) {
        case 200: return @"OK";
        case 400: return @"Bad Request";
        case 403: return @"Forbidden";
        case 415: return @"Unsupported Media Type";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 409: return @"Conflict";
        case 413: return @"Payload Too Large";
        default: return @"Error";
    }
}

NSData *BrowserRemoteResponseData(NSInteger status, NSString *contentType, NSData *body) {
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\n"
                                                 "Content-Type: %@\r\n"
                                                 "Content-Length: %lu\r\n"
                                                 "Connection: close\r\n"
                                                 "Cache-Control: no-store\r\n\r\n",
                      (long)status, BrowserRemoteReasonPhrase(status), contentType, (unsigned long)body.length];
    NSMutableData *data = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [data appendData:body];
    return data;
}

NSData *BrowserRemoteJSONResponseData(NSInteger status, id JSONObject) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:JSONObject options:0 error:nil] ?: [NSData data];
    return BrowserRemoteResponseData(status, @"application/json; charset=utf-8", body);
}

NSString *BrowserRemoteOpenPayloadFromJSON(id JSON, BOOL *outNewTab) {
    if (![JSON isKindOfClass:[NSDictionary class]] || ![JSON[@"text"] isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *text = [JSON[@"text"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        return nil;
    }
    id newTab = JSON[@"newTab"];
    *outNewTab = [newTab respondsToSelector:@selector(boolValue)] ? [newTab boolValue] : NO;
    return text;
}

NSDictionary *BrowserRemoteFieldPayloadFromJSON(id JSON) {
    if (![JSON isKindOfClass:[NSDictionary class]] ||
        ![JSON[@"id"] isKindOfClass:[NSString class]] ||
        ![JSON[@"text"] isKindOfClass:[NSString class]]) {
        return nil;
    }
    id submit = JSON[@"submit"];
    return @{
        @"id": JSON[@"id"],
        @"text": JSON[@"text"],
        @"submit": @([submit respondsToSelector:@selector(boolValue)] ? [submit boolValue] : NO),
    };
}

BOOL BrowserRemoteIsWebURLString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSURL *URL = [NSURL URLWithString:[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    NSString *scheme = URL.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && URL.host.length > 0;
}

static NSString *BrowserRemoteTrimmed(NSString *string) {
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Trimmed string, or @"" for anything that isn't a string.
static NSString *BrowserRemoteTrimmedString(id value) {
    return [value isKindOfClass:[NSString class]] ? BrowserRemoteTrimmed(value) : @"";
}

static NSDictionary *BrowserRemoteInvalidPayload(NSString **outErrorCode, NSString *code) {
    if (outErrorCode != NULL) {
        *outErrorCode = code;
    }
    return nil;
}

NSDictionary *BrowserRemoteActionPayload(NSString *action, id JSON, NSString **outErrorCode) {
    if (outErrorCode != NULL) {
        *outErrorCode = nil;
    }
    if (![JSON isKindOfClass:[NSDictionary class]]) {
        return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
    }
    NSDictionary *body = JSON;

    if ([action isEqualToString:@"tabs/switch"] || [action isEqualToString:@"tabs/close"]) {
        NSString *identifier = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
        return identifier.length > 0 ? @{@"id": identifier} : BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
    }
    if ([action isEqualToString:@"tabs/new"]) {
        return @{};
    }

    if ([action isEqualToString:@"media"]) {
        // {command: toggle|play|pause|exit-fullscreen} | {command: seek, time} | {command: skip, delta} (seconds).
        NSString *command = [body[@"command"] isKindOfClass:[NSString class]] ? body[@"command"] : nil;
        if ([@[@"toggle", @"play", @"pause", @"exit-fullscreen"] containsObject:command ?: @""]) {
            return @{@"command": command};
        }
        NSString *key = [command isEqualToString:@"seek"] ? @"time" : ([command isEqualToString:@"skip"] ? @"delta" : nil);
        id value = key != nil ? body[key] : nil;
        if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue]) ||
            ([command isEqualToString:@"seek"] && [value doubleValue] < 0.0)) {
            return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
        }
        return @{@"command": command, key: @([value doubleValue])};
    }

    if ([action isEqualToString:@"home"]) {
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        if ([body[@"useCurrent"] respondsToSelector:@selector(boolValue)] && [body[@"useCurrent"] boolValue]) {
            payload[@"useCurrent"] = @YES;
        } else if (body[@"url"] != nil) {
            if (!BrowserRemoteIsWebURLString(body[@"url"])) {
                return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-url");
            }
            payload[@"url"] = BrowserRemoteTrimmed(body[@"url"]);
        }
        if (body[@"launch"] != nil) {
            if (![@[@"last-session", @"home-page"] containsObject:body[@"launch"]]) {
                return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-launch");
            }
            payload[@"launch"] = body[@"launch"];
        }
        if (body[@"favorites"] != nil) {
            if (![body[@"favorites"] isKindOfClass:[NSNumber class]]) {
                return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
            }
            payload[@"favorites"] = @([body[@"favorites"] boolValue]);
        }
        return payload.count > 0 ? payload : BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
    }
    if ([action isEqualToString:@"favorites/add"]) {
        if ([body[@"current"] respondsToSelector:@selector(boolValue)] && [body[@"current"] boolValue]) {
            return @{@"current": @YES};
        }
        if (!BrowserRemoteIsWebURLString(body[@"url"])) {
            return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-url");
        }
        return @{@"url": BrowserRemoteTrimmed(body[@"url"]), @"title": BrowserRemoteTrimmedString(body[@"title"])};
    }
    if ([action hasPrefix:@"favorites/"]) {
        // update/remove/move/open all target {index, url}: the URL guards against a list
        // that changed on the TV since the panel rendered it.
        if (![body[@"index"] isKindOfClass:[NSNumber class]] || ![body[@"url"] isKindOfClass:[NSString class]]) {
            return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
        }
        NSInteger index = [body[@"index"] integerValue];
        if (index < 0) {
            return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-index");
        }
        NSMutableDictionary *payload = [@{@"index": @(index), @"url": body[@"url"]} mutableCopy];
        if ([action isEqualToString:@"favorites/remove"]) {
            return payload;
        }
        if ([action isEqualToString:@"favorites/open"]) {
            id newTab = body[@"newTab"];
            payload[@"newTab"] = @([newTab respondsToSelector:@selector(boolValue)] && [newTab boolValue]);
            return payload;
        }
        if ([action isEqualToString:@"favorites/move"]) {
            if (![body[@"to"] isKindOfClass:[NSNumber class]]) {
                return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
            }
            if ([body[@"to"] integerValue] < 0) {
                return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-index");
            }
            payload[@"to"] = @([body[@"to"] integerValue]);
            return payload;
        }
        if ([action isEqualToString:@"favorites/update"]) {
            if (![body[@"title"] isKindOfClass:[NSString class]]) {
                return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
            }
            NSString *newURL = body[@"newURL"] != nil ? body[@"newURL"] : body[@"url"];
            if (!BrowserRemoteIsWebURLString(newURL)) {
                return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-url");
            }
            payload[@"title"] = BrowserRemoteTrimmed(body[@"title"]);
            payload[@"newURL"] = BrowserRemoteTrimmed(newURL);
            return payload;
        }
    }
    return BrowserRemoteInvalidPayload(outErrorCode, @"invalid-request");
}
