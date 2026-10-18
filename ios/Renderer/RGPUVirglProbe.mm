#import "RGPUVirglProbe.h"
#include "RGPUVirglAPI.hpp"
#include "RGPUVTestSession.hpp"
#include "RGPUCapabilities.hpp"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <algorithm>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>

#include "RGPUANGLEHost.hpp"

namespace {
void append(std::vector<uint8_t>& bytes, uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) bytes.push_back(uint8_t(value >> shift));
}
uint32_t word(const std::vector<uint8_t>& bytes, size_t at) {
    return uint32_t(bytes[at]) | uint32_t(bytes[at + 1]) << 8 |
        uint32_t(bytes[at + 2]) << 16 | uint32_t(bytes[at + 3]) << 24;
}
NSString* glName(GLenum name) {
    const auto value = glGetString(name);
    return value ? [NSString stringWithUTF8String:reinterpret_cast<const char*>(value)] : @"unavailable";
}
}
@implementation RGPUVirglProbe
+ (NSString *)runWithError:(NSError **)error
{
    try {
        ANGLEHost host;
        host.initialize(true, true);
        const char name[] = "RemoteGPU iOS native gate";
        std::vector<uint8_t> request;
        append(request, sizeof(name)); append(request, 8);
        request.insert(request.end(), name, name + sizeof(name));
        append(request, 0); append(request, 9);
        append(request, 0); append(request, 1);
        auto replies = host.session->feed(request.data(), request.size());
        if (replies.size() != 2 || !host.session->atCommandBoundary())
            throw std::runtime_error("Native vtest capset response missing");
        NSMutableString *report = [NSMutableString stringWithFormat:
            @"PASS: native vtest context + caps over ANGLE Metal\nHost GL: %@\nGLSL: %@\nRenderer: %@\n",
            glName(GL_VERSION), glName(GL_SHADING_LANGUAGE_VERSION), glName(GL_RENDERER)];
        [report appendFormat:@"\n%@\n", host.versionAttempts];
        for (size_t index = 0; index < replies.size(); ++index) {
            const auto& reply = replies[index];
            if (reply.size() < 8 || word(reply, 0) != reply.size() - 7 || word(reply, 4) != (index == 0 ? 2u : 1u))
                throw std::runtime_error("Invalid native vtest capset framing");
            NSData *caps = [NSData dataWithBytes:reply.data() + 8 length:reply.size() - 8];
            const auto summary = rgpu::summarizeCaps(word(reply, 4), reply.data() + 8, caps.length);
            [report appendFormat:@"\nGuest GLSL feature level: %u (planned minimum: 150)\nRender targets: %u, samples: %u, uniform blocks: %u\n%@\n",
                summary.glslLevel, summary.renderTargets, summary.samples, summary.uniformBlocks,
                !summary.meetsGlslThreshold() ?
                    @"BLOCKED: GLSL level below the Minecraft capability gate. No version override applied." :
                    @"GLSL threshold met; guest GL 3.2 Core still needs the Ubuntu probe."];
            [report appendFormat:@"\nCapset %u: %lu bytes\nBase64: %@\n", word(reply, 4),
                (unsigned long)caps.length, [caps base64EncodedStringWithOptions:0]];
        }
        [report appendString:@"\nGuest OpenGL 3.2 Core is NOT yet verified. Ubuntu must create that context through this renderer. No remote display is connected.\n"];
        return report;
    } catch (const std::exception& failure) {
        if (error) *error = [NSError errorWithDomain:@"org.remotegpu.virgl" code:1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()]}];
        return nil;
    }
}
@end

@implementation RGPUVTestEndpoint {
    std::unique_ptr<ANGLEHost> _host;
}
+ (instancetype)createWithError:(NSError **)error
{
    try {
        RGPUVTestEndpoint *endpoint = [[self alloc] init];
        endpoint->_host = std::make_unique<ANGLEHost>();
        endpoint->_host->initialize(false);
        endpoint->_host->suspend();
        return endpoint;
    } catch (const std::exception& failure) {
        if (error) *error = [NSError errorWithDomain:@"org.remotegpu.endpoint" code:1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()]}];
        return nil;
    }
}
- (NSArray<NSData *> *)submitVTest:(NSData *)bytes error:(NSError **)error
{
    try {
        if (!_host) throw std::runtime_error("Native endpoint is not initialized");
        _host->resume();
        auto replies = _host->session->feed(static_cast<const uint8_t*>(bytes.bytes), bytes.length);
        NSMutableArray<NSData *> *result = [NSMutableArray arrayWithCapacity:replies.size()];
        for (const auto& reply : replies)
            [result addObject:[NSData dataWithBytes:reply.data() length:reply.size()]];
        _host->suspend();
        return result;
    } catch (const std::exception& failure) {
        // Even failure must release EGL thread ownership before queue cleanup.
        if (_host) { try { _host->suspend(); } catch (...) {} }
        if (error) *error = [NSError errorWithDomain:@"org.remotegpu.endpoint" code:2
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()]}];
        return nil;
    }
}
- (NSString *)hostReport
{
    if (!_host) return @"Native endpoint unavailable";
    try {
        _host->resume();
        NSString *result = [NSString stringWithFormat:@"Host GL: %@\nHost GLSL: %@\nRenderer: %@\nGuest GL 3.2 Core must be reported by Ubuntu, not inferred here.",
            glName(GL_VERSION), glName(GL_SHADING_LANGUAGE_VERSION), glName(GL_RENDERER)];
        _host->suspend();
        return result;
    } catch (...) {
        try { _host->suspend(); } catch (...) {}
        return @"Cannot query host context";
    }
}
@end
