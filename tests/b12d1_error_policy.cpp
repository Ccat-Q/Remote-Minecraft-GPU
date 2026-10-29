// Actual adapted error-selection helper only, NOT GPU / iPhone execution.
#include "DiagnosticErrors.hpp"
#include <cassert>
#include <iostream>
int main() {
    unsigned frontend = 0x502, backend = 0x500, observations = 0;
    const auto read = [&] { ++observations; const auto value = backend; backend = 0; return value; };
    assert(rgpu::diagnostic::takeError(frontend,read) == 0x502);
    assert(frontend == 0 && backend == 0x500 && observations == 0);
    assert(rgpu::diagnostic::takeError(frontend,read) == 0x500);
    assert(observations == 1 && backend == 0);
    assert(rgpu::diagnostic::takeError(frontend,read) == 0);
    assert(observations == 2);
    frontend = 0x501;
    assert(rgpu::diagnostic::takeError(frontend,read) == 0x501);
    assert(observations == 2);
    std::cout << "PASS: actual strict diagnostic error helper preserves frontend/backend errors; NOT device execution\n";
}
