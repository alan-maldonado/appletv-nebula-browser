#import "BrowserRemoteServer.h"

#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>

#import "BrowserRemoteHTTP.h"
#import "BrowserRemoteState.h"
#import "BrowserRemoteWebSocket.h"

static NSUInteger const kBrowserRemoteMaxConnections = 8;
static NSTimeInterval const kBrowserRemoteReceiveTimeout = 10.0;
static NSTimeInterval const kBrowserRemoteLongPollTimeout = 25.0;
// A trackpad socket with no frames (moves or the panel's 20 s keepalive) for this long
// is closed, so idle/half-open sockets can't hold the 8 connection slots.
static NSTimeInterval const kBrowserRemoteWebSocketIdleTimeout = 60.0;
static const char * const kBrowserRemotePorts[] = {"8080", "8081", "8082"};

// One client connection. Only touched on the server queue.
@interface BrowserRemoteConnection : NSObject

@property (nonatomic) nw_connection_t connection;
@property (nonatomic) NSMutableData *buffer;
@property (nonatomic) BOOL parked;    // waiting long-poll
@property (nonatomic) BOOL finished;  // replied or cancelled
@property (nonatomic) BOOL webSocket; // upgraded trackpad connection
// Trackpad deltas accumulated on the server queue; at most one hop to main per kind.
@property (nonatomic) CGPoint pendingMove;
@property (nonatomic) CGPoint pendingScroll;
@property (nonatomic) BOOL moveScheduled;
@property (nonatomic) BOOL scrollScheduled;
@property (nonatomic) CFTimeInterval lastFrameTime;

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
        for (BrowserRemoteConnection *client in [self.connections copy]) {
            if (client.webSocket) {
                [self closeWebSocket:client code:1001]; // going away
            } else {
                client.finished = YES;
                nw_connection_cancel(client.connection);
            }
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
        if (!client.finished && !client.parked && !client.webSocket) {
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
        @"/app.css": @"GET",
        @"/app.js": @"GET",
        @"/apple-touch-icon.png": @"GET",
        @"/api/trackpad": @"GET",
        @"/api/cursor": @"GET",
        @"/api/state": @"GET",
        @"/api/open": @"POST",
        @"/api/field": @"POST",
        @"/api/tabs/switch": @"POST",
        @"/api/tabs/close": @"POST",
        @"/api/tabs/new": @"POST",
        @"/api/favorites/add": @"POST",
        @"/api/favorites/update": @"POST",
        @"/api/favorites/remove": @"POST",
        @"/api/favorites/move": @"POST",
        @"/api/favorites/open": @"POST",
        @"/api/home": @"POST",
        @"/api/media": @"POST",
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

    NSDictionary<NSString *, NSArray<NSString *> *> *staticFiles = @{
        @"/": @[@"index", @"html", @"text/html; charset=utf-8"],
        @"/app.css": @[@"app", @"css", @"text/css; charset=utf-8"],
        @"/app.js": @[@"app", @"js", @"application/javascript; charset=utf-8"],
    };
    if ([request.path isEqualToString:@"/api/trackpad"]) {
        [self upgradeTrackpadClient:client request:request];
        return;
    }
    if ([request.path isEqualToString:@"/api/cursor"]) {
        [self onMain:client respond:^NSData *{
            return BrowserRemoteJSONResponseData(200, [self.delegate remoteServerCursorState:self] ?: @{});
        }];
        return;
    }
    NSArray<NSString *> *staticFile = staticFiles[request.path];
    if (staticFile != nil) {
        // Whitelisted panel files from the bundle's RemotePanel folder; nothing else is served.
        NSURL *fileURL = [NSBundle.mainBundle URLForResource:staticFile[0] withExtension:staticFile[1] subdirectory:@"RemotePanel"];
        NSData *contents = fileURL != nil ? [NSData dataWithContentsOfURL:fileURL] : nil;
        [self finish:client data:contents != nil
            ? BrowserRemoteResponseData(200, staticFile[2], contents)
            : BrowserRemoteJSONResponseData(404, @{@"error": @"not-found"})];
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
            NSDictionary *response = nil;
            NSInteger status = [self.delegate remoteServer:self openText:text inNewTab:newTab response:&response];
            return BrowserRemoteJSONResponseData(status, response ?: @{@"ok": @YES});
        }];
    } else if (![request.path isEqualToString:@"/api/field"]) {
        // Admin actions: validated here, executed by the delegate on the main queue.
        NSString *action = [request.path substringFromIndex:@"/api/".length];
        NSString *errorCode = nil;
        NSDictionary *payload = BrowserRemoteActionPayload(action, [request JSONBody], &errorCode);
        if (payload == nil) {
            [self finish:client data:BrowserRemoteJSONResponseData(400, @{@"error": errorCode ?: @"invalid-request"})];
            return;
        }
        [self onMain:client respond:^NSData *{
            NSDictionary *response = nil;
            NSInteger status = [self.delegate remoteServer:self performAction:action payload:payload response:&response];
            return BrowserRemoteJSONResponseData(status, response ?: @{@"ok": @YES});
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

#pragma mark - Trackpad WebSocket (server queue)

- (void)upgradeTrackpadClient:(BrowserRemoteConnection *)client request:(BrowserRemoteRequest *)request {
    if (!BrowserRemoteRequestIsWebSocketUpgrade(request)) {
        [self finish:client data:BrowserRemoteJSONResponseData(400, @{@"error": @"websocket-required"})];
        return;
    }
    if (!BrowserRemoteWebSocketOriginAllowed(request)) {
        [self finish:client data:BrowserRemoteJSONResponseData(403, @{@"error": @"cross-origin"})];
        return;
    }
    // Frames may already follow the request in the buffer: keep the bytes after the headers.
    NSData *terminator = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSRange headerEnd = [client.buffer rangeOfData:terminator options:0 range:NSMakeRange(0, client.buffer.length)];
    NSUInteger frameStart = NSMaxRange(headerEnd);
    client.buffer = [[client.buffer subdataWithRange:NSMakeRange(frameStart, client.buffer.length - frameStart)] mutableCopy];
    client.webSocket = YES;
    client.lastFrameTime = CACurrentMediaTime();
    [self send:BrowserRemoteWebSocketHandshakeResponse(request.headers[@"sec-websocket-key"]) to:client];
    [self scheduleIdleCheckForClient:client];
    if ([self processWebSocketFrames:client]) {
        [self receiveWebSocket:client];
    }
}

- (void)receiveWebSocket:(BrowserRemoteConnection *)client {
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
        if (![strongSelf processWebSocketFrames:client]) {
            return;
        }
        if (error != nil || isComplete) {
            [strongSelf close:client];
        } else {
            [strongSelf receiveWebSocket:client];
        }
    });
}

// Handles every complete frame in the buffer. Returns NO once the connection is closing.
- (BOOL)processWebSocketFrames:(BrowserRemoteConnection *)client {
    while (!client.finished) {
        BrowserRemoteFrame *frame = nil;
        NSUInteger consumed = 0;
        BrowserRemoteFrameStatus status = BrowserRemoteDecodeFrame(client.buffer, &frame, &consumed);
        if (status == BrowserRemoteFrameStatusIncomplete) {
            return YES;
        }
        if (status == BrowserRemoteFrameStatusProtocolError || status == BrowserRemoteFrameStatusTooLarge) {
            [self closeWebSocket:client code:status == BrowserRemoteFrameStatusTooLarge ? 1009 : 1002];
            return NO;
        }
        [client.buffer replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
        client.lastFrameTime = CACurrentMediaTime();
        switch (frame.opcode) {
            case 1:
                [self handleTrackpadMessage:frame.payload client:client];
                break;
            case 8:
                [self closeWebSocket:client code:1000];
                return NO;
            case 9:
                [self send:BrowserRemoteEncodeFrame(10, frame.payload) to:client];
                break;
            default:
                break; // pong
        }
    }
    return NO;
}

- (void)handleTrackpadMessage:(NSData *)payload client:(BrowserRemoteConnection *)client {
    double dx = 0.0, dy = 0.0;
    BrowserRemoteTrackpadKind kind = BrowserRemoteParseTrackpadMessage(payload, &dx, &dy);
    switch (kind) {
        case BrowserRemoteTrackpadKindMove:
            client.pendingMove = CGPointMake(client.pendingMove.x + dx, client.pendingMove.y + dy);
            if (!client.moveScheduled) {
                client.moveScheduled = YES;
                [self deliverPendingMoveForClient:client];
            }
            break;
        case BrowserRemoteTrackpadKindScroll:
            client.pendingScroll = CGPointMake(client.pendingScroll.x + dx, client.pendingScroll.y + dy);
            if (!client.scrollScheduled) {
                client.scrollScheduled = YES;
                [self deliverPendingScrollForClient:client];
            }
            break;
        case BrowserRemoteTrackpadKindClick:
        case BrowserRemoteTrackpadKindDoubleClick: {
            BOOL isDouble = kind == BrowserRemoteTrackpadKindDoubleClick;
            // Apply the movement that preceded the click first, so it lands where aimed.
            CGPoint move = client.pendingMove;
            CGPoint scroll = client.pendingScroll;
            client.pendingMove = CGPointZero;
            client.pendingScroll = CGPointZero;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!CGPointEqualToPoint(move, CGPointZero)) {
                    [self.delegate remoteServer:self trackpadMoveBy:move];
                }
                if (!CGPointEqualToPoint(scroll, CGPointZero)) {
                    [self.delegate remoteServer:self trackpadScrollBy:scroll];
                }
                if (isDouble) {
                    [self.delegate remoteServerTrackpadDoubleClick:self];
                } else {
                    [self.delegate remoteServerTrackpadClick:self];
                }
            });
            break;
        }
        case BrowserRemoteTrackpadKindNone:
            break; // malformed or unknown message: ignored
    }
}

