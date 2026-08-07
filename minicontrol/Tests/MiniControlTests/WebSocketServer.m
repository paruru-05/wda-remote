// Minimal RFC6455 WebSocket server built on BSD sockets.
// Serves a single active client. Text frames carry JSON requests.

#import "WebSocketServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
static const int kReadBufferSize = 1 << 20; // 1MB cap per frame

@interface WebSocketServer ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSLock *writeLock;
@end

@implementation WebSocketServer {
    int _listenFd;
    int _clientFd;
    int _clientGen;
    MCRequestHandler _handler;
}

- (instancetype)initWithPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _port = port;
        _listenFd = -1;
        _clientFd = -1;
        self.writeLock = [NSLock new];
        self.running = NO;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Lifecycle

- (void)startWithHandler:(MCRequestHandler)handler {
    _handler = handler;
    self.running = YES;

    _listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFd < 0) {
        NSLog(@"[MiniControl] socket() failed");
        return;
    }
    int one = 1;
    setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(self.port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(_listenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSLog(@"[MiniControl] bind(%u) failed", (unsigned)self.port);
        close(_listenFd);
        _listenFd = -1;
        return;
    }
    if (listen(_listenFd, 4) != 0) {
        NSLog(@"[MiniControl] listen failed");
        close(_listenFd);
        _listenFd = -1;
        return;
    }

    NSLog(@"[MiniControl] WebSocket server listening on 0.0.0.0:%u", (unsigned)self.port);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self acceptLoop];
    });
}

- (void)stop {
    self.running = NO;
    if (_listenFd >= 0) {
        close(_listenFd);
        _listenFd = -1;
    }
    [self closeClient];
}

- (void)closeClient {
    [self.writeLock lock];
    if (_clientFd >= 0) {
        close(_clientFd);
        _clientFd = -1;
    }
    [self.writeLock unlock];
}

#pragma mark - Accept loop

- (void)acceptLoop {
    while (self.running) {
        struct sockaddr_in clientAddr;
        socklen_t addrLen = sizeof(clientAddr);
        int fd = accept(_listenFd, (struct sockaddr *)&clientAddr, &addrLen);
        if (fd < 0) {
            if (self.running) {
                usleep(100 * 1000);
            }
            continue;
        }
        NSLog(@"[MiniControl] client connected from %s", inet_ntoa(clientAddr.sin_addr));
        [self closeClient]; // single active client
        [self.writeLock lock];
        self->_clientFd = fd;
        self->_clientGen++;
        int gen = self->_clientGen;
        [self.writeLock unlock];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [self handleConnection:fd generation:gen];
        });
    }
}

#pragma mark - Connection

- (BOOL)readExact:(int)fd buffer:(void *)buffer length:(size_t)length {
    size_t got = 0;
    while (got < length) {
        ssize_t n = read(fd, (char *)buffer + got, length - got);
        if (n <= 0) {
            return NO;
        }
        got += (size_t)n;
    }
    return YES;
}

- (BOOL)doHandshake:(int)fd {
    NSMutableData *requestData = [NSMutableData data];
    char byte = 0;
    // Read until \r\n\r\n
    while (requestData.length < 65536) {
        if (![self readExact:fd buffer:&byte length:1]) {
            return NO;
        }
        [requestData appendBytes:&byte length:1];
        if (requestData.length >= 4) {
            const char *bytes = (const char *)requestData.bytes;
            if (bytes[requestData.length - 4] == '\r' &&
                bytes[requestData.length - 3] == '\n' &&
                bytes[requestData.length - 2] == '\r' &&
                bytes[requestData.length - 1] == '\n') {
                break;
            }
        }
    }
    if (requestData.length >= 65536) {
        return NO;
    }
    NSString *requestString = [[NSString alloc] initWithData:requestData
                                                    encoding:NSUTF8StringEncoding];
    if (requestString == nil) {
        return NO;
    }
    NSString *key = nil;
    for (NSString *line in [requestString componentsSeparatedByString:@"\r\n"]) {
        if ([line.lowercaseString hasPrefix:@"sec-websocket-key:"]) {
            key = [line substringFromIndex:@"sec-websocket-key:".length];
            key = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }
    if (key == nil) {
        return NO;
    }

    NSString *accept = [self websocketAcceptForKey:key];
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\n"
        @"Upgrade: websocket\r\n"
        @"Connection: Upgrade\r\n"
        @"Sec-WebSocket-Accept: %@\r\n\r\n", accept];
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
    ssize_t written = write(fd, data.bytes, data.length);
    return written == (ssize_t)data.length;
}

