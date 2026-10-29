// Exercises the exact App query plan. Fixture values are NOT device evidence.
#include "ContextMetadata.hpp"
#include <cassert>
#include <iostream>
#include <stdexcept>
#include <utility>
#include <vector>

int main() {
    using namespace rgpu::b11;
    std::vector<std::pair<char, unsigned>> calls;
    // Deliberately non-GL-version fixture values: helper must neither infer
    // version support nor substitute creation-request values or a Core bit.
    const auto data = queryContextMetadata([&](int token) {
        calls.emplace_back('E', token);
        if (token == eglContextClientType) return 71;
        assert(token == eglConfigId); return 72;
    }, [&](unsigned token) {
        calls.emplace_back('G', token);
        if (token == glMajorVersion) return 81;
        if (token == glMinorVersion) return 82;
        assert(token == glContextProfileMask); return 83;
    });
    const std::vector<std::pair<char, unsigned>> expected = {
        {'E', 0x3097}, {'E', 0x3028}, {'G', 0x821B}, {'G', 0x821C}, {'G', 0x9126}};
    assert(calls == expected);
    assert(data.clientType == 71 && data.configId == 72 && data.major == 81 && data.minor == 82 && data.profile == 83);
    // Every individual error must propagate, not become fabricated metadata.
    for (int failAt = 0; failAt < 5; ++failAt) {
        int visited = 0;
        auto query = [&](auto) { if (visited++ == failAt) throw std::runtime_error("query failed"); return 0; };
        bool threw = false;
        try { (void)queryContextMetadata(query, query); }
        catch (const std::runtime_error&) { threw = true; }
        assert(threw && visited == failAt + 1);
    }
    std::cout << "PASS: actual B1.1 metadata plan uses EGL client/config and GL version/profile; no invalid EGL creation-attribute queries, fabricated values or swallowed errors; NOT device execution\n";
}
