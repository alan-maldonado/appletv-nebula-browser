#import "BrowserRemoteServer.h"

#import <Network/Network.h>

#import "BrowserRemoteHTTP.h"
#import "BrowserRemoteState.h"

static NSUInteger const kBrowserRemoteMaxConnections = 8;
static NSTimeInterval const kBrowserRemoteReceiveTimeout = 10.0;
static NSTimeInterval const kBrowserRemoteLongPollTimeout = 25.0;
static const char * const kBrowserRemotePorts[] = {"8080", "8081", "8082"};

// One client connection. Only touched on the server queue.
@interface BrowserRemoteConnection : NSObject

@property (nonatomic) nw_connection_t connection;
@property (nonatomic) NSMutableData *buffer;
@property (nonatomic) BOOL parked;    // waiting long-poll
@property (nonatomic) BOOL finished;  // replied or cancelled

@end

@implementation BrowserRemoteConnection
@end

@interface BrowserRemoteServer ()

@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, readwrite) BrowserRemoteState *state;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, nullable) nw_listener_t listener;
@property (nonatomic) NSUInteger portIndex;
// Server queue only.
@property (nonatomic) NSMutableArray<BrowserRemoteConnection *> *connections;

@end

@implementation BrowserRemoteServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("app.orbitlabs.tvbrowser.remote", DISPATCH_QUEUE_SERIAL);
        _state = [BrowserRemoteState new];
        _connections = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Lifecycle (main thread)

- (void)start {
    if (self.listener != nil) {
        return;
    }
    self.portIndex = 0;
    [self startListenerOnCurrentPort];
}

- (void)startListenerOnCurrentPort {
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create_with_port(kBrowserRemotePorts[self.portIndex], parameters);
    if (listener == nil) {
        NSLog(@"[Remote] could not create listener on %s", kBrowserRemotePorts[self.portIndex]);
        return;
    }
    self.listener = listener;

    __weak typeof(self) weakSelf = self;
    nw_listener_set_queue(listener, self.queue);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        uint16_t port = nw_listener_get_port(listener);
        int errorCode = error != nil ? nw_error_get_error_code(error) : 0;
        NSLog(@"[Remote] listener state=%d port=%u error=%d", (int)state, port, errorCode);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf listener:listener didChangeState:state port:port errorCode:errorCode];
        });
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf acceptConnection:connection];
    });
    nw_listener_start(listener);
}

- (void)listener:(nw_listener_t)listener didChangeState:(nw_listener_state_t)state port:(uint16_t)port errorCode:(int)errorCode {
    if (listener != self.listener) {
        return; // a listener we already replaced or stopped
    }
    if (state == nw_listener_state_ready) {
        self.port = port;
        return;
    }
    if (state == nw_listener_state_failed) {
        nw_listener_cancel(listener);
        self.listener = nil;
        self.port = 0;
        if (errorCode == EADDRINUSE && self.portIndex + 1 < sizeof(kBrowserRemotePorts) / sizeof(kBrowserRemotePorts[0])) {
            self.portIndex += 1;
            [self startListenerOnCurrentPort];
        }
    }
}

- (void)stop {
    if (self.listener != nil) {
        nw_listener_cancel(self.listener);
        self.listener = nil;
    }
    self.port = 0;
    dispatch_async(self.queue, ^{
        for (BrowserRemoteConnection *client in self.connections) {
            client.finished = YES;
            nw_connection_cancel(client.connection);
        }
        [self.connections removeAllObjects];
    });
}

- (void)stateDidChange {
    NSDictionary *snapshot = [self.state JSONObject];
    dispatch_async(self.queue, ^{
        for (BrowserRemoteConnection *client in [self.connections copy]) {
            if (client.parked) {
                [self finish:client data:BrowserRemoteJSONResponseData(200, snapshot)];
            }
        }
    });
}

#pragma mark - Connections (server queue)

- (void)acceptConnection:(nw_connection_t)connection {
    nw_connection_set_queue(connection, self.queue);
    if (self.connections.count >= kBrowserRemoteMaxConnections) {
        nw_connection_cancel(connection);
        return;
    }

    BrowserRemoteConnection *client = [BrowserRemoteConnection new];
    client.connection = connection;
    client.buffer = [NSMutableData data];
    [self.connections addObject:client];
    nw_connection_start(connection);

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserRemoteReceiveTimeout * NSEC_PER_SEC)), self.queue, ^{
        if (!client.finished && !client.parked) {
            [weakSelf close:client];
        }
    });
    [self receiveOn:client];
}

- (void)receiveOn:(BrowserRemoteConnection *)client {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(client.connection, 1, 65536, ^(dispatch_data_t content, __unused nw_content_context_t context, bool isComplete, nw_error_t error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || client.finished) {
            return;
        }
        if (content != nil) {
            dispatch_data_apply(content, ^bool(__unused dispatch_data_t region, __unused size_t offset, const void *bytes, size_t size) {
                [client.buffer appendBytes:bytes length:size];
                return true;
            });
        }

        BrowserRemoteRequest *request = nil;
        BrowserRemoteParseStatus status = BrowserRemoteParseRequest(client.buffer, &request);
        switch (status) {
            case BrowserRemoteParseStatusComplete:
                [strongSelf route:request client:client];
                return;
            case BrowserRemoteParseStatusInvalid:
                [strongSelf finish:client data:BrowserRemoteJSONResponseData(400, @{@"error": @"bad-request"})];
                return;
            case BrowserRemoteParseStatusTooLarge:
                [strongSelf finish:client data:BrowserRemoteJSONResponseData(413, @{@"error": @"too-large"})];
                return;
            case BrowserRemoteParseStatusIncomplete:
                if (error != nil || isComplete) {
                    [strongSelf close:client];
                } else {
                    [strongSelf receiveOn:client];
                }
                return;
        }
    });
}

