#pragma once

#include <cstddef>
#include <cstdint>
#include <unordered_set>
#include <vector>

namespace rgpu {
// Owns one legacy vtest context. The caller owns virgl_renderer_init/cleanup
// and invokes this object, poll and fenceCompleted on one renderer thread.
// The init cookie's write_fence callback must call fenceCompleted.
// No Unix descriptor/shared-memory protocol extensions are accepted.
class VTestSession {
public:
    explicit VTestSession(uint32_t context = 1);
    ~VTestSession();
    VTestSession(const VTestSession&) = delete;
    VTestSession& operator=(const VTestSession&) = delete;
    std::vector<std::vector<uint8_t>> feed(const uint8_t* bytes, size_t count);
    void fenceCompleted(uint32_t fence);
    bool busy();
    bool atCommandBoundary() const { return pending_.empty(); }
private:
    std::vector<uint8_t> execute(uint32_t command, const uint8_t* data, size_t size);
    uint32_t context_, submitted_ = 0, completed_ = 0;
    bool initialized_ = false, failed_ = false;
    std::vector<uint8_t> pending_;
    std::unordered_set<uint32_t> resources_;
};
}
