#import <Foundation/Foundation.h>

#import "BrowserRemoteHTTP.h"

NS_ASSUME_NONNULL_BEGIN

// Minimal RFC 6455 support for the Nebula Remote trackpad: handshake, client
// frame decoding (masked, final, text/close/ping/pong, ≤ 1 KB) and the few
// server frames we send. Foundation + CommonCrypto only (tested on macOS).

static const NSUInteger kBrowserRemoteWebSocketMaxPayload = 1024;

typedef NS_ENUM(NSInteger, BrowserRemoteFrameStatus) {
    BrowserRemoteFrameStatusIncomplete,
    BrowserRemoteFrameStatusFrame,
    BrowserRemoteFrameStatusProtocolError,
    BrowserRemoteFrameStatusTooLarge,
};

@interface BrowserRemoteFrame : NSObject

@property (nonatomic, readonly) uint8_t opcode;   // 1 text, 8 close, 9 ping, 10 pong
@property (nonatomic, readonly) NSData *payload;  // unmasked

@end

NSString *BrowserRemoteWebSocketAccept(NSString *key);
BOOL BrowserRemoteRequestIsWebSocketUpgrade(BrowserRemoteRequest *request);
NSData *BrowserRemoteWebSocketHandshakeResponse(NSString *key);
// Cross-site WebSocket hijacking guard: browsers don't apply CORS to WebSockets, so a
// page from another site must be refused. Allowed when there is no Origin (native
// clients) or when Origin's host:port equals the Host header.
BOOL BrowserRemoteWebSocketOriginAllowed(BrowserRemoteRequest *request);

// Decodes the first frame in buffer; *outConsumed is the frame's byte length when
// the status is Frame.
BrowserRemoteFrameStatus BrowserRemoteDecodeFrame(NSData *buffer,
                                                  BrowserRemoteFrame * _Nullable * _Nullable outFrame,
                                                  NSUInteger *outConsumed);
// Server frame: FIN set, unmasked.
NSData *BrowserRemoteEncodeFrame(uint8_t opcode, NSData *payload);
NSData *BrowserRemoteCloseFrame(uint16_t code);

typedef NS_ENUM(NSInteger, BrowserRemoteTrackpadKind) {
    BrowserRemoteTrackpadKindNone,
    BrowserRemoteTrackpadKindMove,
    BrowserRemoteTrackpadKindScroll,
    BrowserRemoteTrackpadKindClick,
    BrowserRemoteTrackpadKindDoubleClick,
};

// {"t":"m"|"s","dx":n,"dy":n} (deltas clamped to ±500), {"t":"c"}, {"t":"d"}; else None.
BrowserRemoteTrackpadKind BrowserRemoteParseTrackpadMessage(NSData *payload, double *outDX, double *outDY);

NS_ASSUME_NONNULL_END
