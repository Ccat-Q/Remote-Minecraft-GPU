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

// Native notifications are emitted only after actual copy/Metal completion.
@interface RGPUBufferedDisplayEvent : NSObject
@property(nonatomic) NSUInteger kind; // 1 snapshot-safe, 2 Metal-completed
@property(nonatomic) NSUInteger slot;
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint64_t frameID;
@property(nonatomic) uint64_t resourceID;
@property(nonatomic) uint64_t afterSequence;
@property(nonatomic, copy) NSString *report;
@end

// Separate from RGPUVTestEndpoint: Capability Probe still cannot PRESENT.
@interface RGPURemoteDisplayEndpoint : NSObject
@property(nonatomic, readonly) NSString *hostReport;
+ (nullable instancetype)createWithCancellation:(RGPUDisplayCancellation *)cancellation
    error:(NSError **)error NS_SWIFT_NAME(create(cancellation:));
- (nullable NSArray<NSData *> *)submitVTest:(NSData *)bytes error:(NSError **)error NS_SWIFT_NAME(submit(_:));
- (nullable NSString *)presentPayload:(NSData *)payload layer:(CAMetalLayer *)layer
    error:(NSError **)error NS_SWIFT_NAME(present(_:layer:));
// A3.1: one pinned frame, driven ONLY on the serialized renderer owner.
// Stages: 1 producer fence, 2 copy fence, 3 Metal consumption, 4 complete.
@property(nonatomic, readonly) NSUInteger asyncPresentStage;
- (BOOL)beginAsyncPresent:(NSData *)payload layer:(CAMetalLayer *)layer
    error:(NSError **)error NS_SWIFT_NAME(beginAsyncPresent(_:layer:));
// Empty string = pending; full frame report = completed; nil + error = failure.
- (nullable NSString *)pollAsyncPresentWithError:(NSError **)error NS_SWIFT_NAME(pollAsyncPresent());
- (BOOL)enableDoubleBufferingWithError:(NSError **)error NS_SWIFT_NAME(enableDoubleBuffering());
@property(nonatomic, readonly) BOOL bufferedCanAdvance;
@property(nonatomic, readonly) NSUInteger bufferedPendingFrames;
@property(nonatomic, readonly) NSString *bufferedStatistics;
- (nullable RGPUBufferedDisplayEvent *)beginBufferedPresent:(NSData *)payload layer:(CAMetalLayer *)layer
    error:(NSError **)error NS_SWIFT_NAME(beginBufferedPresent(_:layer:));
- (nullable NSArray<RGPUBufferedDisplayEvent *> *)pollBufferedWithError:(NSError **)error NS_SWIFT_NAME(pollBuffered());
- (NSString *)close;
@end
NS_ASSUME_NONNULL_END
