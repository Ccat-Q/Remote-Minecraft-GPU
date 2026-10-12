#pragma once

#include <cstddef>
#include <cstdint>
#include <unordered_set>
#include <unordered_map>
#include <vector>

namespace rgpu {
// Owns one legacy vtest context. The caller owns virgl_renderer_init/cleanup
// and serializes this object, poll and fenceCompleted. If callers migrate OS
// threads, their EGL provider must restore/unbind the context on each call.
// The init cookie's write_fence callback must call fenceCompleted.
// No Unix descriptor/shared-memory protocol extensions are accepted.
class VTestSession {
public:
    explicit VTestSession(uint32_t context = 1, bool allowReadbacks = true);
    ~VTestSession();
    VTestSession(const VTestSession&) = delete;
    VTestSession& operator=(const VTestSession&) = delete;
    std::vector<std::vector<uint8_t>> feed(const uint8_t* bytes, size_t count);
    void fenceCompleted(uint32_t fence);
    bool busy();
    // Capture the fence at PRESENT arrival, not at a later poll. Subsequent
    // submissions must not delay readiness of this frame.
    uint32_t submittedFence() const { return submitted_; }
    uint32_t fenceForPresent();
    bool isFenceComplete(uint32_t fence);
    void retainForPresent(uint32_t resource);
    void releaseFromPresent(uint32_t resource);
    bool atCommandBoundary() const { return pending_.empty(); }
private:
    std::vector<uint8_t> execute(uint32_t command, const uint8_t* data, size_t size);
    uint32_t context_, submitted_ = 0, completed_ = 0;
    bool initialized_ = false, failed_ = false;
    bool allowReadbacks_;
    std::vector<uint8_t> pending_;
    std::unordered_set<uint32_t> resources_;
    std::unordered_set<uint32_t> retired_;
    std::unordered_map<uint32_t, size_t> presentReferences_;
};
}
