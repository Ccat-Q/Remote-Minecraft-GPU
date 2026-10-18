#import "RGPURemotePresent.h"
#include "RGPUFrameCopy.hpp"
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

namespace {
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
        rgpu::interop::require(_host && !_cancellation.cancelled, "Display session closed/cancelled");
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
        require(_host && !_cancellation.cancelled && payload.length == 48, "Invalid/closed PRESENT");
        _host->resume();
        auto bytes = static_cast<const uint8_t *>(payload.bytes);
        const auto frame = bigEndian(bytes, 8), handle = bigEndian(bytes + 8, 8), after = bigEndian(bytes + 16, 8);
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
            copy.copy(layer, info, desc, report);
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
- (NSString *)close {
    if (!_host) return @"Native display endpoint already closed";
    const auto counts = _host->session->commandCounts();
    _host.reset(); // Serialized owner queue; restores EGL before GL teardown.
    return [NSString stringWithFormat:@"Native session/context/resources cleanup returned. SUBMIT_CMD=%llu TRANSFER_PUT=%llu TRANSFER_GET=%llu. No reconnect attempted; leak profiling remains separate.",
        (unsigned long long)counts[6], (unsigned long long)counts[5], (unsigned long long)counts[4]];
}
@end
