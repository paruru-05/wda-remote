// MiniControl UI-test runner. WDA replacement for low-latency input control.
// Started via `pymobiledevice3 developer dvt xcuitest` which launches this test bundle.
//
// Flow:
//   1. setUp starts a WebSocket server on 0.0.0.0:9100
//   2. testRunner runs the main run loop forever (never-ending test)
//   3. Incoming JSON commands are executed via InputController

#import <XCTest/XCTest.h>
#import <notify.h>
#import "WebSocketServer.h"
#import "InputController.h"

static BOOL kMiniControlScreenLocked;
static const NSTimeInterval kHomeButtonCoolOffTime = 1.0;

@interface MiniControlTest : XCTestCase
@property (nonatomic, strong, readonly) InputController *inputController;
@end

@implementation MiniControlTest {
    InputController *_inputController;
}

+ (void)load {
    int token;
    notify_register_dispatch("com.apple.springboard.lockstate", &token,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
        ^(int notificationToken) {
            uint64_t state = UINT64_MAX;
            notify_get_state(notificationToken, &state);
            kMiniControlScreenLocked = state != 0;
        });
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
}

- (void)testRunner {
    NSLog(@"[MiniControl] runner starting");

    __block WebSocketServer *server = [[WebSocketServer alloc] initWithPort:9100];

    __weak typeof(self) weakSelf = self;
    [server startWithHandler:^(NSDictionary *request, MCResponse respond) {
        [weakSelf handleRequest:request respond:respond];
    }];

    // Keep the test alive forever so the runner stays resident.
    while (YES) {
        [[NSRunLoop mainRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:60.0]];
    }
}

#pragma mark - Command handling

- (InputController *)inputController {
    if (_inputController == nil) {
        _inputController = [InputController new];
    }
    return _inputController;
}

- (void)handleRequest:(NSDictionary *)request respond:(MCResponse)respond {
    NSString *command = request[@"command"];
    NSError *error = nil;
    BOOL success = YES;
    NSDictionary *result = @{};

    if ([command isEqualToString:@"ping"]) {
        result = @{@"status": @"ok", @"locked": @(kMiniControlScreenLocked)};
    } else if ([command isEqualToString:@"tap"]) {
        CGFloat x = [request[@"x"] doubleValue];
        CGFloat y = [request[@"y"] doubleValue];
        success = [self tapAtNormalized:x / [self logicalWidth]
                                     sy:y / [self logicalHeight]
                                  error:&error];
    } else if ([command isEqualToString:@"swipe"]) {
        CGFloat fx = [request[@"fx"] doubleValue];
        CGFloat fy = [request[@"fy"] doubleValue];
        CGFloat tx = [request[@"tx"] doubleValue];
        CGFloat ty = [request[@"ty"] doubleValue];
        NSTimeInterval duration = [request[@"duration"] doubleValue] ?: 0.2;
        CGPoint from = CGPointMake(fx / [self logicalWidth],
                                   fy / [self logicalHeight]);
        CGPoint to = CGPointMake(tx / [self logicalWidth],
                                 ty / [self logicalHeight]);
        success = [self swipeNormalizedFrom:from to:to duration:duration error:&error];
    } else if ([command isEqualToString:@"keys"]) {
        NSString *text = request[@"text"] ?: @"";
        success = [self typeText:[self mapSpecialCharacters:text] error:&error];
    } else if ([command isEqualToString:@"button"]) {
        NSString *button = request[@"button"];
        if ([button isEqualToString:@"unlock"]) {
            success = [self unlockDevice];
        } else {
            success = [self pressButton:button error:&error];
        }
    } else if ([command isEqualToString:@"launch"]) {
        NSString *bundleId = request[@"bundle_id"];
        if (bundleId.length == 0) {
            success = NO;
            error = [NSError errorWithDomain:@"MiniControl" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"bundle_id is required"}];
        } else {
            XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
            [app launch];
            success = YES;
        }
    } else if ([command isEqualToString:@"terminate"]) {
        NSString *bundleId = request[@"bundle_id"];
        if (bundleId.length == 0) {
            success = NO;
            error = [NSError errorWithDomain:@"MiniControl" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"bundle_id is required"}];
        } else {
            XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
            [app terminate];
            success = YES;
        }
    } else {
        success = NO;
        error = [NSError errorWithDomain:@"MiniControl"
                                    code:2
                                userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"Unknown command %@", command]}];
    }

    if (success) {
        respond(@{@"status": @"ok", @"command": command, @"result": result});
    } else {
        respond(@{@"status": @"error",
                  @"command": command,
                  @"message": error.localizedDescription ?: @"unknown error"});
    }
}

