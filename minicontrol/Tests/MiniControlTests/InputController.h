#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MCCompletion)(BOOL success, NSError *_Nullable error);

// Low-latency input synthesis backed by XCUIDevice.eventSynthesizer.
// Coordinates are in points of the logical screen (portrait).
@interface InputController : NSObject

- (void)tapAtPoint:(CGPoint)point completion:(nullable MCCompletion)completion;
- (void)swipeFrom:(CGPoint)from
               to:(CGPoint)to
         duration:(NSTimeInterval)duration
       completion:(nullable MCCompletion)completion;
- (void)typeText:(NSString *)text completion:(nullable MCCompletion)completion;
- (void)pressButton:(NSString *)button completion:(nullable MCCompletion)completion;

@end

NS_ASSUME_NONNULL_END
