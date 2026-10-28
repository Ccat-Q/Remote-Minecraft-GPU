#pragma once
#include "RGPUFrameCopy.hpp"
#include "RGPUDisplaySlots.hpp"

namespace rgpu::interop {
class BufferedPresent {
    using Clock = std::chrono::steady_clock;
    struct Work {
        SlotTicket ticket{};
        ResourceDescription desc{};
        uint32_t fence = 0;
        bool retained = false;
        NSMutableString *report = [NSMutableString string];
        Clock::time_point phaseStarted = Clock::now();
        double producerMs = 0, copyMs = 0, readyMs = 0;
        double elapsed() const { return std::chrono::duration<double, std::milli>(Clock::now() - phaseStarted).count(); }
    };
    struct Storage {
        std::unique_ptr<SingleFrameCopy> copy;
        std::unique_ptr<Work> work;
        bool initialized = false;
    };
    ANGLEHost& host_;
    std::function<bool()> cancelled_;
    DisplaySlots state_;
    std::array<Storage, 2> storage_;
    id<MTLCommandQueue> queue_;
    CAMetalLayer *layer_;
    unsigned allocations_ = 0, reuse_ = 0, retired_ = 0;
    bool closed_ = false;
    static uint64_t read(const uint8_t *bytes, size_t count) {
        uint64_t value = 0; for (size_t i = 0; i < count; ++i) value = (value << 8) | bytes[i]; return value;
    }
    RGPUBufferedDisplayEvent *event(Work& work, unsigned kind, NSString *report) {
        auto result = [RGPUBufferedDisplayEvent new];
        result.kind = kind; result.slot = work.ticket.slot; result.generation = work.ticket.generation;
        result.frameID = work.ticket.frame; result.resourceID = work.ticket.resource; result.afterSequence = work.ticket.after;
        result.report = report;
        return result;
    }
public:
    BufferedPresent(ANGLEHost& host, std::function<bool()> cancelled)
        : host_(host), cancelled_(std::move(cancelled)) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        require(device != nil, "Double-buffer Metal device missing");
        queue_ = [device newCommandQueue];
        require(queue_ != nil, "Double-buffer shared Metal queue missing");
    }
    bool canAdvance() const { return !closed_ && state_.canAdvance(); }
    unsigned pending() const { return state_.inUse(); }
    NSString *statistics() const {
        return [NSString stringWithFormat:@"A32_POOL capacity=2 occupied=%u high_water=%u allocated=%u reused=%u retired=%u source_barrier=%@ iosurface_bytes_estimate=%u (not total renderer GPU memory)",
            state_.inUse(), state_.highWater(), allocations_, reuse_, retired_, state_.sourceBarrier() ? @"YES" : @"NO", allocations_ * 64 * 64 * 4];
    }
    RGPUBufferedDisplayEvent *begin(NSData *payload, CAMetalLayer *layer) {
        require(canAdvance() && !cancelled_() && payload.length == 48, "Double-buffer closed/full/source barrier active");
        const auto *bytes = static_cast<const uint8_t *>(payload.bytes);
        auto work = std::make_unique<Work>();
        const auto handle = read(bytes + 8, 8);
        work->desc = host_.session->validatePresentResource(handle,
            uint32_t(read(bytes + 24, 4)), uint32_t(read(bytes + 28, 4)),
            uint32_t(read(bytes + 32, 4)), uint32_t(read(bytes + 36, 4)),
            uint32_t(read(bytes + 40, 4)), uint32_t(read(bytes + 44, 4)));
        require(work->desc.width == 64 && work->desc.height == 64, "A3.2 retains verified 64x64 bounds");
        require(!layer_ || layer_ == layer, "Double-buffer layer changed during session");
        layer_ = layer;
        work->ticket = state_.begin(read(bytes, 8), handle, read(bytes + 16, 8));
        const auto index = work->ticket.slot;
        storage_[index].work = std::move(work); // Own before retain/fence can fail.
        auto& w = *storage_[index].work;
        host_.session->retainForPresent(uint32_t(handle)); w.retained = true;
        w.fence = host_.session->fenceForPresent(); glFlush();
        glCheck(w.report, "A32 producer fence submitted");
        [w.report appendFormat:@"A32_BEGIN frame=%llu slot=%u generation=%llu resource=%llu after=%llu producer_fence=%u; source barrier HELD\n",
            (unsigned long long)w.ticket.frame, index, (unsigned long long)w.ticket.generation,
            (unsigned long long)handle, (unsigned long long)w.ticket.after, w.fence];
        return event(w, 0, [NSString stringWithFormat:@"A32_ADMITTED frame=%llu slot=%u generation=%llu resource=%llu after=%llu; source barrier HELD\n",
            (unsigned long long)w.ticket.frame, index, (unsigned long long)w.ticket.generation,
            (unsigned long long)handle, (unsigned long long)w.ticket.after]);
    }
    NSArray<RGPUBufferedDisplayEvent *> *poll() {
        require(!closed_ && !cancelled_(), "Double-buffer session cancelled/closed");
        NSMutableArray<RGPUBufferedDisplayEvent *> *events = [NSMutableArray array];
        // Only one producer/copy at a time. Later writes are admitted only
        // AFTER its copy fence is observed complete, never via a speculative
        // cross-context GPU dependency or merely after resource pinning.
        for (unsigned index = 0; index < 2; ++index) {
            auto& slot = storage_[index];
            if (!slot.work) continue;
            auto& w = *slot.work;
            require(w.elapsed() < 10000, "Double-buffer phase timeout (local monotonic 10s)");
            const auto phase = state_.slots()[index].phase;
            if (phase == SlotPhase::producer && host_.session->isFenceComplete(w.fence)) {
                w.producerMs = w.elapsed();
                glCheck(w.report, "Remote producer fence complete");
                virgl_renderer_resource_info info{};
                require(!virgl_renderer_resource_get_info(uint32_t(w.ticket.resource), &info), "Buffered Resource Info failed");
                [w.report appendFormat:@"Resource: handle=%u tex_id=%u format=%u %ux%u depth=%u flags=0x%x stride=%u; target=%u samples=%u array=%u last_level=%u\n",
                    info.handle, info.tex_id, info.virgl_format, info.width, info.height, info.depth, info.flags, info.stride,
                    w.desc.target, w.desc.samples, w.desc.arraySize, w.desc.lastLevel];
                if (!slot.copy) slot.copy = std::make_unique<SingleFrameCopy>(host_, cancelled_, true, queue_);
                w.phaseStarted = Clock::now();
                slot.copy->beginCopy(layer_, info, w.desc, w.report, true);
                if (!slot.initialized) { slot.initialized = true; ++allocations_; } else ++reuse_;
                state_.copying(w.ticket);
            } else if (phase == SlotPhase::copying && slot.copy->pollCopy(w.report)) {
                w.copyMs = w.elapsed();
                host_.session->releaseFromPresent(uint32_t(w.ticket.resource)); w.retained = false;
                state_.snapshot(w.ticket); w.phaseStarted = Clock::now();
                [w.report appendString:@"Snapshot complete; source pin released. No later source writes preceded snapshot completion.\n"];
                [events addObject:event(w, 1, [NSString stringWithFormat:@"A32_SNAPSHOT frame=%llu slot=%u generation=%llu; copy fence complete; source barrier RELEASED (IOSurface still owned)\n",
                    (unsigned long long)w.ticket.frame, index, (unsigned long long)w.ticket.generation])];
            }
        }
        for (unsigned index = 0; index < 2; ++index) {
            auto& slot = storage_[index];
            if (state_.slots()[index].phase != SlotPhase::presenting || !slot.copy->pollDisplay()) continue;
            auto& w = *slot.work;
            [w.report appendString:@"Metal command status: COMPLETED; IOSurface retained through consumption\n"];
            const auto& counts = host_.session->commandCounts();
            require(counts[4] == 0, "Display TRANSFER_GET forbidden");
            [w.report appendFormat:@"Counts: SUBMIT_CMD=%llu TRANSFER_PUT=%llu TRANSFER_GET=%llu; Metal displayed frame=%llu\nA32_TIMING frame=%llu producer_observed_ms=%.3f copy_observed_ms=%.3f ready_observed_ms=%.3f metal_observed_ms=%.3f (local polling/setup inclusive; NOT GPU timestamps or RTT)\nA32_COMPLETED frame=%llu slot=%u generation=%llu; Metal complete; slot FREE, storage retained for reuse\n",
                (unsigned long long)counts[6], (unsigned long long)counts[5], (unsigned long long)counts[4], (unsigned long long)w.ticket.frame,
                (unsigned long long)w.ticket.frame, w.producerMs, w.copyMs, w.readyMs, w.elapsed(),
                (unsigned long long)w.ticket.frame, index, (unsigned long long)w.ticket.generation];
            [events addObject:event(w, 2, w.report)];
            state_.complete(w.ticket); ++retired_; slot.work.reset();
        }
        const int ready = state_.readySlot();
        if (ready >= 0) {
            auto& slot = storage_[unsigned(ready)]; auto& w = *slot.work;
            w.readyMs = w.elapsed(); w.phaseStarted = Clock::now();
            slot.copy->beginDisplay(); // Same Metal queue; no CPU completion wait.
            state_.presenting(w.ticket);
        }
        return events;
    }
    NSString *close() {
        if (closed_) return @"A32 pool already closed";
        closed_ = true; state_.cancel();
        NSMutableString *report = [NSMutableString string];
        unsigned released = 0, cancelledFrames = 0;
        for (auto& slot : storage_) {
            if (slot.work) { [report appendString:slot.work->report]; ++cancelledFrames; }
            try {
                if (slot.copy) {
                    require(slot.copy->close(), "Buffered slot cleanup failed");
                    if (slot.initialized) ++released;
                    slot.copy.reset();
                }
                host_.resume();
                if (slot.work && slot.work->retained)
                    host_.session->releaseFromPresent(uint32_t(slot.work->ticket.resource));
            } catch (const std::exception& failed) { [report appendFormat:@"A32_CLEANUP_ERROR %s\n", failed.what()]; }
            slot.work.reset();
        }
        [report appendFormat:@"A32_POOL_CLOSE allocated=%u released=%u cancelled_frames=%u; incomplete-copy drains are teardown-only; pending Metal holds independent IOSurface lease\n",
            allocations_, released, cancelledFrames];
        return report;
    }
    ~BufferedPresent() { if (!closed_) close(); }
};
}
