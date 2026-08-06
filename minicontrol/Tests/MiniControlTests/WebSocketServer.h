#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MCResponse)(NSDictionary *response);
typedef void (^MCRequestHandler)(NSDictionary *request, MCResponse respond);

@interface WebSocketServer : NSObject

- (instancetype)initWithPort:(uint16_t)port;

// Starts the listener. Never blocks the calling thread.
- (void)startWithHandler:(MCRequestHandler)handler;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
