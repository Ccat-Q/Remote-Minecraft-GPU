// Diagnostic host for the SAME native decoder used by the iOS renderer.
// A Unix socket here isolates protocol validation; production iOS uses QUIC.
#include "RGPUVTestSession.hpp"
#include "RGPUVirglAPI.hpp"
#include "remote-present-verifier.hpp"
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <memory>
#include <cstdlib>
#include <algorithm>
#include <stdexcept>

static int listenUnix(const char* path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strcpy(address.sun_path, path);
    if (fd < 0 || bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(fd, 1)) {
        if (fd >= 0) close(fd);
        throw std::runtime_error("socket setup failed");
    }
    return fd;
}
static void exactRead(int fd, uint8_t* bytes, size_t count) {
    while (count) {
        pollfd p{fd, POLLIN, 0};
        int ready;
        do { ready = poll(&p, 1, 5000); } while (ready < 0 && errno == EINTR);
        if (ready <= 0) throw std::runtime_error("oracle control/read deadline");
        auto n = read(fd, bytes, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) throw std::runtime_error("truncated oracle request/vtest prefix");
        bytes += n; count -= size_t(n);
    }
}
int main(int argc, char** argv) {
    const char* controlPath = nullptr;
    unsigned expectedFrames = 0;
    if (argc == 6 && !std::strcmp(argv[2], "--verify-present-socket") && !std::strcmp(argv[4], "--expected-frames")) {
        controlPath = argv[3];
        char* end = nullptr;
        auto n = std::strtoul(argv[5], &end, 10);
        if (!end || *end || n < 1 || n > 100000) return 2;
        expectedFrames = unsigned(n);
    } else if (argc != 2) return 2;
    if (std::strlen(argv[1]) >= sizeof(sockaddr_un::sun_path) ||
        (controlPath && std::strlen(controlPath) >= sizeof(sockaddr_un::sun_path))) return 2;
    int listener = -1, peer = -1, controlListener = -1, control = -1;
    bool rendererInitialized = false;
    std::unique_ptr<rgpu::VTestSession> session;
    try {
        virgl_renderer_callbacks callbacks{};
        callbacks.version = 1;
        callbacks.write_fence = [](void* cookie, uint32_t fence) {
            auto& owner = *static_cast<std::unique_ptr<rgpu::VTestSession>*>(cookie);
            if (owner) owner->fenceCompleted(fence);
        };
        std::fprintf(stderr, "native vtest: initializing EGL renderer\n");
        if (virgl_renderer_init(&session, VIRGL_RENDERER_USE_EGL | VIRGL_RENDERER_USE_SURFACELESS | VIRGL_RENDERER_USE_GLES, &callbacks))
            throw std::runtime_error("renderer initialization failed");
        rendererInitialized = true;
        // Never unlink an existing user socket; use a private temporary path.
        listener = listenUnix(argv[1]);
        if (controlPath) controlListener = listenUnix(controlPath);
        std::fprintf(stderr, "native vtest: ready on %s\n", argv[1]);
        peer = accept(listener, nullptr, nullptr);
        if (peer < 0) throw std::runtime_error("accept failed");
        session = std::make_unique<rgpu::VTestSession>();
        std::unique_ptr<rgpu_test::FrameVerifier> verifier;
        if (controlPath) {
            control = accept(controlListener, nullptr, nullptr);
            if (control < 0) throw std::runtime_error("oracle accept failed");
            verifier = std::make_unique<rgpu_test::FrameVerifier>(expectedFrames);
        }
        uint8_t buffer[65536];
        uint64_t consumed = 0;
        auto lastInput = std::chrono::steady_clock::now();
        auto feed = [&](size_t size) {
            consumed += size;
            lastInput = std::chrono::steady_clock::now();
            for (const auto& reply : session->feed(buffer, size)) {
                size_t sent = 0;
                while (sent < reply.size()) {
                    const auto written = send(peer, reply.data() + sent, reply.size() - sent, MSG_NOSIGNAL);
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) throw std::runtime_error("socket write failed");
                    sent += size_t(written);
                }
            }
        };
        for (;;) {
            if (verifier) {
                // Require a real idle command stream, not merely elapsed
                // time since PRESENT (glFinish can send a later BUSY_WAIT).
                if (std::chrono::steady_clock::now() - lastInput >= std::chrono::milliseconds(400))
                    verifier->pollHold(*session);
                pollfd fds[] = {{peer, POLLIN, 0}, {control, POLLIN, 0}};
                int ready = poll(fds, 2, 20);
                if (ready < 0 && errno == EINTR) continue;
                if (ready < 0) throw std::runtime_error("oracle poll failed");
                if (fds[1].revents & POLLIN) {
                    uint8_t first;
                    auto available = recv(control, &first, 1, MSG_PEEK);
                    if (available < 0 && errno == EINTR) continue;
                    if (available == 0) {
                        // The receiver closes its control connection before
                        // the raw vtest socket. Drain the latter's cleanup/
                        // UNREF commands and finish only at its real EOF.
                        close(control);
                        control = -1;
                        continue;
                    }
                    if (available < 0) throw std::runtime_error("oracle control peek failed");
                    uint8_t request[56]; // BE raw byte offset + unchanged PRESENT payload.
                    exactRead(control, request, sizeof(request));
                    const auto boundary = rgpu_test::be(request, 8);
                    rgpu_test::require(boundary >= consumed, "PRESENT arrived after later commands");
                    while (consumed < boundary) {
                        const auto count = size_t(std::min<uint64_t>(sizeof(buffer), boundary - consumed));
                        exactRead(peer, buffer, count);
                        feed(count);
                    }
                    verifier->verify(request + 8, *session);
                    size_t sent = 0;
                    while (sent < 8) {
                        auto n = send(control, request + 8 + sent, 8 - sent, MSG_NOSIGNAL);
                        if (n < 0 && errno == EINTR) continue;
                        if (n <= 0) throw std::runtime_error("oracle ACK failed");
                        sent += size_t(n);
                    }
                    continue;
                }
                if (!(fds[0].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            }
            const auto size = read(peer, buffer, sizeof(buffer));
            if (size < 0 && errno == EINTR) continue;
            if (size < 0) throw std::runtime_error("socket read failed");
            if (!size) break;
            feed(size_t(size));
        }
        if (!session->atCommandBoundary()) throw std::runtime_error("truncated vtest command");
        if (verifier) verifier->finish(*session);
        session.reset();
        virgl_renderer_cleanup(&session);
        close(peer); close(listener); unlink(argv[1]);
        if (control >= 0) close(control);
        if (controlListener >= 0) { close(controlListener); unlink(controlPath); }
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "native vtest: %s\n", error.what());
        session.reset();
        if (rendererInitialized) virgl_renderer_cleanup(&session);
        if (peer >= 0) close(peer);
        if (listener >= 0) close(listener);
        if (control >= 0) close(control);
        if (controlListener >= 0) close(controlListener);
        return 1;
    }
}
