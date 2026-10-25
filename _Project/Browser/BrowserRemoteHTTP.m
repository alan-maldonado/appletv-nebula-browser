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

static NSString *BrowserRemoteReasonPhrase(NSInteger status) {
    switch (status) {
        case 200: return @"OK";
        case 400: return @"Bad Request";
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
