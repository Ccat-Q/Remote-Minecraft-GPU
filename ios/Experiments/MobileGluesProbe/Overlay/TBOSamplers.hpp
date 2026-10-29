#pragma once
// Token-aware, typed samplerBuffer lowering before glslang/SPIRV-Cross.
// One emulation binding/dimension set, matching the pinned provider limitation.
#include <cctype>
#include <algorithm>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
namespace rgpu::tbo {
struct Token { std::size_t begin, end; std::string text; };
inline std::vector<Token> tokens(const std::string& source) {
    std::vector<Token> result;
    for (std::size_t i = 0; i < source.size();) {
        const auto c = static_cast<unsigned char>(source[i]);
        if (std::isspace(c)) { ++i; continue; }
        if (source.compare(i,2,"//") == 0) {
            const auto end = source.find('\n',i+2); i = end == std::string::npos ? source.size() : end; continue;
        }
        if (source.compare(i,2,"/*") == 0) {
            const auto end = source.find("*/",i+2);
            if (end == std::string::npos) throw std::runtime_error("Unterminated GLSL comment");
            i = end+2; continue;
        }
        const auto start = i++;
        if (std::isalpha(c) || c == '_') {
            while (i < source.size() && (std::isalnum(static_cast<unsigned char>(source[i])) || source[i] == '_')) ++i;
        }
        result.push_back({start,i,source.substr(start,i-start)});
    }
    return result;
}
inline std::string lowerSamplers(std::string source, std::size_t insertion) {
    const auto words = tokens(source);
    std::set<std::string> buffers, kinds;
    struct Edit { std::size_t begin, length; std::string value; };
    std::vector<Edit> edits;
    for (std::size_t i = 0; i+1 < words.size(); ++i) {
        const auto& type = words[i].text;
        if (type != "samplerBuffer" && type != "isamplerBuffer" && type != "usamplerBuffer") continue;
        if (i+2 >= words.size() || words[i+2].text != ";")
            throw std::runtime_error("TBO lowering supports scalar named declarations only; arrays/parameters NOT implemented");
        buffers.insert(words[i+1].text); kinds.insert(type);
        edits.push_back({words[i].begin,words[i].end-words[i].begin,
                         type == "samplerBuffer" ? "sampler2D" : type == "isamplerBuffer" ? "isampler2D" : "usampler2D"});
    }
    if (buffers.empty()) return source;
    for (const auto& word : words) {
        if (word.text == "rgpuBufferFetch" || word.text == "u_BufferTexWidth" || word.text == "u_BufferTexHeight")
            throw std::runtime_error("GLSL identifier conflicts with TBO emulation support");
    }
    for (std::size_t i = 0; i+3 < words.size(); ++i) {
        if (words[i].text == "texelFetch" && words[i+1].text == "(" &&
            buffers.count(words[i+2].text) && words[i+3].text == ",")
            edits.push_back({words[i].begin,words[i].end-words[i].begin,"rgpuBufferFetch"});
    }
    std::string support = "\nuniform int u_BufferTexWidth;\nuniform int u_BufferTexHeight;\n";
    for (const auto& kind : kinds) {
        const std::string prefix = kind == "samplerBuffer" ? "" : kind == "isamplerBuffer" ? "i" : "u";
        support += prefix + "vec4 rgpuBufferFetch(" + prefix + "sampler2D tex, int index) {\n"
                   "    return texelFetch(tex, ivec2(index % u_BufferTexWidth, index / u_BufferTexWidth), 0);\n}\n";
    }
    // Edits run backwards, preserving offsets in the original source.
    std::sort(edits.begin(),edits.end(),[](const Edit& a,const Edit& b) { return a.begin > b.begin; });
    for (const auto& edit : edits) source.replace(edit.begin,edit.length,edit.value);
    // Support is inserted after preprocessor directives; all changed tokens must follow it.
    for (const auto& edit : edits) if (edit.begin < insertion)
        throw std::runtime_error("TBO declaration before support insertion point");
    source.insert(insertion,support);
    return source;
}
}
