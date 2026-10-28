// Actual native slot engine; deterministic delayed-GPU ownership, not device pixels.
#include "RGPUDisplaySlots.hpp"
#include <cstdio>
#include <stdexcept>
static void check(bool ok) { if (!ok) throw std::runtime_error("slot contract assertion"); }
template<class Function> void rejects(Function fn) {
    bool failed = false; try { fn(); } catch (const std::exception&) { failed = true; }
    check(failed);
}
int main() try {
    using namespace rgpu;
    DisplaySlots pool;
    auto first = pool.begin(1, 42, 1);
    check(first.slot == 0 && !pool.canAdvance());
    rejects([&] { pool.begin(2, 42, 2); });
    pool.copying(first); rejects([&] { pool.complete(first); });
    pool.snapshot(first); check(pool.canAdvance()); pool.presenting(first);
    // Delay older Metal completion; next source writes/copy can now overlap it.
    auto second = pool.begin(2, 42, 2);
    check(second.slot == 1 && pool.inUse() == 2);
    pool.copying(second); pool.snapshot(second);
    check(!pool.canAdvance() && pool.readySlot() == -1);
    rejects([&] { pool.begin(3, 42, 3); });
    rejects([&] { pool.presenting(second); });
    rejects([&] { pool.complete(second); });
    pool.complete(first); pool.presenting(second);
    auto third = pool.begin(3, 42, 3);
    check(third.slot == first.slot && third.generation != first.generation);
    rejects([&] { pool.copying(first); });
    auto wrong = third; wrong.resource = 43;
    rejects([&] { pool.copying(wrong); });
    pool.copying(third); pool.snapshot(third); pool.complete(second); pool.presenting(third); pool.complete(third);
    check(pool.highWater() == 2 && pool.displayed() == 3 && pool.inUse() == 0);
    for (uint64_t frame = 4; frame <= 16; ++frame) {
        auto ticket = pool.begin(frame, 42, frame);
        pool.copying(ticket); pool.snapshot(ticket); pool.presenting(ticket); pool.complete(ticket);
    }
    rejects([&] { pool.begin(17, 42, 17); });
    // Cancel at every ownership stage: never return a busy slot for reuse.
    for (int stage = 0; stage < 4; ++stage) {
        DisplaySlots cancelled;
        auto ticket = cancelled.begin(1, 42, 1);
        if (stage >= 1) cancelled.copying(ticket);
        if (stage >= 2) cancelled.snapshot(ticket);
        if (stage >= 3) cancelled.presenting(ticket);
        cancelled.cancel();
        check(!cancelled.canAdvance() && cancelled.inUse() == 1);
        rejects([&] { cancelled.complete(ticket); });
        rejects([&] { cancelled.begin(2, 42, 2); });
    }
    std::puts("PASS: native two-slot capacity, delayed Metal/backpressure, source-copy barrier, stale generations, cancellation and 16-frame bound");
    return 0;
} catch (const std::exception& failed) { std::fprintf(stderr, "FAIL: %s\n", failed.what()); return 1; }
