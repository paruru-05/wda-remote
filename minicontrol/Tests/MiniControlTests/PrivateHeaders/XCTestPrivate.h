// Private XCTest interfaces used by MiniControl for low-level event synthesis.
// Class-dump generated headers are Copyright (c) 2015-present Facebook, Inc.
// (BSD-style license, see WebDriverAgent/PrivateHeaders/XCTest).
// These are used to bypass per-element overhead for fast input synthesis.

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset;
- (instancetype)initForTextInput;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (void)liftUpAtOffset:(NSTimeInterval)offset;
- (void)pressDownAtOffset:(NSTimeInterval)offset;
- (void)pressDownWithPressure:(double)pressure atOffset:(NSTimeInterval)offset;
- (void)typeText:(NSString *)text
         atOffset:(NSTimeInterval)offset
     typingSpeed:(NSUInteger)speed
    shouldRedact:(BOOL)redact;
@end

@interface XCSynthesizedEventRecord : NSObject <NSSecureCoding>
- (instancetype)initWithName:(NSString *)name
         interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(XCPointerEventPath *)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end

@protocol XCUIEventSynthesizing <NSObject>
- (void)synthesizeEvent:(XCSynthesizedEventRecord *)event
            completion:(void (^)(BOOL success, NSError *_Nullable error))completion;
@end

@interface XCUIDevice (MiniControlPrivate)
@property (readonly) id<XCUIEventSynthesizing> eventSynthesizer;
- (void)pressLockButton;
@end

NS_ASSUME_NONNULL_END
