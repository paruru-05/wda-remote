// Input synthesis via XCUIDevice.eventSynthesizer (XCEventGenerator).
// Mirrors the low-level path WebDriverAgent uses in FBEventSynthesizer.

#import "InputController.h"
#import <UIKit/UIKit.h>
#import "PrivateHeaders/XCTestPrivate.h"

@implementation InputController

- (void)tapAtPoint:(CGPoint)point completion:(MCCompletion)completion {
    XCPointerEventPath *path = [[XCPointerEventPath alloc]
        initForTouchAtPoint:point offset:0];
    [path liftUpAtOffset:0.05];
    [self synthesizePaths:@[path] completion:completion];
}

- (void)swipeFrom:(CGPoint)from
               to:(CGPoint)to
         duration:(NSTimeInterval)duration
       completion:(MCCompletion)completion {
    XCPointerEventPath *path = [[XCPointerEventPath alloc]
        initForTouchAtPoint:from offset:0];
    [path moveToPoint:to atOffset:duration];
    [path liftUpAtOffset:duration + 0.05];
    [self synthesizePaths:@[path] completion:completion];
}

- (void)typeText:(NSString *)text completion:(MCCompletion)completion {
    XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTextInput];
    [path typeText:text atOffset:0 typingSpeed:100 shouldRedact:NO];
    [self synthesizePaths:@[path] completion:completion];
}

- (void)pressButton:(NSString *)button completion:(MCCompletion)completion {
    if ([button isEqualToString:@"home"]) {
        [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
        if (completion) completion(YES, nil);
    } else if ([button isEqualToString:@"lock"]) {
        [[XCUIDevice sharedDevice] pressLockButton];
        if (completion) completion(YES, nil);
    } else if ([button isEqualToString:@"volumeUp"]) {
        [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonVolumeUp];
        if (completion) completion(YES, nil);
    } else if ([button isEqualToString:@"volumeDown"]) {
        [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonVolumeDown];
        if (completion) completion(YES, nil);
    } else {
        NSError *error = [NSError errorWithDomain:@"MiniControl"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithFormat:@"Unknown button %@", button]}];
        if (completion) completion(NO, error);
    }
}

#pragma mark - Private

- (void)synthesizePaths:(NSArray<XCPointerEventPath *> *)paths
             completion:(MCCompletion)completion {
    XCSynthesizedEventRecord *record =
        [[XCSynthesizedEventRecord alloc] initWithName:@"MiniControlEvent"
                                    interfaceOrientation:UIInterfaceOrientationPortrait];
    for (XCPointerEventPath *path in paths) {
        [record addPointerEventPath:path];
    }
    id<XCUIEventSynthesizing> synthesizer = XCUIDevice.sharedDevice.eventSynthesizer;
    [synthesizer synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        if (completion) completion(success, error);
    }];
}

@end
