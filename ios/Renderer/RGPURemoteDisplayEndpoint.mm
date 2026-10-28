#import "RGPURemotePresent.h"
#include "RGPUFrameCopy.hpp"
#include "RGPUBufferedPresent.hpp"
#include <atomic>
#include <thread>
#include <sys/utsname.h>

@implementation RGPUDisplayCancellation {
    std::atomic<bool> _cancelled;
}
- (instancetype)init { self = [super init]; if (self) _cancelled.store(false); return self; }
- (BOOL)isCancelled { return _cancelled.load(); }
- (void)cancel { _cancelled.store(true); }
@end

@implementation RGPUBufferedDisplayEvent
@end

namespace {
struct AsyncFrame {
    uint64_t frame = 0, after = 0;
    uint32_t resource = 0, fence = 0;
    rgpu::ResourceDescription desc{};
    bool retained = false;
    unsigned stage = 1;
    NSMutableString *report = [NSMutableString string];
    CAMetalLayer *layer;
    std::unique_ptr<rgpu::interop::SingleFrameCopy> copy;
    using Clock = std::chrono::steady_clock;
    Clock::time_point started = Clock::now(), stageStarted = started;
    double producerMs = 0, copyMs = 0, metalMs = 0;
    double elapsedMs() const { return std::chrono::duration<double, std::milli>(Clock::now() - stageStarted).count(); }
    void advance(unsigned next) { stage = next; stageStarted = Clock::now(); }
};
uint64_t bigEndian(const uint8_t *bytes, size_t count) {
    uint64_t value = 0;
    for (size_t i = 0; i < count; ++i) value = (value << 8) | bytes[i];
    return value;
}
void failure(NSError **error, NSString *report, const std::exception& failed) {
    if (error) *error = [NSError errorWithDomain:@"org.remotegpu.remote-display" code:1
        userInfo:@{NSLocalizedDescriptionKey: [report stringByAppendingFormat:@"\nFAILED: %s", failed.what()]}];
}
}

