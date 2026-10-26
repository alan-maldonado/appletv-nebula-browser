#import "BrowserRemoteWebSocket.h"

#import <CommonCrypto/CommonDigest.h>

static NSString * const kBrowserRemoteWebSocketGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
static double const kBrowserRemoteTrackpadMaxDelta = 500.0;

@interface BrowserRemoteFrame ()

@property (nonatomic, readwrite) uint8_t opcode;
@property (nonatomic, readwrite) NSData *payload;

@end

@implementation BrowserRemoteFrame
@end

NSString *BrowserRemoteWebSocketAccept(NSString *key) {
    NSData *input = [[key stringByAppendingString:kBrowserRemoteWebSocketGUID] dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(input.bytes, (CC_LONG)input.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

static BOOL BrowserRemoteHeaderContainsToken(NSString *value, NSString *token) {
    for (NSString *part in [value.lowercaseString componentsSeparatedByString:@","]) {
        if ([[part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:token]) {
            return YES;
        }
    }
    return NO;
}

BOOL BrowserRemoteRequestIsWebSocketUpgrade(BrowserRemoteRequest *request) {
    NSDictionary<NSString *, NSString *> *headers = request.headers;
    return [request.method isEqualToString:@"GET"] &&
        BrowserRemoteHeaderContainsToken(headers[@"upgrade"], @"websocket") &&
        BrowserRemoteHeaderContainsToken(headers[@"connection"], @"upgrade") &&
        [headers[@"sec-websocket-version"] isEqualToString:@"13"] &&
        headers[@"sec-websocket-key"].length > 0;
}

NSData *BrowserRemoteWebSocketHandshakeResponse(NSString *key) {
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\n"
                                                     "Upgrade: websocket\r\n"
                                                     "Connection: Upgrade\r\n"
                                                     "Sec-WebSocket-Accept: %@\r\n\r\n",
                          BrowserRemoteWebSocketAccept(key)];
    return [response dataUsingEncoding:NSUTF8StringEncoding];
}

BrowserRemoteFrameStatus BrowserRemoteDecodeFrame(NSData *buffer, BrowserRemoteFrame **outFrame, NSUInteger *outConsumed) {
    const uint8_t *bytes = buffer.bytes;
    NSUInteger length = buffer.length;
    if (length < 2) {
        return BrowserRemoteFrameStatusIncomplete;
    }

    BOOL final = (bytes[0] & 0x80) != 0;
    uint8_t opcode = bytes[0] & 0x0f;
    BOOL masked = (bytes[1] & 0x80) != 0;
    uint8_t shortLength = bytes[1] & 0x7f;
    BOOL knownOpcode = opcode == 1 || opcode == 8 || opcode == 9 || opcode == 10;
    if (!final || !masked || !knownOpcode || (bytes[0] & 0x70) != 0 || shortLength == 127) {
        return BrowserRemoteFrameStatusProtocolError;
    }

    NSUInteger headerLength = 2;
    NSUInteger payloadLength = shortLength;
    if (shortLength == 126) {
        if (length < 4) {
            return BrowserRemoteFrameStatusIncomplete;
        }
        payloadLength = ((NSUInteger)bytes[2] << 8) | bytes[3];
        headerLength = 4;
    }
    if (payloadLength > kBrowserRemoteWebSocketMaxPayload) {
        return BrowserRemoteFrameStatusTooLarge;
    }

    NSUInteger frameLength = headerLength + 4 + payloadLength;
    if (length < frameLength) {
        return BrowserRemoteFrameStatusIncomplete;
    }

    const uint8_t *mask = bytes + headerLength;
    NSMutableData *payload = [NSMutableData dataWithLength:payloadLength];
    uint8_t *unmasked = payload.mutableBytes;
    for (NSUInteger index = 0; index < payloadLength; index++) {
        unmasked[index] = bytes[headerLength + 4 + index] ^ mask[index % 4];
    }

    if (outFrame != NULL) {
        BrowserRemoteFrame *frame = [BrowserRemoteFrame new];
        frame.opcode = opcode;
        frame.payload = payload;
        *outFrame = frame;
    }
    if (outConsumed != NULL) {
        *outConsumed = frameLength;
    }
    return BrowserRemoteFrameStatusFrame;
}

NSData *BrowserRemoteEncodeFrame(uint8_t opcode, NSData *payload) {
    NSMutableData *frame = [NSMutableData data];
    uint8_t first = 0x80 | (opcode & 0x0f);
    [frame appendBytes:&first length:1];
    if (payload.length < 126) {
        uint8_t length = (uint8_t)payload.length;
        [frame appendBytes:&length length:1];
    } else {
        uint8_t length[3] = {126, (uint8_t)(payload.length >> 8), (uint8_t)(payload.length & 0xff)};
        [frame appendBytes:length length:3];
    }
    [frame appendData:payload];
    return frame;
}

NSData *BrowserRemoteCloseFrame(uint16_t code) {
    uint8_t body[2] = {(uint8_t)(code >> 8), (uint8_t)(code & 0xff)};
    return BrowserRemoteEncodeFrame(8, [NSData dataWithBytes:body length:2]);
}

static double BrowserRemoteClampDelta(double value) {
    return MAX(-kBrowserRemoteTrackpadMaxDelta, MIN(kBrowserRemoteTrackpadMaxDelta, value));
}

BrowserRemoteTrackpadKind BrowserRemoteParseTrackpadMessage(NSData *payload, double *outDX, double *outDY) {
    id JSON = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![JSON isKindOfClass:[NSDictionary class]] || ![JSON[@"t"] isKindOfClass:[NSString class]]) {
        return BrowserRemoteTrackpadKindNone;
    }
    NSString *type = JSON[@"t"];
    if ([type isEqualToString:@"c"]) {
        return BrowserRemoteTrackpadKindClick;
    }
    if ([type isEqualToString:@"d"]) {
        return BrowserRemoteTrackpadKindDoubleClick;
    }
    if (![type isEqualToString:@"m"] && ![type isEqualToString:@"s"]) {
        return BrowserRemoteTrackpadKindNone;
    }
    id dx = JSON[@"dx"];
    id dy = JSON[@"dy"];
    if (![dx isKindOfClass:[NSNumber class]] || ![dy isKindOfClass:[NSNumber class]]) {
        return BrowserRemoteTrackpadKindNone;
    }
    *outDX = BrowserRemoteClampDelta([dx doubleValue]);
    *outDY = BrowserRemoteClampDelta([dy doubleValue]);
    return [type isEqualToString:@"m"] ? BrowserRemoteTrackpadKindMove : BrowserRemoteTrackpadKindScroll;
}
