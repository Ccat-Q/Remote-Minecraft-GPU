#pragma once
// Actual dependency/range policy used by the isolated GL wrapper, not a GPU oracle.
#include <algorithm>
#include <cstddef>
#include <map>
#include <mutex>
#include <vector>
namespace rgpu::tbo {
struct Attachment { unsigned texture, buffer, format; };
class Attachments {
    std::mutex mutex;
    std::map<unsigned, Attachment> edges;
public:
    void attach(unsigned texture, unsigned buffer, unsigned format) {
        std::lock_guard<std::mutex> lock(mutex);
        if (texture && buffer) edges[texture] = {texture,buffer,format};
        else edges.erase(texture);
    }
    void eraseTexture(unsigned texture) {
        std::lock_guard<std::mutex> lock(mutex); edges.erase(texture);
    }
    void eraseBuffer(unsigned buffer) {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto it = edges.begin(); it != edges.end();) {
            if (it->second.buffer == buffer) it = edges.erase(it); else ++it;
        }
    }
    std::vector<Attachment> forBuffer(unsigned buffer) {
        std::lock_guard<std::mutex> lock(mutex);
        std::vector<Attachment> result;
        for (const auto& entry : edges) if (entry.second.buffer == buffer) result.push_back(entry.second);
        return result;
    }
};
struct Span { std::size_t row, x, count, byteOffset; };
inline std::vector<Span> spans(std::size_t bytes, std::size_t texelBytes,
                               std::size_t width, std::size_t offset, std::size_t count) {
    std::vector<Span> result;
    if (!texelBytes || !width || !count || offset > bytes || count > bytes-offset) return result;
    const auto elements = bytes / texelBytes;
    const auto first = offset / texelBytes;
    // Round outward to whole texels, copying their actual bytes from the GPU buffer.
    const auto endByte = offset + count;
    const auto end = std::min(elements,endByte/texelBytes + (endByte%texelBytes != 0));
    for (auto index = first; index < end;) {
        const auto n = std::min(end-index,width-index%width);
        result.push_back({index/width,index%width,n,index*texelBytes}); index += n;
    }
    return result;
}
}