#pragma mark - Input helpers (normalized 0..1, portrait)

- (CGFloat)logicalWidth {
    return CGRectGetWidth(UIScreen.mainScreen.bounds);
}

- (CGFloat)logicalHeight {
    return CGRectGetHeight(UIScreen.mainScreen.bounds);
}

- (BOOL)tapAtNormalized:(CGFloat)sx sy:(CGFloat)sy error:(NSError **)error {
    CGPoint point = CGPointMake(sx * [self logicalWidth],
                                sy * [self logicalHeight]);
    __block BOOL done = NO;
    __block BOOL ok = NO;
    __block NSError *localError = nil;
    [self.inputController tapAtPoint:point completion:^(BOOL success, NSError *e) {
        ok = success;
        localError = e;
        done = YES;
    }];
    [self waitForFlag:&done];
    if (error) *error = localError;
    return ok;
}

- (BOOL)swipeNormalizedFrom:(CGPoint)from to:(CGPoint)to
                   duration:(NSTimeInterval)duration
                      error:(NSError **)error {
    CGPoint start = CGPointMake(from.x * [self logicalWidth],
                                from.y * [self logicalHeight]);
    CGPoint end = CGPointMake(to.x * [self logicalWidth],
                              to.y * [self logicalHeight]);
    __block BOOL done = NO;
    __block BOOL ok = NO;
    __block NSError *localError = nil;
    [self.inputController swipeFrom:start to:end duration:duration
                         completion:^(BOOL success, NSError *e) {
        ok = success;
        localError = e;
        done = YES;
    }];
    [self waitForFlag:&done];
    if (error) *error = localError;
    return ok;
}

- (BOOL)typeText:(NSString *)text error:(NSError **)error {
    __block BOOL done = NO;
    __block BOOL ok = NO;
    __block NSError *localError = nil;
    [self.inputController typeText:text completion:^(BOOL success, NSError *e) {
        ok = success;
        localError = e;
        done = YES;
    }];
    [self waitForFlag:&done];
    if (error) *error = localError;
    return ok;
}

- (BOOL)pressButton:(NSString *)button error:(NSError **)error {
    __block BOOL done = NO;
    __block BOOL ok = NO;
    __block NSError *localError = nil;
    [self.inputController pressButton:button completion:^(BOOL success, NSError *e) {
        ok = success;
        localError = e;
        done = YES;
    }];
    [self waitForFlag:&done];
    if (error) *error = localError;
    return ok;
}

- (BOOL)unlockDevice {
    if (!kMiniControlScreenLocked) {
        return YES;
    }
    [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
    [[NSRunLoop mainRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:kHomeButtonCoolOffTime]];
    [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
    [[NSRunLoop mainRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:kHomeButtonCoolOffTime]];
    return YES;
}

- (NSString *)mapSpecialCharacters:(NSString *)text {
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        switch (c) {
            case 0xE000: break;
            case 0xE003: [result appendString:@"\x08"]; break;
            case 0xE004: [result appendString:@"\t"]; break;
            case 0xE006: [result appendString:@"\r"]; break;
            case 0xE007: [result appendString:@"\n"]; break;
            case 0xE00C: [result appendString:@"\x1b"]; break;
            case 0xE00D:
            case 0xE05D: [result appendString:@" "]; break;
            case 0xE017: [result appendString:@"\x7f"]; break;
            case 0xE018: [result appendString:@";"]; break;
            case 0xE019: [result appendString:@"="]; break;
            case 0xE01A: [result appendString:@"0"]; break;
            case 0xE01B: [result appendString:@"1"]; break;
            case 0xE01C: [result appendString:@"2"]; break;
            case 0xE01D: [result appendString:@"3"]; break;
            case 0xE01E: [result appendString:@"4"]; break;
            case 0xE01F: [result appendString:@"5"]; break;
            case 0xE020: [result appendString:@"6"]; break;
            case 0xE021: [result appendString:@"7"]; break;
            case 0xE022: [result appendString:@"8"]; break;
            case 0xE023: [result appendString:@"9"]; break;
            case 0xE024: [result appendString:@"*"]; break;
            case 0xE025: [result appendString:@"+"]; break;
            case 0xE026: [result appendString:@","]; break;
            case 0xE027: [result appendString:@"-"]; break;
            case 0xE028: [result appendString:@"."]; break;
            case 0xE029: [result appendString:@"/"]; break;
            default:
                if (c >= 0xE000 && c <= 0xE05D) break;
                [result appendString:[NSString stringWithCharacters:&c length:1]];
        }
    }
    return result;
}

- (void)waitForFlag:(BOOL *)flag {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (!*flag && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

@end
