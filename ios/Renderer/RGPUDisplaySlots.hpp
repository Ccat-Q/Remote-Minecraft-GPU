#pragma once
#include <array>
#include <cstdint>
#include <stdexcept>

namespace rgpu {
enum class SlotPhase { free, producer, copying, ready, presenting };
struct SlotTicket {
    unsigned slot;
    uint64_t generation, frame, resource, after;
    bool operator==(const SlotTicket& other) const {
        return slot == other.slot && generation == other.generation && frame == other.frame &&
            resource == other.resource && after == other.after;
    }
};
struct DisplaySlot { SlotPhase phase = SlotPhase::free; SlotTicket ticket{}; };

// Actual native ownership state, also compiled in Linux sanitizer tests.
// Source writes resume only after COPYING -> READY; IOSurface reuse only
// after PRESENTING -> FREE. One Metal submission at a time, two owned slots.
class DisplaySlots {
    std::array<DisplaySlot, 2> slots_{};
    uint64_t generation_ = 0, accepted_ = 0, snapshotted_ = 0, submitted_ = 0, displayed_ = 0;
    unsigned next_ = 0, highWater_ = 0;
    bool cancelled_ = false;
    static void check(bool ok) { if (!ok) throw std::runtime_error("Invalid/stale double-buffer slot transition"); }
    DisplaySlot& owned(const SlotTicket& ticket, SlotPhase phase) {
        check(!cancelled_ && ticket.slot < slots_.size());
        auto& slot = slots_[ticket.slot];
        check(slot.ticket == ticket && slot.phase == phase);
        return slot;
    }
public:
    const std::array<DisplaySlot, 2>& slots() const { return slots_; }
    unsigned inUse() const {
        unsigned count = 0; for (const auto& slot : slots_) count += slot.phase != SlotPhase::free; return count;
    }
    bool sourceBarrier() const {
        for (const auto& slot : slots_)
            if (slot.phase == SlotPhase::producer || slot.phase == SlotPhase::copying) return true;
        return false;
    }
    bool canAdvance() const { return !cancelled_ && !sourceBarrier() && inUse() < 2; }
    unsigned highWater() const { return highWater_; }
    uint64_t displayed() const { return displayed_; }
    SlotTicket begin(uint64_t frame, uint64_t resource, uint64_t after) {
        check(canAdvance() && frame == accepted_ + 1 && frame <= 16 && resource && resource <= UINT32_MAX && after);
        for (unsigned offset = 0; offset < 2; ++offset) {
            const unsigned index = (next_ + offset) % 2;
            if (slots_[index].phase != SlotPhase::free) continue;
            SlotTicket ticket{index, ++generation_, frame, resource, after};
            slots_[index] = {SlotPhase::producer, ticket};
            next_ = (index + 1) % 2; accepted_ = frame;
            if (inUse() > highWater_) highWater_ = inUse();
            return ticket;
        }
        throw std::runtime_error("Double-buffer backpressure");
    }
    void copying(const SlotTicket& ticket) { owned(ticket, SlotPhase::producer).phase = SlotPhase::copying; }
    void snapshot(const SlotTicket& ticket) {
        check(ticket.frame == snapshotted_ + 1);
        owned(ticket, SlotPhase::copying).phase = SlotPhase::ready;
        snapshotted_ = ticket.frame;
    }
    // Conservative display policy: no nextDrawable acquisition while an older
    // Metal consumption is pending. GPU copy in the other slot can overlap it.
    int readySlot() const {
        if (cancelled_) return -1;
        for (const auto& slot : slots_) if (slot.phase == SlotPhase::presenting) return -1;
        for (unsigned index = 0; index < 2; ++index)
            if (slots_[index].phase == SlotPhase::ready && slots_[index].ticket.frame == submitted_ + 1)
                return int(index);
        return -1;
    }
    void presenting(const SlotTicket& ticket) {
        check(readySlot() == int(ticket.slot));
        owned(ticket, SlotPhase::ready).phase = SlotPhase::presenting;
        submitted_ = ticket.frame;
    }
    void complete(const SlotTicket& ticket) {
        check(ticket.frame == displayed_ + 1);
        owned(ticket, SlotPhase::presenting).phase = SlotPhase::free;
        displayed_ = ticket.frame;
    }
    void cancel() { cancelled_ = true; } // GPU teardown owns draining; never recycle early.
};
}
