#pragma once
#import <Foundation/Foundation.h>
#include <functional>
// Resolvers validate exact images and frontend direct/proc equality before any
// GL call. Everything executes on the current, exclusive Probe owner thread.
void RGPURunShaderDrawProbe(NSMutableString *report,
    const std::function<void*(const char*)>& frontend,
    const std::function<void*(const char*)>& backend);
#if RGPU_B12_FEATURE_PROBE
void RGPURunInstancingSyncProbe(NSMutableString *report,
    const std::function<void*(const char*)>& frontend,
    const std::function<void*(const char*)>& backend);
#endif
#if RGPU_B12_CORE_PROBE
#include "CapabilityFixtures.hpp"
// One invocation per fresh, unshared context; failures throw after local cleanup.
void RGPURunCapabilityProbe(NSMutableString *report,
    const std::function<void*(const char*)>& frontend,
    const std::function<void*(const char*)>& backend,
    rgpu::b12::Capability kind);
#endif
#if RGPU_B12_RASTER_PROBE
void RGPURunRasterProbe(NSMutableString *report,
    const std::function<void*(const char*)>& frontend,
    const std::function<void*(const char*)>& backend);
#endif
