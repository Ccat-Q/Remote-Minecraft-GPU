#pragma once
// B1.2d.1 isolated diagnostic policy, NOT a capability/version override.
// Return a pending emulated error first without consuming an unrelated backend
// error. On the next query, ask the actual backend. Header used by real adapted
// glGetError and by Actions-only sanitizer tests.
namespace rgpu::diagnostic {
template<class BackendError>
unsigned takeError(unsigned& frontend,BackendError backend) {
    if (frontend != 0) {
        const unsigned error = frontend;
        frontend = 0;
        return error;
    }
    return backend();
}
}
