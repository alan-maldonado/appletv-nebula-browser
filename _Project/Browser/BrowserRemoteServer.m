#import "BrowserRemoteServer.h"

#import <Network/Network.h>

@interface BrowserRemoteServer ()

@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, nullable) nw_listener_t listener;

@end

@implementation BrowserRemoteServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("app.orbitlabs.tvbrowser.remote", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    if (self.listener != nil) {
        return;
    }

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create_with_port("8080", parameters);
    if (listener == nil) {
        NSLog(@"[Remote] could not create listener");
        return;
    }
    self.listener = listener;

    __weak typeof(self) weakSelf = self;
    nw_listener_set_queue(listener, self.queue);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        uint16_t port = nw_listener_get_port(listener);
        NSLog(@"[Remote] listener state=%d port=%u error=%@", (int)state, port, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.port = (state == nw_listener_state_ready) ? port : 0;
        });
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf handleConnection:connection];
    });
    nw_listener_start(listener);
}

- (void)stop {
    if (self.listener == nil) {
        return;
    }
    nw_listener_cancel(self.listener);
    self.listener = nil;
    self.port = 0;
}

- (void)handleConnection:(nw_connection_t)connection {
    nw_connection_set_queue(connection, self.queue);
    nw_connection_start(connection);
    nw_connection_receive(connection, 1, 65536, ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error) {
        NSString *body = @"<!doctype html><meta charset=\"utf-8\"><h1>Hola desde Nebula</h1>";
        NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
                          (unsigned long)bodyData.length];
        NSMutableData *response = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [response appendData:bodyData];
        dispatch_data_t data = dispatch_data_create(response.bytes, response.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        nw_connection_send(connection, data, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {
            nw_connection_cancel(connection);
        });
    });
}

@end
