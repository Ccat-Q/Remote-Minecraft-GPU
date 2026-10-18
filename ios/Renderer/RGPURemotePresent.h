#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
NS_ASSUME_NONNULL_BEGIN
// One-shot local VirGL-resource interop diagnostic, NOT network presentation.
// Always returns the accumulated report, including partial failure evidence.
@interface RGPURemotePresent : NSObject
+ (NSString *)runWithLayer:(CAMetalLayer *)layer NS_SWIFT_NAME(run(layer:));
@end
NS_ASSUME_NONNULL_END
