// Diagnostic host for the SAME native decoder used by the iOS renderer.
// A Unix socket here isolates protocol validation; production iOS uses QUIC.
#include "RGPUVTestSession.hpp"
#include <virgl/virglrenderer.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>

int main(int argc, char** argv) {
    if (argc != 2 || std::strlen(argv[1]) >= sizeof(sockaddr_un::sun_path)) return 2;
    int listener = -1, peer = -1;
    bool rendererInitialized = false;
    std::unique_ptr<rgpu::VTestSession> session;
    try {
        virgl_renderer_callbacks callbacks{};
        callbacks.version = 1;
        callbacks.write_fence = [](void* cookie, uint32_t fence) {
            auto& owner = *static_cast<std::unique_ptr<rgpu::VTestSession>*>(cookie);
            if (owner) owner->fenceCompleted(fence);
        };
        if (virgl_renderer_init(&session, VIRGL_RENDERER_USE_EGL | VIRGL_RENDERER_USE_SURFACELESS | VIRGL_RENDERER_USE_GLES, &callbacks))
            throw std::runtime_error("renderer initialization failed");
        rendererInitialized = true;
        listener = socket(AF_UNIX, SOCK_STREAM, 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        std::strcpy(address.sun_path, argv[1]);
        // Never unlink an existing user socket; use a private temporary path.
        if (listener < 0 || bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(listener, 1))
            throw std::runtime_error("socket setup failed");
        peer = accept(listener, nullptr, nullptr);
        if (peer < 0) throw std::runtime_error("accept failed");
        session = std::make_unique<rgpu::VTestSession>();
        uint8_t buffer[65536];
        for (;;) {
            const auto size = read(peer, buffer, sizeof(buffer));
            if (size < 0 && errno == EINTR) continue;
            if (size < 0) throw std::runtime_error("socket read failed");
            if (!size) break;
            for (const auto& reply : session->feed(buffer, size)) {
                size_t sent = 0;
                while (sent < reply.size()) {
                    const auto written = send(peer, reply.data() + sent, reply.size() - sent, MSG_NOSIGNAL);
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) throw std::runtime_error("socket write failed");
                    sent += size_t(written);
                }
            }
        }
        if (!session->atCommandBoundary()) throw std::runtime_error("truncated vtest command");
        session.reset();
        virgl_renderer_cleanup(&session);
        close(peer); close(listener); unlink(argv[1]);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "native vtest: %s\n", error.what());
        session.reset();
        if (rendererInitialized) virgl_renderer_cleanup(&session);
        if (peer >= 0) close(peer);
        if (listener >= 0) close(listener);
        return 1;
    }
}