- (NSString *)websocketAcceptForKey:(NSString *)key {
    NSString *concat = [key stringByAppendingString:kGUID];
    NSData *keyData = [concat dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(keyData.bytes, (CC_LONG)keyData.length, digest);
    NSData *digestData = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    return [digestData base64EncodedStringWithOptions:0];
}

- (void)handleConnection:(int)fd generation:(int)gen {
    if (![self doHandshake:fd]) {
        close(fd);
        [self clearClientIfCurrent:fd generation:gen];
        return;
    }
    while (self.running) {
        NSData *payload = nil;
        int opcode = 0;
        if (![self readFrame:fd opcode:&opcode payload:&payload]) {
            break;
        }
        switch (opcode) {
            case 0x1: { // text
                [self dispatchText:payload];
                break;
            }
            case 0x8: // close
                goto done;
            case 0x9: // ping -> pong
                [self sendRawFrame:0xA payload:payload];
                break;
            case 0xA: // pong
            default:
                break;
        }
    }
done:
    NSLog(@"[MiniControl] client disconnected");
    close(fd);
    [self clearClientIfCurrent:fd generation:gen];
}

- (void)clearClientIfCurrent:(int)fd generation:(int)gen {
    [self.writeLock lock];
    if (_clientFd == fd && _clientGen == gen) {
        _clientFd = -1;
    }
    [self.writeLock unlock];
}

#pragma mark - Framing

- (BOOL)readFrame:(int)fd opcode:(int *)opcodeOut payload:(NSData **)payloadOut {
    uint8_t hdr[2];
    if (![self readExact:fd buffer:hdr length:2]) {
        return NO;
    }
    uint8_t opcode = hdr[0] & 0x0F;
    BOOL masked = (hdr[1] & 0x80) != 0;
    uint64_t length = hdr[1] & 0x7F;

    if (length == 126) {
        uint8_t ext[2];
        if (![self readExact:fd buffer:ext length:2]) return NO;
        length = ((uint16_t)ext[0] << 8) | ext[1];
    } else if (length == 127) {
        uint8_t ext[8];
        if (![self readExact:fd buffer:ext length:8]) return NO;
        length = 0;
        for (int i = 0; i < 8; i++) {
            length = (length << 8) | ext[i];
        }
    }
    if (length > kReadBufferSize) {
        return NO;
    }

    uint8_t mask[4] = {0, 0, 0, 0};
    if (masked) {
        if (![self readExact:fd buffer:mask length:4]) return NO;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    if (length > 0) {
        if (![self readExact:fd buffer:data.mutableBytes length:(size_t)length]) return NO;
        if (masked) {
            uint8_t *bytes = data.mutableBytes;
            for (uint64_t i = 0; i < length; i++) {
                bytes[i] ^= mask[i % 4];
            }
        }
    }

    *opcodeOut = opcode;
    *payloadOut = data;
    return YES;
}

- (void)sendRawFrame:(uint8_t)opcode payload:(NSData *)payload {
    if (_clientFd < 0) return;
    NSMutableData *frame = [NSMutableData data];
    uint8_t b0 = 0x80 | opcode;
    [frame appendBytes:&b0 length:1];
    NSUInteger len = payload.length;
    if (len < 126) {
        uint8_t b1 = (uint8_t)len;
        [frame appendBytes:&b1 length:1];
    } else if (len <= 0xFFFF) {
        uint8_t b1 = 126;
        [frame appendBytes:&b1 length:1];
        uint16_t big = htons((uint16_t)len);
        [frame appendBytes:&big length:2];
    } else {
        uint8_t b1 = 127;
        [frame appendBytes:&b1 length:1];
        uint64_t big = CFSwapInt64HostToBig(len);
        [frame appendBytes:&big length:8];
    }
    [frame appendData:payload];
    [self.writeLock lock];
    if (_clientFd >= 0) {
        size_t sent = 0;
        while (sent < frame.length) {
            ssize_t n = write(_clientFd, frame.bytes + sent, frame.length - sent);
            if (n <= 0) break;
            sent += (size_t)n;
        }
    }
    [self.writeLock unlock];
}

- (void)sendJSON:(NSDictionary *)dict {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (error != nil) {
        return;
    }
    [self sendRawFrame:0x1 payload:data];
}

- (void)dispatchText:(NSData *)payload {
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&error];
    if (error != nil || ![obj isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSDictionary *request = (NSDictionary *)obj;
    __weak WebSocketServer *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WebSocketServer *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_handler == nil) {
            return;
        }
        strongSelf->_handler(request, ^(NSDictionary *response) {
            [strongSelf sendJSON:response];
        });
    });
}

@end
