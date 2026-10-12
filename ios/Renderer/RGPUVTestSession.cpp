#include "RGPUVTestSession.hpp"

#include <virgl/virglrenderer.h>
#include <sys/uio.h>
#include <chrono>
#include <algorithm>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <thread>

// Public virglrenderer.h forward-declares this argument but does not install
// virgl_hw.h. ABI from pinned UTM virglrenderer 482f9d8 src/virgl_hw.h.
struct virgl_box { uint32_t x, y, z, w, h, d; };
static_assert(sizeof(virgl_box) == 24, "virgl transfer box ABI");

namespace rgpu {
namespace {
constexpr size_t limit = 16 * 1024 * 1024;
uint32_t word(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
void append(std::vector<uint8_t>& out, uint32_t value) {
    for (int i = 0; i < 4; ++i) out.push_back(uint8_t(value >> (8 * i)));
}
void check(int result, const char* operation) {
    if (result) throw std::runtime_error(operation);
}
void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
}

VTestSession::VTestSession(uint32_t context) : context_(context) {
    require(context != 0, "vtest context must be nonzero");
}
VTestSession::~VTestSession() {
    if (initialized_) virgl_renderer_context_destroy(context_);
    for (auto handle : resources_) virgl_renderer_resource_unref(handle);
}
void VTestSession::fenceCompleted(uint32_t fence) {
    // IDs never wrap in this session, so an old callback cannot clear a newer fence.
    if (fence <= submitted_ && fence > completed_) completed_ = fence;
}
bool VTestSession::busy() {
    virgl_renderer_poll();
    return completed_ != submitted_;
}

std::vector<std::vector<uint8_t>> VTestSession::feed(const uint8_t* bytes, size_t count) {
    require(!failed_, "vtest session already failed");
    std::vector<std::vector<uint8_t>> replies;
    try {
        // Append incrementally: arbitrarily many coalesced messages are allowed
        // without permitting a single incomplete message to exhaust memory.
        for (size_t at = 0; at < count;) {
            size_t need = pending_.size() < 8 ? 8 : 8 + size_t(word(pending_.data())) * 4;
            if (pending_.size() >= 8) {
                const auto command = word(pending_.data() + 4);
                require(command >= 1 && command <= 9, "REMOTEGPU_ERR_UNSUPPORTED_VTEST_COMMAND");
                if (command == 8) need = 8 + size_t(word(pending_.data()));
                if (command == 5) {
                    if (pending_.size() < 52) need = 52;
                    else {
                        const auto payload = word(pending_.data() + 48);
                        require(word(pending_.data()) == 11 + (size_t(payload) + 3) / 4,
                                "invalid TRANSFER_PUT length");
                        need = 52 + size_t(payload); // wire data is NOT dword padded
                    }
                }
                require(need <= limit, "vtest message exceeds limit");
            }
            const size_t take = std::min(need - pending_.size(), count - at);
            pending_.insert(pending_.end(), bytes + at, bytes + at + take);
            at += take;
            if (pending_.size() < 8) continue;
            const auto command = word(pending_.data() + 4);
            // Recompute after reading the header/TRANSFER_PUT arguments.
            size_t total = 8 + size_t(word(pending_.data())) * 4;
            require(command >= 1 && command <= 9, "REMOTEGPU_ERR_UNSUPPORTED_VTEST_COMMAND");
            if (command == 8) total = 8 + size_t(word(pending_.data()));
            if (command == 5) {
                require(word(pending_.data()) >= 11, "short TRANSFER_PUT header");
                if (pending_.size() < 52) continue;
                const auto payload = word(pending_.data() + 48);
                require(word(pending_.data()) == 11 + (size_t(payload) + 3) / 4,
                        "invalid TRANSFER_PUT length");
                total = 52 + size_t(payload);
            }
            require(total <= limit, "vtest message exceeds limit");
            if (pending_.size() != total) continue;
            auto reply = execute(command, pending_.data() + 8, total - 8);
            if (!reply.empty()) replies.push_back(std::move(reply));
            pending_.clear();
        }
    } catch (...) {
        failed_ = true;
        throw;
    }
    return replies;
}

std::vector<uint8_t> VTestSession::execute(uint32_t command, const uint8_t* data, size_t size) {
    std::vector<uint8_t> reply;
    if (command == 8) {
        require(!initialized_ && size > 0 && size <= 4096 && data[size - 1] == 0,
                "invalid CREATE_RENDERER");
        check(virgl_renderer_context_create(context_, uint32_t(size), reinterpret_cast<const char*>(data)),
              "virgl context create failed");
        initialized_ = true;
        return reply;
    }
    require(initialized_, "CREATE_RENDERER required first");
    switch (command) {
    case 1: case 9: {
        require(size == 0, "invalid GET_CAPS length");
        const uint32_t set = command == 1 ? 1 : 2;
        uint32_t version = 0, bytes = 0;
        virgl_renderer_get_cap_set(set, &version, &bytes);
        require(version >= 1 && bytes > 0 && bytes <= limit - 8, "unsupported virgl capset");
        // Historical vtest caps replies use byte count + 1, NOT dword count.
        append(reply, bytes + 1); append(reply, set);
        std::vector<uint32_t> caps((bytes + 3) / 4);
        virgl_renderer_fill_caps(set, 1, caps.data());
        auto start = reinterpret_cast<uint8_t*>(caps.data());
        reply.insert(reply.end(), start, start + bytes);
        break;
    }
    case 2: {
        require(size == 40, "invalid RESOURCE_CREATE length");
        const auto handle = word(data);
        require(handle != 0 && !resources_.count(handle), "duplicate/zero resource handle");
        virgl_renderer_resource_create_args args{};
        args.handle = handle; args.target = word(data + 4); args.format = word(data + 8);
        args.bind = word(data + 12); args.width = word(data + 16); args.height = word(data + 20);
        args.depth = word(data + 24); args.array_size = word(data + 28);
        args.last_level = word(data + 32); args.nr_samples = word(data + 36);
        check(virgl_renderer_resource_create(&args, nullptr, 0), "virgl resource create failed");
        resources_.insert(handle);
        virgl_renderer_ctx_attach_resource(context_, handle);
        break;
    }
    case 3: {
        require(size == 4 && resources_.count(word(data)), "invalid RESOURCE_UNREF");
        const auto handle = word(data);
        virgl_renderer_ctx_detach_resource(context_, handle);
        virgl_renderer_resource_unref(handle);
        resources_.erase(handle);
        break;
    }
    case 4: case 5: {
        require(size >= 44 && resources_.count(word(data)), "invalid transfer resource");
        const uint32_t bytes = word(data + 40);
        require(bytes > 0 && bytes <= limit - 52, "unsupported zero/oversized transfer");
        require(size == (command == 4 ? 44 : 44 + size_t(bytes)), "invalid transfer length");
        virgl_box box{};
        box.x = word(data + 16); box.y = word(data + 20); box.z = word(data + 24);
        box.w = word(data + 28); box.h = word(data + 32); box.d = word(data + 36);
        std::vector<uint8_t> buffer(bytes);
        if (command == 5) std::memcpy(buffer.data(), data + 44, bytes);
        iovec iov{buffer.data(), buffer.size()};
        if (command == 4) {
            check(virgl_renderer_transfer_read_iov(word(data), context_, word(data + 4),
                  word(data + 8), word(data + 12), &box, 0, &iov, 1), "virgl transfer read failed");
            reply = std::move(buffer); // raw bytes; no reply header
        } else {
            check(virgl_renderer_transfer_write_iov(word(data), context_, word(data + 4),
                  word(data + 8), word(data + 12), &box, 0, &iov, 1), "virgl transfer write failed");
        }
        break;
    }
    case 6: {
        require(size % 4 == 0, "unaligned SUBMIT_CMD length");
        std::vector<uint32_t> commands(size / 4);
        if (size) std::memcpy(commands.data(), data, size);
        check(virgl_renderer_submit_cmd(commands.data(), context_, int(commands.size())), "virgl submit failed");
        require(submitted_ < uint32_t(std::numeric_limits<int>::max()), "fence IDs exhausted; reconnect required");
        check(virgl_renderer_create_fence(int(++submitted_), 0), "virgl fence create failed");
        break;
    }
    case 7: {
        require(size == 8 && (word(data + 4) & ~1u) == 0, "invalid BUSY_WAIT");
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (busy() && (word(data + 4) & 1)) {
            require(std::chrono::steady_clock::now() < deadline, "renderer fence timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        append(reply, 1); append(reply, 7); append(reply, busy() ? 1 : 0);
        break;
    }
    }
    return reply;
}
}