@implementation RGPURemoteDisplayEndpoint {
    std::unique_ptr<ANGLEHost> _host;
    RGPUDisplayCancellation *_cancellation;
    std::unique_ptr<AsyncFrame> _asyncFrame;
    NSUInteger _asyncPresentStage;
    std::unique_ptr<rgpu::interop::BufferedPresent> _buffered;
}
+ (instancetype)createWithCancellation:(RGPUDisplayCancellation *)cancellation error:(NSError **)error {
    try {
        auto endpoint = [[self alloc] init];
        endpoint->_cancellation = cancellation;
        endpoint->_host = std::make_unique<ANGLEHost>();
        endpoint->_host->initialize(false); // No TRANSFER_GET in display diagnostic.
        endpoint->_host->session->setCancellationCheck([cancellation] { return bool(cancellation.cancelled); });
        endpoint->_host->suspend();
        return endpoint;
    } catch (const std::exception& failed) { failure(error, @"Remote renderer initialization", failed); return nil; }
}
- (NSString *)hostReport {
    if (!_host) return @"Remote display endpoint closed";
    try {
        _host->resume();
        struct utsname machine{}; uname(&machine);
        NSURL *url = [NSBundle.mainBundle URLForResource:@"RGPUProvenance" withExtension:@"json"];
        NSData *manifest = url ? [NSData dataWithContentsOfURL:url] : nil;
        NSString *report = [NSString stringWithFormat:@"A2.1 REAL REMOTE DISPLAY (bounded diagnostic, not A3)\nDevice: %s; %@\nBuild provenance: %@\nHost GL: %@\nGLSL: %@\nRenderer: %@\n",
            machine.machine, NSProcessInfo.processInfo.operatingSystemVersionString,
            manifest ? [[NSString alloc] initWithData:manifest encoding:NSUTF8StringEncoding] : @"MISSING",
            rgpu::interop::glText(GL_VERSION), rgpu::interop::glText(GL_SHADING_LANGUAGE_VERSION), rgpu::interop::glText(GL_RENDERER)];
        _host->suspend();
        return report;
    } catch (const std::exception& failed) { return [NSString stringWithUTF8String:failed.what()]; }
}
- (NSArray<NSData *> *)submitVTest:(NSData *)bytes error:(NSError **)error {
    try {
        rgpu::interop::require(_host && !_cancellation.cancelled && !_asyncFrame &&
            (!_buffered || _buffered->canAdvance()),
            "Display session closed/cancelled or snapshot barrier active");
        _host->resume();
        auto replies = _host->session->feed(static_cast<const uint8_t *>(bytes.bytes), bytes.length);
        NSMutableArray<NSData *> *result = [NSMutableArray arrayWithCapacity:replies.size()];
        for (const auto& reply : replies) [result addObject:[NSData dataWithBytes:reply.data() length:reply.size()]];
        _host->suspend();
        return result;
    } catch (const std::exception& failed) {
        if (_host) { try { _host->suspend(); } catch (...) {} }
        failure(error, @"Native remote vtest submission", failed); return nil;
    }
}
- (NSString *)presentPayload:(NSData *)payload layer:(CAMetalLayer *)layer error:(NSError **)error {
    using namespace rgpu::interop;
    NSMutableString *report = [NSMutableString string];
    bool retained = false;
    uint32_t resource = 0;
    try {
        require(_host && !_cancellation.cancelled && !_asyncFrame && !_buffered && payload.length == 48, "Invalid/closed PRESENT");
        _host->resume();
        auto bytes = static_cast<const uint8_t *>(payload.bytes);
        const auto frame = bigEndian(bytes, 8), handle = bigEndian(bytes + 8, 8), after = bigEndian(bytes + 16, 8);
        [report appendFormat:@"Native PRESENT frame=%llu resource=%llu after=%llu; command boundary=%@\n",
            (unsigned long long)frame, (unsigned long long)handle, (unsigned long long)after,
            _host->session->atCommandBoundary() ? @"YES" : @"NO"];
        if (handle && handle <= UINT32_MAX) {
            const auto created = _host->session->resourceDescription(uint32_t(handle));
            [report appendFormat:@"Created resource: format=%u %ux%u target=%u depth=%u samples=%u array=%u last_level=%u\n",
                created.format, created.width, created.height, created.target, created.depth, created.samples, created.arraySize, created.lastLevel];
        }
        const auto desc = _host->session->validatePresentResource(handle,
            uint32_t(bigEndian(bytes + 24, 4)), uint32_t(bigEndian(bytes + 28, 4)),
            uint32_t(bigEndian(bytes + 32, 4)), uint32_t(bigEndian(bytes + 36, 4)),
            uint32_t(bigEndian(bytes + 40, 4)), uint32_t(bigEndian(bytes + 44, 4)));
        // A2.1 fixture is A1's exact 64x64 window. Larger/other surfaces wait
        // for explicit image/format verification instead of guessed scaling.
        require(desc.width == 64 && desc.height == 64, "A2.1 requires the A1 64x64 window");
        resource = uint32_t(handle);
        _host->session->retainForPresent(resource); retained = true;
        const auto fence = _host->session->fenceForPresent(); // At THIS command boundary.
        [report appendFormat:@"REMOTE_PRESENT frame=%llu resource=%u after=%llu; producer fence=%u captured; later vtest PAUSED\n",
            (unsigned long long)frame, resource, (unsigned long long)after, fence];
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (!_host->session->isFenceComplete(fence)) {
            require(!_cancellation.cancelled, "Producer wait cancelled");
            require(std::chrono::steady_clock::now() < deadline, "Producer fence timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        glCheck(report, "Remote producer fence complete");
        virgl_renderer_resource_info info{};
        require(!virgl_renderer_resource_get_info(resource, &info), "Remote Resource Info failed");
        [report appendFormat:@"Resource: handle=%u tex_id=%u format=%u %ux%u depth=%u flags=0x%x stride=%u; target=%u samples=%u array=%u last_level=%u\n",
            info.handle, info.tex_id, info.virgl_format, info.width, info.height, info.depth, info.flags, info.stride,
            desc.target, desc.samples, desc.arraySize, desc.lastLevel];
        {
            RGPUDisplayCancellation *cancellation = _cancellation;
            SingleFrameCopy copy(*_host, [cancellation] { return bool(cancellation.cancelled); });
            copy.copy(layer, info, desc, report, true); // A1 Gallium window, NOT A2.0 fixture rows.
            _host->session->releaseFromPresent(resource); retained = false;
            [report appendString:@"Snapshot complete; source pin released. No later source writes preceded snapshot completion.\n"];
            copy.display(report);
            require(copy.close(), "Remote snapshot cleanup failed");
        }
        eglCheck(report, "Remote copy teardown");
        const auto& counts = _host->session->commandCounts();
        [report appendFormat:@"Counts: SUBMIT_CMD=%llu TRANSFER_PUT=%llu TRANSFER_GET=%llu; Metal displayed frame=%llu\n",
            (unsigned long long)counts[6], (unsigned long long)counts[5], (unsigned long long)counts[4], (unsigned long long)frame];
        require(counts[4] == 0, "Display TRANSFER_GET forbidden");
        _host->suspend();
        return report;
    } catch (const std::exception& failed) {
        [report appendFormat:@"Before endpoint teardown GL=0x%x EGL=0x%x\n", glGetError(), eglGetError()];
        if (_host) {
            try { _host->resume(); if (retained) _host->session->releaseFromPresent(resource); _host->suspend(); } catch (...) {}
        }
        failure(error, report, failed); return nil;
    }
}
- (NSUInteger)asyncPresentStage { return _asyncPresentStage; }
- (BOOL)beginAsyncPresent:(NSData *)payload layer:(CAMetalLayer *)layer error:(NSError **)error {
    using namespace rgpu::interop;
    try {
        require(_host && !_cancellation.cancelled && !_asyncFrame && !_buffered && payload.length == 48,
                "Invalid/closed/overlapping async PRESENT");
        _host->resume();
        const auto *bytes = static_cast<const uint8_t *>(payload.bytes);
        auto frame = std::make_unique<AsyncFrame>();
        frame->frame = bigEndian(bytes, 8); frame->after = bigEndian(bytes + 16, 8);
        const auto handle = bigEndian(bytes + 8, 8);
        frame->desc = _host->session->validatePresentResource(handle,
            uint32_t(bigEndian(bytes + 24, 4)), uint32_t(bigEndian(bytes + 28, 4)),
            uint32_t(bigEndian(bytes + 32, 4)), uint32_t(bigEndian(bytes + 36, 4)),
            uint32_t(bigEndian(bytes + 40, 4)), uint32_t(bigEndian(bytes + 44, 4)));
        require(frame->frame && frame->desc.width == 64 && frame->desc.height == 64,
                "A3.1 keeps the verified 64x64 single slot");
        frame->resource = uint32_t(handle); frame->layer = layer;
        _asyncFrame = std::move(frame); // Endpoint owns cleanup before any pin/fence can throw.
        auto& f = *_asyncFrame;
        _host->session->retainForPresent(f.resource); f.retained = true;
        f.fence = _host->session->fenceForPresent();
        glFlush();
        glCheck(f.report, "A3 producer fence submitted");
        [f.report appendFormat:@"A3_BEGIN frame=%llu resource=%u after=%llu producer_fence=%u command_boundary=YES; later vtest PAUSED\n",
            (unsigned long long)f.frame, f.resource, (unsigned long long)f.after, f.fence];
        _asyncPresentStage = 1;
        _host->suspend();
        return YES;
    } catch (const std::exception& failed) {
        if (_host) { try { _host->suspend(); } catch (...) {} }
        failure(error, _asyncFrame ? _asyncFrame->report : @"Async begin", failed); return NO;
    }
}
- (NSString *)pollAsyncPresentWithError:(NSError **)error {
    using namespace rgpu::interop;
    try {
        require(_host && _asyncFrame && !_cancellation.cancelled, "Async frame closed/cancelled");
        auto& f = *_asyncFrame;
        require(f.elapsedMs() < 10000, "Async GPU phase timeout (local monotonic 10s)");
        _host->resume();
        if (f.stage == 1 && _host->session->isFenceComplete(f.fence)) {
            f.producerMs = f.elapsedMs();
            glCheck(f.report, "Remote producer fence complete");
            virgl_renderer_resource_info info{};
            require(!virgl_renderer_resource_get_info(f.resource, &info), "Remote Resource Info failed");
            [f.report appendFormat:@"Resource: handle=%u tex_id=%u format=%u %ux%u depth=%u flags=0x%x stride=%u; target=%u samples=%u array=%u last_level=%u\n",
                info.handle, info.tex_id, info.virgl_format, info.width, info.height, info.depth, info.flags, info.stride,
                f.desc.target, f.desc.samples, f.desc.arraySize, f.desc.lastLevel];
            RGPUDisplayCancellation *cancel = _cancellation;
            f.copy = std::make_unique<SingleFrameCopy>(*_host, [cancel] { return bool(cancel.cancelled); });
            f.advance(2); // Includes snapshot setup/scheduling, not a GPU timestamp.
            f.copy->beginCopy(f.layer, info, f.desc, f.report, true);
        } else if (f.stage == 2 && f.copy->pollCopy(f.report)) {
            f.copyMs = f.elapsedMs();
            _host->session->releaseFromPresent(f.resource); f.retained = false;
            [f.report appendString:@"Snapshot complete; source pin released. No later source writes preceded snapshot completion.\n"];
            f.advance(3);
            f.copy->beginDisplay(); // Submits Metal; NEVER waits for completion.
        } else if (f.stage == 3 && f.copy->pollDisplay()) {
            f.metalMs = f.elapsedMs();
            [f.report appendString:@"Metal command status: COMPLETED; IOSurface retained through consumption\n"];
            require(f.copy->close(), "Async copy cleanup failed");
            eglCheck(f.report, "Remote copy teardown");
            const auto& counts = _host->session->commandCounts();
            require(counts[4] == 0, "Display TRANSFER_GET forbidden");
            [f.report appendFormat:@"Counts: SUBMIT_CMD=%llu TRANSFER_PUT=%llu TRANSFER_GET=%llu; Metal displayed frame=%llu\nA3_TIMING frame=%llu producer_observed_ms=%.3f snapshot_observed_ms=%.3f metal_observed_ms=%.3f clock=local_monotonic (poll/setup inclusive, NOT GPU timestamps or network latency)\n",
                (unsigned long long)counts[6], (unsigned long long)counts[5], (unsigned long long)counts[4],
                (unsigned long long)f.frame, (unsigned long long)f.frame, f.producerMs, f.copyMs, f.metalMs];
            NSString *report = [f.report copy];
            _host->suspend();
            _asyncFrame.reset(); _asyncPresentStage = 4;
            return report;
        }
        _asyncPresentStage = f.stage;
        _host->suspend();
        return @"";
    } catch (const std::exception& failed) {
        if (_host) { try { _host->suspend(); } catch (...) {} }
        failure(error, _asyncFrame ? _asyncFrame->report : @"Async poll", failed); return nil;
    }
}
- (BOOL)enableDoubleBufferingWithError:(NSError **)error {
    try {
        rgpu::interop::require(_host && !_asyncFrame && !_buffered && !_cancellation.cancelled &&
            _host->session->commandCounts()[8] == 0, "Double-buffer mode must be selected before vtest context creation");
        RGPUDisplayCancellation *cancel = _cancellation;
        _buffered = std::make_unique<rgpu::interop::BufferedPresent>(*_host, [cancel] { return bool(cancel.cancelled); });
        return YES;
    } catch (const std::exception& failed) { failure(error, @"Double-buffer setup", failed); return NO; }
}
- (BOOL)bufferedCanAdvance { return _buffered && !_cancellation.cancelled && _buffered->canAdvance(); }
- (NSUInteger)bufferedPendingFrames { return _buffered ? _buffered->pending() : 0; }
- (NSString *)bufferedStatistics { return _buffered ? _buffered->statistics() : @"Double buffering not enabled"; }
- (RGPUBufferedDisplayEvent *)beginBufferedPresent:(NSData *)payload layer:(CAMetalLayer *)layer error:(NSError **)error {
    try {
        rgpu::interop::require(_host && _buffered && !_cancellation.cancelled, "Double-buffer session closed");
        _host->resume(); auto result = _buffered->begin(payload, layer); _host->suspend();
        return result;
    } catch (const std::exception& failed) {
        if (_host) { try { _host->suspend(); } catch (...) {} }
        failure(error, @"Double-buffer PRESENT", failed); return nil;
    }
}
- (NSArray<RGPUBufferedDisplayEvent *> *)pollBufferedWithError:(NSError **)error {
    try {
        rgpu::interop::require(_host && _buffered && !_cancellation.cancelled, "Double-buffer poll closed/cancelled");
        _host->resume(); auto result = _buffered->poll(); _host->suspend();
        return result;
    } catch (const std::exception& failed) {
        if (_host) { try { _host->suspend(); } catch (...) {} }
        failure(error, @"Double-buffer GPU completion", failed); return nil;
    }
}
- (NSString *)close {
    if (!_host) return @"Native display endpoint already closed";
    NSMutableString *drain = [NSMutableString string];
    if (_buffered) {
        try { _host->resume(); [drain appendString:_buffered->close()]; }
        catch (const std::exception& failed) { [drain appendFormat:@"A32_CLEANUP_ERROR %s\n", failed.what()]; }
        _buffered.reset(); // Slots and shared-context teardown precede ANGLEHost.
    }
    if (_asyncFrame) {
        [drain appendString:_asyncFrame->report];
        // Cancellation/error path ONLY: drain an incomplete GL copy before
        // unpinning its source. Metal keeps its independent IOSurface lease.
        // No queued poll retains this native object after serial close.
        try {
            _host->resume();
            if (_asyncFrame->copy) rgpu::interop::require(_asyncFrame->copy->close(), "Cancelled copy cleanup failed");
            _host->resume();
            if (_asyncFrame->retained) _host->session->releaseFromPresent(_asyncFrame->resource);
            [drain appendFormat:@"A3_CANCEL frame=%llu phase=%u source_cleanup=returned; exceptional drain, NOT steady state\n",
                (unsigned long long)_asyncFrame->frame, _asyncFrame->stage];
        } catch (const std::exception& failed) {
            [drain appendFormat:@"A3 cleanup error: %s\n", failed.what()];
        }
        _asyncFrame.reset();
    }
    const auto counts = _host->session->commandCounts();
    _host.reset(); // Serialized owner queue; restores EGL before GL teardown.
    return [drain stringByAppendingFormat:@"Native session/context/resources cleanup returned. SUBMIT_CMD=%llu TRANSFER_PUT=%llu TRANSFER_GET=%llu. Reconnect requires a separate session; leak profiling remains separate.",
        (unsigned long long)counts[6], (unsigned long long)counts[5], (unsigned long long)counts[4]];
}
@end
