#import <Foundation/Foundation.h>

@class BrowserRemoteServer;
@class BrowserRemoteState;

NS_ASSUME_NONNULL_BEGIN

// All delegate methods are called on the main queue.
@protocol BrowserRemoteServerDelegate <NSObject>

- (void)remoteServer:(BrowserRemoteServer *)server openText:(NSString *)text inNewTab:(BOOL)newTab;
// Return NO when fieldID is not the active field (server answers 409).
- (BOOL)remoteServer:(BrowserRemoteServer *)server submitFieldText:(NSString *)text fieldID:(NSString *)fieldID submitForm:(BOOL)submitForm;
- (NSString *)remoteServerPageHTML:(BrowserRemoteServer *)server;

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