// One hop to main per kind at a time: deltas that arrive while it waits are summed,
// so a busy main thread never builds a backlog (the cursor stops when the finger does).
- (void)deliverPendingMoveForClient:(BrowserRemoteConnection *)client {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block CGPoint delta = CGPointZero;
        dispatch_sync(self.queue, ^{
            delta = client.pendingMove;
            client.pendingMove = CGPointZero;
            client.moveScheduled = NO;
        });
        if (!CGPointEqualToPoint(delta, CGPointZero)) {
            [self.delegate remoteServer:self trackpadMoveBy:delta];
        }
    });
}

- (void)deliverPendingScrollForClient:(BrowserRemoteConnection *)client {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block CGPoint delta = CGPointZero;
        dispatch_sync(self.queue, ^{
            delta = client.pendingScroll;
            client.pendingScroll = CGPointZero;
            client.scrollScheduled = NO;
        });
        if (!CGPointEqualToPoint(delta, CGPointZero)) {
            [self.delegate remoteServer:self trackpadScrollBy:delta];
        }
    });
}

- (void)scheduleIdleCheckForClient:(BrowserRemoteConnection *)client {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserRemoteWebSocketIdleTimeout / 3.0 * NSEC_PER_SEC)), self.queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || client.finished) {
            return;
        }
        if (CACurrentMediaTime() - client.lastFrameTime >= kBrowserRemoteWebSocketIdleTimeout) {
            [strongSelf closeWebSocket:client code:1001];
            return;
        }
        [strongSelf scheduleIdleCheckForClient:client];
    });
}

- (void)send:(NSData *)data to:(BrowserRemoteConnection *)client {
    NSData *payload = [data copy];
    dispatch_data_t content = dispatch_data_create(payload.bytes, payload.length, self.queue, ^{
        (void)payload;
    });
    // is_complete must be true: an open default-context message would block the final
    // (close) send queued behind it. On TCP this only delimits the message.
    nw_connection_send(client.connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(__unused nw_error_t error) {});
}

- (void)closeWebSocket:(BrowserRemoteConnection *)client code:(uint16_t)code {
    if (client.finished) {
        return;
    }
    [self finish:client data:BrowserRemoteCloseFrame(code)];
}

@end
