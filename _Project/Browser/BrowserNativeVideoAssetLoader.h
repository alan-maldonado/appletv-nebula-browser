#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoAssetLoader : NSObject

- (instancetype)initWithRequestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                               cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// Recently captured master playlist URLs (e.g. the probe system's freshest
// load-playlist-multi captures), oldest-first. When a media-playlist request
// 403/404s, a request in the same /playlist/<ID>/ family is retried against
// the freshest matching master.
@property (nonatomic, copy, nullable) NSArray<NSURL *> *fresherMasterURLs;

- (NSURL *)assetURLForPlaybackURL:(NSURL *)playbackURL;
- (BOOL)attachToAsset:(id)asset;

@end

NS_ASSUME_NONNULL_END
