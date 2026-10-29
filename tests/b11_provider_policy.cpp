// Tests the actual policy used by the iPhone Probe, not a simulated device.
#include "Bootstrap.h"
#include <cassert>
#include <iostream>
#include <initializer_list>
#include <stdexcept>
#include <string>

int main() {
    using namespace rgpu::b11;
    int exported = 0, proc = 0, egl = 0, gles = 0, frontend = 0;
    int exportQueries = 0, procQueries = 0, identities = 0;
    auto resolve = [&](void *direct, void *extension, const void *base) {
        exportQueries = procQueries = identities = 0;
        return selectPlatform([&] { ++exportQueries; return direct; },
            [&] { ++procQueries; return extension; },
            [&](void *p) { assert(p == (direct ? direct : extension)); ++identities; return base; },
            &egl, &gles);
    };
    auto selected = resolve(&exported, &proc, &egl);
    assert(selected.address == &exported && selected.route == PlatformRoute::exported);
    assert(exportQueries == 1 && procQueries == 0 && identities == 1);
    // Exact reported device condition: export absent, ANGLE proc table present.
    for (const void *base : {&egl, &gles}) {
        selected = resolve(nullptr, &proc, base);
        assert(selected.address == &proc && selected.route == PlatformRoute::proc);
        assert(exportQueries == 1 && procQueries == 1 && identities == 1);
    }
    auto rejected = [&](void *direct, void *extension, const void *base, const char *reason) {
        bool threw = false;
        try { (void)resolve(direct, extension, base); }
        catch (const std::runtime_error& error) {
            threw = std::string(error.what()).find(reason) != std::string::npos;
        }
        assert(threw);
    };
    rejected(nullptr, nullptr, nullptr, "export and proc absent");
    assert(identities == 0);
    rejected(nullptr, &proc, nullptr, "no dladdr identity");
    rejected(nullptr, &proc, &frontend, "Wrong ANGLE");
    rejected(&exported, &proc, &gles, "Wrong ANGLE");
    assert(procQueries == 0); // do not hide a foreign direct export via fallback
    rejected(&exported, &proc, &frontend, "Wrong ANGLE");
    assert(procQueries == 0);
    rejected(&exported, &proc, nullptr, "no dladdr identity");
    assert(procQueries == 0);
    for (const void *anchor : {static_cast<const void*>(nullptr), static_cast<const void*>(&gles)}) {
        bool threw = false;
        try { (void)selectPlatform([]() -> void* { assert(false); return nullptr; },
            []() -> void* { assert(false); return nullptr; }, [](void*) -> const void* { assert(false); return nullptr; }, anchor, &gles); }
        catch (const std::runtime_error&) { threw = true; }
        assert(threw);
    }
    std::cout << "PASS: actual B1.1 shared resolver: export absent/proc valid accepted; absent, unresolved, foreign and invalid anchors rejected; lazy fallback; NOT device execution\n";
}