- (void)route:(BrowserRemoteRequest *)request client:(BrowserRemoteConnection *)client {
    NSDictionary<NSString *, NSString *> *methodsByPath = @{
        @"/": @"GET",
        @"/apple-touch-icon.png": @"GET",
        @"/api/state": @"GET",
        @"/api/open": @"POST",
        @"/api/field": @"POST",
    };
    if (!BrowserRemoteRequestHasTrustedHost(request)) {
        [self finish:client data:BrowserRemoteJSONResponseData(403, @{@"error": @"untrusted-host"})];
        return;
    }
    if ([request.method isEqualToString:@"POST"] && !BrowserRemoteRequestHasJSONContentType(request)) {
        [self finish:client data:BrowserRemoteJSONResponseData(415, @{@"error": @"json-required"})];
        return;
    }
    NSString *expectedMethod = methodsByPath[request.path];
    if (expectedMethod == nil) {
        [self finish:client data:BrowserRemoteJSONResponseData(404, @{@"error": @"not-found"})];
        return;
    }
    if (![request.method isEqualToString:expectedMethod]) {
        [self finish:client data:BrowserRemoteJSONResponseData(405, @{@"error": @"method-not-allowed"})];
        return;
    }

    if ([request.path isEqualToString:@"/"]) {
        [self onMain:client respond:^NSData *{
            NSString *HTML = [self.delegate remoteServerPageHTML:self] ?: @"";
            return BrowserRemoteResponseData(200, @"text/html; charset=utf-8", [HTML dataUsingEncoding:NSUTF8StringEncoding]);
        }];
    } else if ([request.path isEqualToString:@"/apple-touch-icon.png"]) {
        [self onMain:client respond:^NSData *{
            NSData *PNG = [self.delegate remoteServerTouchIconPNG:self];
            return PNG != nil
                ? BrowserRemoteResponseData(200, @"image/png", PNG)
                : BrowserRemoteJSONResponseData(404, @{@"error": @"not-found"});
        }];
    } else if ([request.path isEqualToString:@"/api/state"]) {
        NSUInteger seenVersion = (NSUInteger)MAX(0, [request.query[@"v"] integerValue]);
        [self handleStateRequestWithSeenVersion:seenVersion client:client];
    } else if ([request.path isEqualToString:@"/api/open"]) {
        BOOL newTab = NO;
        NSString *text = BrowserRemoteOpenPayloadFromJSON([request JSONBody], &newTab);
        if (text == nil) {
            [self finish:client data:BrowserRemoteJSONResponseData(400, @{@"error": @"invalid-request"})];
            return;
        }
        [self onMain:client respond:^NSData *{
            [self.delegate remoteServer:self openText:text inNewTab:newTab];
            return BrowserRemoteJSONResponseData(200, @{@"ok": @YES});
        }];
    } else {
        NSDictionary *payload = BrowserRemoteFieldPayloadFromJSON([request JSONBody]);
        if (payload == nil) {
            [self finish:client data:BrowserRemoteJSONResponseData(400, @{@"error": @"invalid-request"})];
            return;
        }
        [self onMain:client respond:^NSData *{
            BOOL accepted = [self.delegate remoteServer:self
                                        submitFieldText:payload[@"text"]
                                                fieldID:payload[@"id"]
                                             submitForm:[payload[@"submit"] boolValue]];
            return accepted
                ? BrowserRemoteJSONResponseData(200, @{@"ok": @YES})
                : BrowserRemoteJSONResponseData(409, @{@"error": @"field-not-active"});
        }];
    }
}

- (void)handleStateRequestWithSeenVersion:(NSUInteger)seenVersion client:(BrowserRemoteConnection *)client {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSDictionary *snapshot = [strongSelf.state JSONObject];
        BOOL changed = seenVersion != strongSelf.state.version;
        dispatch_async(strongSelf.queue, ^{
            if (client.finished) {
                return;
            }
            if (changed) {
                [strongSelf finish:client data:BrowserRemoteJSONResponseData(200, snapshot)];
                return;
            }
            client.parked = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserRemoteLongPollTimeout * NSEC_PER_SEC)), strongSelf.queue, ^{
                if (client.finished) {
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSDictionary *current = [strongSelf.state JSONObject];
                    dispatch_async(strongSelf.queue, ^{
                        [strongSelf finish:client data:BrowserRemoteJSONResponseData(200, current)];
                    });
                });
            });
        });
    });
}

// Runs `respond` on the main queue (delegate and state live there), then sends its data.
- (void)onMain:(BrowserRemoteConnection *)client respond:(NSData *(^)(void))respond {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData *data = respond();
        dispatch_async(self.queue, ^{
            [self finish:client data:data];
        });
    });
}

- (void)finish:(BrowserRemoteConnection *)client data:(NSData *)data {
    if (client.finished) {
        return;
    }
    client.finished = YES;
    client.parked = NO;
    [self.connections removeObject:client];
    NSData *payload = [data copy];
    dispatch_data_t content = dispatch_data_create(payload.bytes, payload.length, self.queue, ^{
        (void)payload; // keep the bytes alive until Network.framework is done with them
    });
    nw_connection_t connection = client.connection;
    nw_connection_send(connection, content, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(__unused nw_error_t error) {
        nw_connection_cancel(connection);
    });
}

- (void)close:(BrowserRemoteConnection *)client {
    if (client.finished) {
        return;
    }
    client.finished = YES;
    client.parked = NO;
    [self.connections removeObject:client];
    nw_connection_cancel(client.connection);
}

@end
