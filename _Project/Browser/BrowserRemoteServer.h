#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Nebula Remote: a small HTTP server on the local network so an iPhone or Mac
// browser can type into Nebula. Runs only while the app is active.
@interface BrowserRemoteServer : NSObject

// The port actually listening, or 0 while stopped.
@property (nonatomic, readonly) uint16_t port;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
