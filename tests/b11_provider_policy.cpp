// Tests the actual policy used by the iPhone Probe, not a simulated device.
#include "ProviderPolicy.hpp"
#include <cassert>
#include <iostream>
#include <stdexcept>
#include <string>

int main() {
    using namespace rgpu::b11;
    int exported = 0, egl = 0, gles = 0, frontend = 0;
    assert(validateOptionalPlatform(nullptr, nullptr, &egl, &gles) == OptionalRoute::unavailable);
    assert(validateOptionalPlatform(&exported, &egl, &egl, &gles) == OptionalRoute::verified);
    assert(validateOptionalPlatform(&exported, &gles, &egl, &gles) == OptionalRoute::verified);
    auto rejected = [&](const void *image, const void *expectedEGL, const char *reason) {
        bool threw = false;
        try { (void)validateOptionalPlatform(&exported, image, expectedEGL, &gles); }
        catch (const std::runtime_error& error) {
            threw = std::string(error.what()).find(reason) != std::string::npos;
        }
        assert(threw);
    };
    rejected(nullptr, &egl, "no dladdr identity");
    rejected(&frontend, &egl, "foreign provider");
    rejected(&egl, nullptr, "foreign provider");
    std::cout << "PASS: actual B1.1 optional-route policy: null diagnostic, exact ANGLE owners accepted, unresolved/foreign rejected; NOT device execution\n";
}
