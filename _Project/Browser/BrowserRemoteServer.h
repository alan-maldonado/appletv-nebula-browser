#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class BrowserRemoteServer;
@class BrowserRemoteState;

NS_ASSUME_NONNULL_BEGIN

// All delegate methods are called on the main queue.
@protocol BrowserRemoteServerDelegate <NSObject>

// Returns the HTTP status; *outResponse is the JSON body (nil means {"ok":true}).
- (NSInteger)remoteServer:(BrowserRemoteServer *)server
                 openText:(NSString *)text
                 inNewTab:(BOOL)newTab
                 response:(NSDictionary * _Nullable * _Nonnull)outResponse;
// Return NO when fieldID is not the active field (server answers 409).
- (BOOL)remoteServer:(BrowserRemoteServer *)server submitFieldText:(NSString *)text fieldID:(NSString *)fieldID submitForm:(BOOL)submitForm;
// Admin panel actions (tabs/…, favorites/…, home) with a payload already validated by
// BrowserRemoteActionPayload. Returns the HTTP status; *outResponse is the JSON body
// (nil means {"ok":true}).
- (NSInteger)remoteServer:(BrowserRemoteServer *)server
            performAction:(NSString *)action
                  payload:(NSDictionary *)payload
                 response:(NSDictionary * _Nullable * _Nonnull)outResponse;
// Trackpad (WebSocket /api/trackpad). Deltas are in TV points, already coalesced.
- (void)remoteServer:(BrowserRemoteServer *)server trackpadMoveBy:(CGPoint)delta;
- (void)remoteServer:(BrowserRemoteServer *)server trackpadScrollBy:(CGPoint)delta;
- (void)remoteServerTrackpadClick:(BrowserRemoteServer *)server;
- (void)remoteServerTrackpadDoubleClick:(BrowserRemoteServer *)server;
// GET /api/cursor: {x, y, mode} for diagnostics/tests.
- (NSDictionary *)remoteServerCursorState:(BrowserRemoteServer *)server;
// PNG for the iOS home-screen icon (GET /apple-touch-icon.png); nil answers 404.
- (nullable NSData *)remoteServerTouchIconPNG:(BrowserRemoteServer *)server;

@end

// Nebula Remote: a small HTTP server on the local network so an iPhone or Mac
// browser can type into Nebula. Runs only while the app is active.
@interface BrowserRemoteServer : NSObject

@property (nonatomic, weak, nullable) id<BrowserRemoteServerDelegate> delegate;
// Main thread only. Call stateDidChange after updating it.
@property (nonatomic, readonly) BrowserRemoteState *state;
// The port actually listening (8080, else 8081/8082), or 0 while stopped.
@property (nonatomic, readonly) uint16_t port;

- (void)start;
// Closes every connection, including pending long-polls, without a reply.
- (void)stop;
// Main thread: answers the waiting long-polls with the current state.
- (void)stateDidChange;

@end

NS_ASSUME_NONNULL_END
