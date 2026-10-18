#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
NS_ASSUME_NONNULL_BEGIN
// One-shot local VirGL-resource interop diagnostic, NOT network presentation.
// Always returns the accumulated report, including partial failure evidence.
@interface RGPURemotePresent : NSObject
+ (NSString *)runWithLayer:(CAMetalLayer *)layer NS_SWIFT_NAME(run(layer:));
@end

// Atomic cancellation may be requested from UIKit/network while renderer waits.
@interface RGPUDisplayCancellation : NSObject
@property(nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

// Separate from RGPUVTestEndpoint: Capability Probe still cannot PRESENT.
@interface RGPURemoteDisplayEndpoint : NSObject
@property(nonatomic, readonly) NSString *hostReport;
+ (nullable instancetype)createWithCancellation:(RGPUDisplayCancellation *)cancellation
    error:(NSError **)error NS_SWIFT_NAME(create(cancellation:));
- (nullable NSArray<NSData *> *)submitVTest:(NSData *)bytes error:(NSError **)error NS_SWIFT_NAME(submit(_:));
- (nullable NSString *)presentPayload:(NSData *)payload layer:(CAMetalLayer *)layer
    error:(NSError **)error NS_SWIFT_NAME(present(_:layer:));
- (NSString *)close;
@end
NS_ASSUME_NONNULL_END
