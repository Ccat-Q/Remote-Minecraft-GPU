#import "Probe.h"
#import <UIKit/UIKit.h>
#include <vulkan/vulkan.h>
#include <sys/utsname.h>
#include <dlfcn.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <vector>
#include "CapabilityDump.inc"

namespace {
constexpr uint32_t W=32, H=32;
std::mutex logMutex;
std::atomic_uint validationErrors{0}, driverErrors{0};
NSFileHandle *journal;
void log(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
void log(NSString *format, ...) {
    va_list args; va_start(args,format);
    NSString *line=[[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    std::lock_guard<std::mutex> lock(logMutex);
    [journal writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [journal synchronizeFile];
}
void saveJSON(NSString *name, id value) {
    NSError *error=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToURL:[RGPUGeometryReportDirectory() URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error])
        throw std::runtime_error("Cannot persist diagnostic JSON");
    log(@"JSON %@: %@",name,[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}
void check(VkResult r,const char *name) {
    log(@"VK %s result=%d",name,r);
    if(r!=VK_SUCCESS) throw std::runtime_error(std::string(name)+" VkResult="+std::to_string(r));
}
VKAPI_ATTR VkBool32 VKAPI_CALL debugCallback(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT type,const VkDebugUtilsMessengerCallbackDataEXT *data,void *) {
    bool validation=(type&VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT)!=0;
    if(severity&VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        if(validation) ++validationErrors; else ++driverErrors;
    }
    log(@"DEBUG severity=0x%x type=0x%x id=%s message=%s",severity,type,
        data->pMessageIdName?:"",data->pMessage?:"");
    return VK_FALSE;
}
struct Buffer { VkBuffer handle{}; VkDeviceMemory memory{}; VkDeviceSize size{}; void *mapped{}; };
struct Vertex { float x,y,r,g,b,a; };
struct Parameters { float offset[4]; float tint[4]; };
using Color=std::array<uint8_t,4>;
using Pixels=std::array<Color,W*H>;
struct Case {
    const char *name,*shader;
    VkPrimitiveTopology topology;
    uint32_t vertices, outputVertices=8, invocations=1;
    bool indirect=false, indexed=false, capture=false;
    int kind=0; // 0=two quads, 1=line strips, 2=points, 3=primitiveID, 4=invocations, 5=gradient
};
class Engine {
public:
    VkInstance instance{}; VkDebugUtilsMessengerEXT messenger{}; VkPhysicalDevice physical{};
    VkDevice device{}; VkQueue queue{}; uint32_t family=0;
    VkPhysicalDeviceFeatures features{}; VkPhysicalDeviceProperties properties{};
    VkPhysicalDeviceMemoryProperties memory{}; bool safeToDestroy=true, validation=false;
    bool transformFeedback=false, depthClip=false;
    VkPhysicalDeviceTransformFeedbackPropertiesEXT xfbLimits{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT};
    std::vector<VkExtensionProperties> extensions;
    std::vector<Buffer> buffers;
    VkImage image{}; VkDeviceMemory imageMemory{}; VkImageView view{};
    VkRenderPass renderPass{}; VkFramebuffer framebuffer{}; VkCommandPool pool{};
    VkCommandBuffer command{}; VkFence fence{}; VkDescriptorSetLayout setLayout{};
    VkPipelineLayout layout{}; VkDescriptorPool descriptorPool{}; VkDescriptorSet descriptor{};
    VkPipeline pipeline{}; std::vector<VkShaderModule> modules;
    Buffer vertex,uniform,readback,indirect,index,xfb;
    PFN_vkCmdBindTransformFeedbackBuffersEXT bindXfb{};
    PFN_vkCmdBeginTransformFeedbackEXT beginXfb{};
    PFN_vkCmdEndTransformFeedbackEXT endXfb{};
    bool has(const char *name) const {
        return std::any_of(extensions.begin(),extensions.end(),[&](auto &e){return !strcmp(e.extensionName,name);});
    }
    uint32_t memoryType(uint32_t bits,VkMemoryPropertyFlags required) {
        for(uint32_t i=0;i<memory.memoryTypeCount;++i)
            if((bits&(1u<<i)) && (memory.memoryTypes[i].propertyFlags&required)==required) return i;
        throw std::runtime_error("No required memory type");
    }
    Buffer buffer(VkDeviceSize bytes,VkBufferUsageFlags usage) {
        Buffer b; b.size=bytes;
        VkBufferCreateInfo ci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; ci.size=bytes; ci.usage=usage;
        check(vkCreateBuffer(device,&ci,nullptr,&b.handle),"vkCreateBuffer");
        // Retain even partially allocated objects so failure cleanup remains ordered.
        buffers.push_back(b); auto &tracked=buffers.back();
        VkMemoryRequirements req; vkGetBufferMemoryRequirements(device,b.handle,&req);
        VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ai.allocationSize=req.size;
        ai.memoryTypeIndex=memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
        check(vkAllocateMemory(device,&ai,nullptr,&tracked.memory),"vkAllocateMemory buffer");
        check(vkBindBufferMemory(device,b.handle,tracked.memory,0),"vkBindBufferMemory");
        check(vkMapMemory(device,tracked.memory,0,VK_WHOLE_SIZE,0,&tracked.mapped),"vkMapMemory");
        return tracked;
    }
    void flush(Buffer b) {
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory=b.memory; range.size=VK_WHOLE_SIZE;
        check(vkFlushMappedMemoryRanges(device,1,&range),"vkFlushMappedMemoryRanges");
    }
    void invalidate(Buffer b) {
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory=b.memory; range.size=VK_WHOLE_SIZE;
        check(vkInvalidateMappedMemoryRanges(device,1,&range),"vkInvalidateMappedMemoryRanges");
    }
    void initialize() {
        Dl_info owner{};
        if(!dladdr((void*)vkCreateInstance,&owner) || !owner.dli_fname)
            throw std::runtime_error("Cannot verify Vulkan provider ownership");
        log(@"ACTUAL_VULKAN_PROVIDER %s",owner.dli_fname);
        if(!strstr(owner.dli_fname,"/MoltenVK.framework/MoltenVK"))
            throw std::runtime_error("Unexpected Vulkan provider; no substitution allowed");
        uint32_t count=0, loaderVersion=VK_API_VERSION_1_0;
        auto version=(PFN_vkEnumerateInstanceVersion)vkGetInstanceProcAddr(nullptr,"vkEnumerateInstanceVersion");
        if(version) check(version(&loaderVersion),"vkEnumerateInstanceVersion");
        log(@"loaderAPI=%u.%u.%u",VK_VERSION_MAJOR(loaderVersion),VK_VERSION_MINOR(loaderVersion),VK_VERSION_PATCH(loaderVersion));
        check(vkEnumerateInstanceLayerProperties(&count,nullptr),"enumerate instance layers");
        std::vector<VkLayerProperties> layers(count); check(vkEnumerateInstanceLayerProperties(&count,layers.data()),"instance layers");
        for(auto &l:layers) { log(@"LAYER %s version=%u",l.layerName,l.specVersion); if(!strcmp(l.layerName,"VK_LAYER_KHRONOS_validation")) validation=true; }
        log(@"VALIDATION %@; debug-utils driver diagnostics are NOT a substitute",validation?@"KHRONOS_LAYER_ENABLED":@"NOT_AVAILABLE / NOT_TESTED");
        check(vkEnumerateInstanceExtensionProperties(nullptr,&count,nullptr),"enumerate instance extensions");
        std::vector<VkExtensionProperties> ie(count); check(vkEnumerateInstanceExtensionProperties(nullptr,&count,ie.data()),"instance extensions");
        std::vector<const char *> enabled;
        VkInstanceCreateFlags flags=0;
        for(auto &e:ie) {
            log(@"INSTANCE_EXTENSION %s spec=%u",e.extensionName,e.specVersion);
            if(!strcmp(e.extensionName,VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) { enabled.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME); flags|=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR; }
            if(!strcmp(e.extensionName,VK_EXT_DEBUG_UTILS_EXTENSION_NAME)) enabled.push_back(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        }
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.pApplicationName="RemoteGPU isolated Geometry Probe";
        app.apiVersion=std::min(loaderVersion,VK_API_VERSION_1_1);
        VkDebugUtilsMessengerCreateInfoEXT dbg{VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT};
        dbg.messageSeverity=VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        dbg.messageType=VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        dbg.pfnUserCallback=debugCallback;
        VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ci.pApplicationInfo=&app; ci.flags=flags;
        ci.enabledExtensionCount=(uint32_t)enabled.size(); ci.ppEnabledExtensionNames=enabled.data();
        const char *layer="VK_LAYER_KHRONOS_validation";
        if(validation) { ci.enabledLayerCount=1; ci.ppEnabledLayerNames=&layer; }
        bool debug=std::any_of(enabled.begin(),enabled.end(),[](auto n){return !strcmp(n,VK_EXT_DEBUG_UTILS_EXTENSION_NAME);});
        if(debug) ci.pNext=&dbg;
        check(vkCreateInstance(&ci,nullptr,&instance),"vkCreateInstance");
        if(debug) {
            auto create=(PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(instance,"vkCreateDebugUtilsMessengerEXT");
            if(create) check(create(instance,&dbg,nullptr,&messenger),"create debug messenger");
        }
        check(vkEnumeratePhysicalDevices(instance,&count,nullptr),"enumerate physical devices");
        if(count!=1) throw std::runtime_error("Expected exactly one isolated MoltenVK physical device");
        check(vkEnumeratePhysicalDevices(instance,&count,&physical),"physical device");
        vkGetPhysicalDeviceProperties(physical,&properties); vkGetPhysicalDeviceFeatures(physical,&features);
        vkGetPhysicalDeviceMemoryProperties(physical,&memory);
        check(vkEnumerateDeviceExtensionProperties(physical,nullptr,&count,nullptr),"enumerate device extensions");
        extensions.resize(count); check(vkEnumerateDeviceExtensionProperties(physical,nullptr,&count,extensions.data()),"device extensions");
        NSMutableArray *extensionReport=[NSMutableArray array];
        for(auto &e:extensions) [extensionReport addObject:@{@"name":@(e.extensionName),@"specVersion":@(e.specVersion)}];
        VkPhysicalDeviceTransformFeedbackFeaturesEXT tf{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT};
        VkPhysicalDeviceDepthClipEnableFeaturesEXT dc{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT};
        VkPhysicalDeviceFeatures2 f2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
        if(has(VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME)) { tf.pNext=f2.pNext; f2.pNext=&tf; }
        if(has(VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME)) { dc.pNext=f2.pNext; f2.pNext=&dc; }
        vkGetPhysicalDeviceFeatures2(physical,&f2); transformFeedback=tf.transformFeedback; depthClip=dc.depthClipEnable;
        // Core features are dumped completely. Extension features needed by the
        // pinned Zink requirement matrix are queried only when valid to query.
        NSMutableDictionary *extra=[NSMutableDictionary dictionary];
        auto query=[&](void *structure) {
            VkPhysicalDeviceFeatures2 q{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
            q.pNext=structure; vkGetPhysicalDeviceFeatures2(physical,&q);
        };
        if(properties.apiVersion>=VK_API_VERSION_1_2) {
            VkPhysicalDeviceVulkan12Features f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}; query(&f);
            extra[@"vulkan12"]=@{@"scalarBlockLayout":@(f.scalarBlockLayout),@"timelineSemaphore":@(f.timelineSemaphore),
                @"imagelessFramebuffer":@(f.imagelessFramebuffer),@"uniformBufferStandardLayout":@(f.uniformBufferStandardLayout),
                @"hostQueryReset":@(f.hostQueryReset),@"bufferDeviceAddress":@(f.bufferDeviceAddress)};
        }
        if(has("VK_EXT_robustness2")) {
            VkPhysicalDeviceRobustness2FeaturesEXT f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT}; query(&f);
            extra[@"VK_EXT_robustness2"]=@{@"nullDescriptor":@(f.nullDescriptor),@"robustBufferAccess2":@(f.robustBufferAccess2),@"robustImageAccess2":@(f.robustImageAccess2)};
        }
        if(has("VK_EXT_custom_border_color")) {
            VkPhysicalDeviceCustomBorderColorFeaturesEXT f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT}; query(&f);
            extra[@"VK_EXT_custom_border_color"]=@{@"customBorderColors":@(f.customBorderColors),@"customBorderColorWithoutFormat":@(f.customBorderColorWithoutFormat)};
        }
        if(has("VK_EXT_line_rasterization")) {
            VkPhysicalDeviceLineRasterizationFeaturesEXT f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LINE_RASTERIZATION_FEATURES_EXT}; query(&f);
            extra[@"VK_EXT_line_rasterization"]=@{@"rectangularLines":@(f.rectangularLines),@"bresenhamLines":@(f.bresenhamLines),@"smoothLines":@(f.smoothLines),
                @"stippledRectangularLines":@(f.stippledRectangularLines),@"stippledBresenhamLines":@(f.stippledBresenhamLines),@"stippledSmoothLines":@(f.stippledSmoothLines)};
        }
        if(has("VK_EXT_provoking_vertex")) {
            VkPhysicalDeviceProvokingVertexFeaturesEXT f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT}; query(&f);
            extra[@"VK_EXT_provoking_vertex"]=@{@"provokingVertexLast":@(f.provokingVertexLast),@"transformFeedbackPreservesProvokingVertex":@(f.transformFeedbackPreservesProvokingVertex)};
        }
        if(has("VK_EXT_border_color_swizzle")) {
            VkPhysicalDeviceBorderColorSwizzleFeaturesEXT f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BORDER_COLOR_SWIZZLE_FEATURES_EXT}; query(&f);
            extra[@"VK_EXT_border_color_swizzle"]=@{@"borderColorSwizzle":@(f.borderColorSwizzle),@"borderColorSwizzleFromImage":@(f.borderColorSwizzleFromImage)};
        }
        if(has("VK_EXT_conditional_rendering")) {
            VkPhysicalDeviceConditionalRenderingFeaturesEXT f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CONDITIONAL_RENDERING_FEATURES_EXT}; query(&f);
            extra[@"VK_EXT_conditional_rendering"]=@{@"conditionalRendering":@(f.conditionalRendering),@"inheritedConditionalRendering":@(f.inheritedConditionalRendering)};
        }
        if(has("VK_EXT_scalar_block_layout")) {
            VkPhysicalDeviceScalarBlockLayoutFeaturesEXT f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SCALAR_BLOCK_LAYOUT_FEATURES_EXT}; query(&f);
            extra[@"VK_EXT_scalar_block_layout"]=@{@"scalarBlockLayout":@(f.scalarBlockLayout)};
        }
        if(properties.apiVersion>=VK_API_VERSION_1_3 || has("VK_KHR_dynamic_rendering")) {
            VkPhysicalDeviceDynamicRenderingFeatures f{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES}; query(&f);
            extra[@"dynamicRendering"]=@{@"dynamicRendering":@(f.dynamicRendering)};
        }
        VkPhysicalDeviceProperties2 p2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
        if(has(VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME)) { p2.pNext=&xfbLimits; vkGetPhysicalDeviceProperties2(physical,&p2); }
        NSMutableArray *heaps=[NSMutableArray array], *types=[NSMutableArray array];
        for(uint32_t i=0;i<memory.memoryHeapCount;++i) [heaps addObject:@{@"size":@(memory.memoryHeaps[i].size),@"flags":@(memory.memoryHeaps[i].flags)}];
        for(uint32_t i=0;i<memory.memoryTypeCount;++i) [types addObject:@{@"heap":@(memory.memoryTypes[i].heapIndex),@"flags":@(memory.memoryTypes[i].propertyFlags)}];
        NSMutableDictionary *formats=[NSMutableDictionary dictionary];
        for(auto format:{VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_D32_SFLOAT,VK_FORMAT_D32_SFLOAT_S8_UINT,VK_FORMAT_B10G11R11_UFLOAT_PACK32}) {
            VkFormatProperties fp{}; vkGetPhysicalDeviceFormatProperties(physical,format,&fp);
            formats[[@(format) stringValue]]=@{@"linearTilingFeatures":@(fp.linearTilingFeatures),@"optimalTilingFeatures":@(fp.optimalTilingFeatures),@"bufferFeatures":@(fp.bufferFeatures)};
        }
        saveJSON(@"features.json",@{@"apiVersion":@(properties.apiVersion),@"deviceName":@(properties.deviceName),
            @"vendorID":@(properties.vendorID),@"deviceID":@(properties.deviceID),@"driverVersion":@(properties.driverVersion),
            @"coreFeatures":dumpVkPhysicalDeviceFeatures(features),@"limits":dumpVkPhysicalDeviceLimits(properties.limits),
            @"zinkRelevantExtensionFeatures":extra,@"unqueriedExtensionFeatures":@"NOT_TESTED; extension presence alone is not a feature-bit or execution PASS",
            @"extensions":extensionReport,@"memoryHeaps":heaps,@"memoryTypes":types,@"formats":formats,
            @"transformFeedback":@(tf.transformFeedback),@"geometryStreams":@(tf.geometryStreams),
            @"depthClipEnable":@(dc.depthClipEnable),@"maxTransformFeedbackBuffers":@(xfbLimits.maxTransformFeedbackBuffers),
            @"maxTransformFeedbackBufferSize":@(xfbLimits.maxTransformFeedbackBufferSize),
            @"maxTransformFeedbackBufferDataStride":@(xfbLimits.maxTransformFeedbackBufferDataStride),
            @"validationLayerEnabled":@(validation),@"evidenceClass":@"DECLARATIONS_ONLY; per-case execution logged separately"});
        vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,nullptr);
        std::vector<VkQueueFamilyProperties> queues(count); vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,queues.data());
        bool found=false;
        for(uint32_t i=0;i<count;++i) {
            log(@"QUEUE family=%u flags=0x%x count=%u timestampValidBits=%u",i,queues[i].queueFlags,queues[i].queueCount,queues[i].timestampValidBits);
            if(!found && (queues[i].queueFlags&VK_QUEUE_GRAPHICS_BIT)) { family=i; found=true; }
        }
        if(!found) throw std::runtime_error("No graphics queue");
        float priority=1;
        VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
        std::vector<const char*> de;
        if(has("VK_KHR_portability_subset")) de.push_back("VK_KHR_portability_subset");
        if(transformFeedback) de.push_back(VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME);
        VkPhysicalDeviceFeatures requested{}; requested.geometryShader=features.geometryShader;
        requested.shaderTessellationAndGeometryPointSize=features.shaderTessellationAndGeometryPointSize;
        VkPhysicalDeviceTransformFeedbackFeaturesEXT requestedTF{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT};
        requestedTF.transformFeedback=transformFeedback; // geometryStreams deliberately NOT enabled/tested
        VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi;
        di.pEnabledFeatures=&requested; di.enabledExtensionCount=(uint32_t)de.size(); di.ppEnabledExtensionNames=de.data();
        if(transformFeedback) di.pNext=&requestedTF;
        check(vkCreateDevice(physical,&di,nullptr,&device),"vkCreateDevice"); vkGetDeviceQueue(device,family,0,&queue);
        bindXfb=(PFN_vkCmdBindTransformFeedbackBuffersEXT)vkGetDeviceProcAddr(device,"vkCmdBindTransformFeedbackBuffersEXT");
        beginXfb=(PFN_vkCmdBeginTransformFeedbackEXT)vkGetDeviceProcAddr(device,"vkCmdBeginTransformFeedbackEXT");
        endXfb=(PFN_vkCmdEndTransformFeedbackEXT)vkGetDeviceProcAddr(device,"vkCmdEndTransformFeedbackEXT");
    }
    void resources() {
        vertex=buffer(sizeof(Vertex)*6,VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        uniform=buffer(sizeof(Parameters),VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        readback=buffer(W*H*4,VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        indirect=buffer(sizeof(VkDrawIndexedIndirectCommand),VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
        index=buffer(6*sizeof(uint16_t),VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        uint16_t indices[]={0,1,2,3,4,5}; memcpy(index.mapped,indices,sizeof(indices)); flush(index);
        if(transformFeedback && xfbLimits.maxTransformFeedbackBufferSize>=1024)
            xfb=buffer(1024,VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT);
        VkImageCreateInfo im{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; im.imageType=VK_IMAGE_TYPE_2D; im.format=VK_FORMAT_R8G8B8A8_UNORM;
        im.extent={W,H,1}; im.mipLevels=im.arrayLayers=1; im.samples=VK_SAMPLE_COUNT_1_BIT;
        im.tiling=VK_IMAGE_TILING_OPTIMAL; im.usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        check(vkCreateImage(device,&im,nullptr,&image),"vkCreateImage");
        VkMemoryRequirements req; vkGetImageMemoryRequirements(device,image,&req);
        VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ai.allocationSize=req.size;
        ai.memoryTypeIndex=memoryType(req.memoryTypeBits,0); check(vkAllocateMemory(device,&ai,nullptr,&imageMemory),"image memory");
        check(vkBindImageMemory(device,image,imageMemory,0),"bind image");
        VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO}; vi.image=image; vi.viewType=VK_IMAGE_VIEW_TYPE_2D; vi.format=im.format;
        vi.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}; check(vkCreateImageView(device,&vi,nullptr,&view),"image view");
        VkAttachmentDescription attachment{}; attachment.format=im.format; attachment.samples=VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp=VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        VkAttachmentReference reference{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription sub{}; sub.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS; sub.colorAttachmentCount=1; sub.pColorAttachments=&reference;
        VkSubpassDependency deps[2]{};
        deps[0].srcSubpass=VK_SUBPASS_EXTERNAL; deps[0].dstSubpass=0; deps[0].srcStageMask=VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        deps[0].dstStageMask=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT; deps[0].dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        deps[1].srcSubpass=0; deps[1].dstSubpass=VK_SUBPASS_EXTERNAL; deps[1].srcStageMask=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[1].dstStageMask=VK_PIPELINE_STAGE_TRANSFER_BIT; deps[1].srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; deps[1].dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        VkRenderPassCreateInfo ri{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO}; ri.attachmentCount=1; ri.pAttachments=&attachment;
        ri.subpassCount=1; ri.pSubpasses=&sub; ri.dependencyCount=2; ri.pDependencies=deps;
        check(vkCreateRenderPass(device,&ri,nullptr,&renderPass),"render pass");
        VkFramebufferCreateInfo fi{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO}; fi.renderPass=renderPass; fi.attachmentCount=1; fi.pAttachments=&view;
        fi.width=W; fi.height=H; fi.layers=1; check(vkCreateFramebuffer(device,&fi,nullptr,&framebuffer),"framebuffer");
        VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT; pi.queueFamilyIndex=family;
        check(vkCreateCommandPool(device,&pi,nullptr,&pool),"command pool");
        VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; ca.commandPool=pool; ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount=1;
        check(vkAllocateCommandBuffers(device,&ca,&command),"command buffer");
        VkFenceCreateInfo fc{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; check(vkCreateFence(device,&fc,nullptr,&fence),"fence");
        VkDescriptorSetLayoutBinding binding{0,VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,1,VK_SHADER_STAGE_ALL_GRAPHICS,nullptr};
        VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO}; li.bindingCount=1; li.pBindings=&binding;
        check(vkCreateDescriptorSetLayout(device,&li,nullptr,&setLayout),"descriptor layout");
        VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; pl.setLayoutCount=1; pl.pSetLayouts=&setLayout;
        check(vkCreatePipelineLayout(device,&pl,nullptr,&layout),"pipeline layout");
        VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,1};
        VkDescriptorPoolCreateInfo dp{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; dp.maxSets=1; dp.poolSizeCount=1; dp.pPoolSizes=&size;
        check(vkCreateDescriptorPool(device,&dp,nullptr,&descriptorPool),"descriptor pool");
        VkDescriptorSetAllocateInfo ds{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; ds.descriptorPool=descriptorPool; ds.descriptorSetCount=1; ds.pSetLayouts=&setLayout;
        check(vkAllocateDescriptorSets(device,&ds,&descriptor),"descriptor set");
        VkDescriptorBufferInfo bi{uniform.handle,0,sizeof(Parameters)};
        VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET}; write.dstSet=descriptor; write.descriptorCount=1;
        write.descriptorType=VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; write.pBufferInfo=&bi; vkUpdateDescriptorSets(device,1,&write,0,nullptr);
    }
    VkShaderModule shader(NSString *name) {
        NSURL *url=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:[@"Shaders/" stringByAppendingString:name]];
        NSData *data=[NSData dataWithContentsOfURL:url];
        if(!data || data.length%4) throw std::runtime_error("Missing or invalid bundled SPIR-V");
        log(@"SHADER %@ bytes=%lu",name,(unsigned long)data.length);
        std::vector<uint32_t> code(data.length/4); memcpy(code.data(),data.bytes,data.length);
        VkShaderModuleCreateInfo si{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; si.codeSize=data.length; si.pCode=code.data();
        VkShaderModule module{}; check(vkCreateShaderModule(device,&si,nullptr,&module),"shader module"); modules.push_back(module); return module;
    }
    void releasePipeline() {
        if(pipeline) vkDestroyPipeline(device,pipeline,nullptr); pipeline={};
        for(auto m:modules) vkDestroyShaderModule(device,m,nullptr); modules.clear();
    }
    void createPipeline(const Case &c) {
        releasePipeline();
        std::vector<VkPipelineShaderStageCreateInfo> stages;
        auto add=[&](VkShaderStageFlagBits stage,NSString *name){
            VkPipelineShaderStageCreateInfo s{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
            s.stage=stage; s.module=shader(name); s.pName="main"; stages.push_back(s);
        };
        add(VK_SHADER_STAGE_VERTEX_BIT,@"input.vert.spv");
        if(c.shader) add(VK_SHADER_STAGE_GEOMETRY_BIT,[@(c.shader) stringByAppendingString:@".geom.spv"]);
        add(VK_SHADER_STAGE_FRAGMENT_BIT,@"output.frag.spv");
        VkVertexInputBindingDescription binding{0,sizeof(Vertex),VK_VERTEX_INPUT_RATE_VERTEX};
        VkVertexInputAttributeDescription attrs[]={{0,0,VK_FORMAT_R32G32_SFLOAT,0},{1,0,VK_FORMAT_R32G32B32A32_SFLOAT,8}};
        VkPipelineVertexInputStateCreateInfo vertexState{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        vertexState.vertexBindingDescriptionCount=1; vertexState.pVertexBindingDescriptions=&binding;
        vertexState.vertexAttributeDescriptionCount=2; vertexState.pVertexAttributeDescriptions=attrs;
        VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; assembly.topology=c.topology;
        VkViewport viewport{0,0,float(W),float(H),0,1}; VkRect2D scissor{{0,0},{W,H}};
        VkPipelineViewportStateCreateInfo vp{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO}; vp.viewportCount=vp.scissorCount=1; vp.pViewports=&viewport; vp.pScissors=&scissor;
        VkPipelineRasterizationStateCreateInfo rs{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        rs.polygonMode=VK_POLYGON_MODE_FILL; rs.cullMode=VK_CULL_MODE_NONE; rs.frontFace=VK_FRONT_FACE_COUNTER_CLOCKWISE; rs.lineWidth=1;
        VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; ms.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState color{}; color.colorWriteMask=15;
        VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; blend.attachmentCount=1; blend.pAttachments=&color;
        VkGraphicsPipelineCreateInfo ci{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO}; ci.stageCount=(uint32_t)stages.size(); ci.pStages=stages.data();
        ci.pVertexInputState=&vertexState; ci.pInputAssemblyState=&assembly; ci.pViewportState=&vp; ci.pRasterizationState=&rs;
        ci.pMultisampleState=&ms; ci.pColorBlendState=&blend; ci.layout=layout; ci.renderPass=renderPass;
        log(@"PIPELINE case=%s actualStages=%s",c.name,c.shader?"VERTEX+GEOMETRY+FRAGMENT":"VERTEX+FRAGMENT_CONTROL_ONLY");
        check(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&ci,nullptr,&pipeline),"vkCreateGraphicsPipelines (NOT execution acceptance)");
    }
    Pixels draw(const Case &c,int revision) {
        std::array<Vertex,6> data{};
        for(auto &v:data) v={-.875f,-.75f,1,0,0,1};
        if(!c.shader) { data[0].x=-1;data[0].y=-1;data[1].x=3;data[1].y=-1;data[2].x=-1;data[2].y=3; }
        if(c.kind==1 || c.kind==2) for(auto &v:data) { v.x=-.65625f; v.y=-.65625f; }
        if(c.kind==3) for(int i=3;i<6;++i) data[i].y=.125f;
        if(revision) for(auto &v:data) { v.x+=c.shader?.125f:0; v.r=0;v.g=1; }
        memcpy(vertex.mapped,data.data(),sizeof(data)); flush(vertex);
        Parameters params{{0,revision?.125f:0,0,0},{1,1,1,1}};
        if(revision==2) { params.offset[0]=.125f; params.tint[1]=.5f; }
        memcpy(uniform.mapped,&params,sizeof(params)); flush(uniform);
        memset(readback.mapped,0xcd,(size_t)readback.size); flush(readback);
        if(c.capture) { memset(xfb.mapped,0xcd,(size_t)xfb.size); flush(xfb); }
        if(c.indirect) {
            if(c.indexed) { VkDrawIndexedIndirectCommand args{c.vertices,1,0,0,0}; memcpy(indirect.mapped,&args,sizeof(args)); }
            else { VkDrawIndirectCommand args{c.vertices,1,0,0}; memcpy(indirect.mapped,&args,sizeof(args)); }
            flush(indirect);
        }
        check(vkResetCommandBuffer(command,0),"reset retired command buffer");
        VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vkBeginCommandBuffer(command,&bi),"begin command buffer");
        VkClearValue clear{}; clear.color.float32[3]=1;
        VkRenderPassBeginInfo rp{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO}; rp.renderPass=renderPass; rp.framebuffer=framebuffer;
        rp.renderArea.extent={W,H}; rp.clearValueCount=1; rp.pClearValues=&clear;
        vkCmdBeginRenderPass(command,&rp,VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);
        VkDeviceSize offset=0; vkCmdBindVertexBuffers(command,0,1,&vertex.handle,&offset);
        vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_GRAPHICS,layout,0,1,&descriptor,0,nullptr);
        if(c.capture) { VkDeviceSize size=xfb.size; bindXfb(command,0,1,&xfb.handle,&offset,&size); beginXfb(command,0,0,nullptr,nullptr); }
        if(c.indirect && c.indexed) { vkCmdBindIndexBuffer(command,index.handle,0,VK_INDEX_TYPE_UINT16); vkCmdDrawIndexedIndirect(command,indirect.handle,0,1,sizeof(VkDrawIndexedIndirectCommand)); }
        else if(c.indirect) vkCmdDrawIndirect(command,indirect.handle,0,1,sizeof(VkDrawIndirectCommand));
        else vkCmdDraw(command,c.vertices,1,0,0);
        if(c.capture) endXfb(command,0,0,nullptr,nullptr);
        vkCmdEndRenderPass(command);
        VkBufferImageCopy copy{}; copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; copy.imageExtent={W,H,1};
        vkCmdCopyImageToBuffer(command,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,readback.handle,1,&copy);
        VkBufferMemoryBarrier barrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER}; barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; barrier.buffer=readback.handle; barrier.size=VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&barrier,0,nullptr);
        if(c.capture) {
            barrier.srcAccessMask=VK_ACCESS_TRANSFORM_FEEDBACK_WRITE_BIT_EXT; barrier.buffer=xfb.handle;
            vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFORM_FEEDBACK_BIT_EXT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&barrier,0,nullptr);
        }
        check(vkEndCommandBuffer(command),"end command buffer"); check(vkResetFences(device,1,&fence),"reset completed fence");
        VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO}; si.commandBufferCount=1; si.pCommandBuffers=&command;
        check(vkQueueSubmit(queue,1,&si,fence),"queue submit"); safeToDestroy=false;
        VkResult first=vkGetFenceStatus(device,fence); log(@"FENCE first=%d (NOT_READY or SUCCESS valid; no timing verdict)",first);
        if(first!=VK_NOT_READY && first!=VK_SUCCESS) check(first,"initial fence status");
        check(vkWaitForFences(device,1,&fence,VK_TRUE,5'000'000'000ULL),"bounded per-submission fence; no deviceWaitIdle");
        safeToDestroy=true; check(vkGetFenceStatus(device,fence),"completed fence before map/read/reuse/free");
        invalidate(readback); Pixels pixels; memcpy(pixels.data(),readback.mapped,sizeof(pixels));
        if(c.capture) {
            invalidate(xfb);
            NSData *bytes=[NSData dataWithBytes:xfb.mapped length:(NSUInteger)xfb.size];
            [bytes writeToURL:[RGPUGeometryReportDirectory() URLByAppendingPathComponent:[NSString stringWithFormat:@"%s-%d-xfb.bin",c.name,revision]] atomically:YES];
            // Exact stream ordering/values must match the emitted eight records.
            auto f=(const float*)xfb.mapped; unsigned mismatches=0;
            for(int j=0;j<2;++j) for(int i=0;i<4;++i) {
                float expected[]={data[0].x+params.offset[0]+j*.875f+(i%2)*.5f,
                    data[0].y+params.offset[1]+(i/2)*.5f,0,1,
                    data[0].r*params.tint[0],data[0].g*params.tint[1],0,1};
                for(int k=0;k<8;++k) if(!std::isfinite(f[(j*4+i)*8+k]) || std::abs(f[(j*4+i)*8+k]-expected[k])>1e-6f) ++mismatches;
            }
            log(@"XFB case=%s revision=%d expectedRecords=8 checkedFloats=64 mismatch=%u (remaining allocation retained in bin)",c.name,revision,mismatches);
            if(mismatches) throw std::runtime_error("Geometry transform feedback output mismatch");
        }
        return pixels;
    }
    ~Engine() {
        if(!safeToDestroy) { log(@"CLEANUP RETAINED: fence not confirmed; no freeing in-flight resources. Relaunch process."); return; }
        if(device) {
            releasePipeline();
            if(descriptorPool) vkDestroyDescriptorPool(device,descriptorPool,nullptr);
            if(layout) vkDestroyPipelineLayout(device,layout,nullptr);
            if(setLayout) vkDestroyDescriptorSetLayout(device,setLayout,nullptr);
            if(fence) vkDestroyFence(device,fence,nullptr);
            if(pool) vkDestroyCommandPool(device,pool,nullptr);
            if(framebuffer) vkDestroyFramebuffer(device,framebuffer,nullptr);
            if(renderPass) vkDestroyRenderPass(device,renderPass,nullptr);
            if(view) vkDestroyImageView(device,view,nullptr);
            if(image) vkDestroyImage(device,image,nullptr);
            if(imageMemory) vkFreeMemory(device,imageMemory,nullptr);
            for(auto &b:buffers) {
                if(b.mapped) vkUnmapMemory(device,b.memory);
                if(b.handle) vkDestroyBuffer(device,b.handle,nullptr);
                if(b.memory) vkFreeMemory(device,b.memory,nullptr);
            }
            vkDestroyDevice(device,nullptr); log(@"CLEANUP device resources released after observed fences; driver leak profiling NOT_TESTED");
        }
        if(messenger) {
            auto destroy=(PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(instance,"vkDestroyDebugUtilsMessengerEXT");
            if(destroy) destroy(instance,messenger,nullptr);
        }
        if(instance) vkDestroyInstance(instance,nullptr);
    }
};

Pixels expected(const Case &c,int revision) {
    Pixels result; result.fill({0,0,0,255});
    if(!c.shader) { result.fill(revision?Color{0,255,0,255}:Color{255,0,0,255}); return result; }
    float ox=-.875f+(revision?.125f:0)+(revision==2?.125f:0), oy=-.75f+(revision?.125f:0);
    if(c.kind==1 || c.kind==2) { ox=-.65625f+(revision?.125f:0)+(revision==2?.125f:0); oy=-.65625f+(revision?.125f:0); }
    Color base=revision?Color{0,uint8_t(revision==2?128:255),0,255}:Color{255,0,0,255};
    for(uint32_t y=0;y<H;++y) for(uint32_t x=0;x<W;++x) {
        float px=(x+.5f)/16-1, py=(y+.5f)/16-1;
        for(int j=0;j<2;++j) {
            float left=ox+(c.kind==3?0:j*.875f), top=oy+(c.kind==3?j*.875f:0);
            bool covered=px>=left && px<left+.5f && py>=top && py<top+.5f;
            if(c.kind==1) covered=px>=left && px<left+.5f && std::abs(py-top)<.02f;
            if(c.kind==2) covered=std::abs(px-left)<.02f && std::abs(py-top)<.02f;
            if(!covered) continue;
            Color color=base;
            if((c.kind==3 || c.kind==4) && j) std::swap(color[0],color[2]);
            if(c.kind==5) color={uint8_t(std::lround((px-left)*510)),uint8_t(std::lround((py-top)*510)),128,255};
            result[y*W+x]=color;
        }
    }
    return result;
}
void saveImage(const Pixels &pixels,NSString *name) {
    NSData *data=[NSData dataWithBytes:pixels.data() length:sizeof(pixels)];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(W,H,8,32,W*4,space,kCGBitmapByteOrderDefault|kCGImageAlphaLast,provider,nullptr,false,kCGRenderingIntentDefault);
    NSData *png=UIImagePNGRepresentation([UIImage imageWithCGImage:image]);
    if(!png || ![png writeToURL:[RGPUGeometryReportDirectory() URLByAppendingPathComponent:name] atomically:YES])
        throw std::runtime_error("Cannot retain actual/oracle image");
    CGImageRelease(image); CGColorSpaceRelease(space); CGDataProviderRelease(provider);
}
bool compare(const Case &c,int revision,const Pixels &actual) {
    auto oracle=expected(c,revision); unsigned mismatch=0, nonClear=0;
    for(size_t i=0;i<actual.size();++i) {
        bool equal=true;
        for(int channel=0;channel<4;++channel) if(std::abs(int(actual[i][channel])-int(oracle[i][channel]))>(channel==3?0:1)) equal=false;
        if(!equal) { if(mismatch<8) log(@"MISMATCH x=%lu y=%lu actual=%u,%u,%u,%u expected=%u,%u,%u,%u",i%W,i/W,actual[i][0],actual[i][1],actual[i][2],actual[i][3],oracle[i][0],oracle[i][1],oracle[i][2],oracle[i][3]); ++mismatch; }
        if(actual[i]!=Color{0,0,0,255}) ++nonClear;
    }
    NSString *stem=[NSString stringWithFormat:@"%s-%d",c.name,revision];
    saveImage(actual,[stem stringByAppendingString:@"-actual.png"]); saveImage(oracle,[stem stringByAppendingString:@"-expected.png"]);
    log(@"PIXELS %@ checked=%u matched=%u mismatch=%u nonClear=%u RGB_tolerance=1 alpha=exact",stem,W*H,W*H-mismatch,mismatch,nonClear);
    for(uint32_t y=0;y<H;++y) {
        NSMutableString *row=[NSMutableString stringWithFormat:@"RGBA %@ y=%u ",stem,y];
        for(uint32_t x=0;x<W;++x) { auto p=actual[y*W+x]; [row appendFormat:@"%02x%02x%02x%02x ",p[0],p[1],p[2],p[3]]; } log(@"%@",row);
    }
    return !mismatch;
}
bool legal(const Engine &e,const Case &c) {
    const auto &l=e.properties.limits;
    bool allowed=e.features.geometryShader && l.maxGeometryShaderInvocations>=c.invocations &&
        l.maxGeometryInputComponents>=4 && l.maxGeometryOutputComponents>=(c.capture?16u:c.kind==2?9u:8u) &&
        l.maxGeometryOutputVertices>=c.outputVertices && l.maxGeometryTotalOutputComponents>=c.outputVertices*(c.capture?16u:c.kind==2?9u:8u);
    if(c.kind==2) allowed=allowed && e.features.shaderTessellationAndGeometryPointSize;
    return allowed;
}
}

NSURL *RGPUGeometryReportDirectory(void) {
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder=[documents URLByAppendingPathComponent:@"GeometryReport" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil]; return folder;
}
NSString *RGPURunGeometryProbe(void) {
    @autoreleasepool {
        NSURL *file=[RGPUGeometryReportDirectory() URLByAppendingPathComponent:@"report.txt"];
        [NSData.data writeToURL:file atomically:YES]; journal=[NSFileHandle fileHandleForWritingToURL:file error:nil];
        if(!journal) return @"Cannot create persistent report; no GPU tests run.";
        validationErrors=0; driverErrors=0;
        log(@"ISOLATED UTM MOLTENVK GEOMETRY PROBE v1\nDevice acceptance initially PENDING. No GL/Zink/VirGL/guest verdict.\nDiagnostic GPU->CPU readback ONLY. No global deviceWaitIdle, capability overrides or backend substitution.");
        struct utsname hardware{}; uname(&hardware);
        log(@"Device=%s OS=%@",hardware.machine,NSProcessInfo.processInfo.operatingSystemVersionString);
        NSData *provenance=[NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"Provenance" withExtension:@"json"]];
        if(provenance) {
            [provenance writeToURL:[RGPUGeometryReportDirectory() URLByAppendingPathComponent:@"Provenance.json"] atomically:YES];
            log(@"PROVENANCE %@",[[NSString alloc] initWithData:provenance encoding:NSUTF8StringEncoding]);
        }
        try {
            Engine e; e.initialize(); e.resources();
            Case control{"C0_VULKAN_CONTROL",nullptr,VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,3};
            e.createPipeline(control);
            bool controlOK=true;
            for(int r=0;r<2;++r) controlOK=compare(control,r,e.draw(control,r)) && controlOK;
            controlOK=controlOK && validationErrors==0 && driverErrors==0;
            log(@"CASE C0_VULKAN_CONTROL %@; never counts as Geometry execution",controlOK?@"PASS_DEVICE_EXECUTED":@"BLOCKED");
            if(!controlOK) throw std::runtime_error("Basic Vulkan output control failed; Geometry not attempted");
            std::vector<Case> cases={
                {"G1_TRIANGLE_AMPLIFICATION","triangles",VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,3},
                {"G2_LINES_TO_STRIPS","lines",VK_PRIMITIVE_TOPOLOGY_LINE_LIST,2},
                {"G2_POINTS_TO_STRIPS","points",VK_PRIMITIVE_TOPOLOGY_POINT_LIST,1},
                {"G2_LINE_STRIP_OUTPUT","line_output",VK_PRIMITIVE_TOPOLOGY_POINT_LIST,1,4,1,false,false,false,1},
                {"G2_POINT_OUTPUT","point_output",VK_PRIMITIVE_TOPOLOGY_POINT_LIST,1,2,1,false,false,false,2},
                {"G3_PRIMITIVE_ID","primitive_id",VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,6,4,1,false,false,false,3},
                {"G3_INVOCATIONS_2","invocations",VK_PRIMITIVE_TOPOLOGY_POINT_LIST,1,4,2,false,false,false,4},
                {"G3_INTERPOLATED_VARYING","gradient",VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,3,8,1,false,false,false,5},
                {"X1_GEOMETRY_TRANSFORM_FEEDBACK","capture",VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,3,8,1,false,false,true},
                {"I1_GEOMETRY_INDIRECT","triangles",VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,3,8,1,true},
                {"I2_GEOMETRY_INDEXED_INDIRECT","triangles",VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,3,8,1,true,true},
            };
            unsigned pass=0, blocked=0;
            for(auto &c:cases) {
                log(@"BEGIN_CASE %s",c.name);
                if(!legal(e,c)) {
                    log(@"CASE %s BLOCKED reason=reported_geometry_feature_or_limits_do_not_permit_shader; pipeline/submit/readback NOT_RUN; values never overridden",c.name); ++blocked; continue;
                }
                if(c.capture && (!e.transformFeedback || !e.xfb.handle || !e.bindXfb || !e.beginXfb || !e.endXfb || e.xfbLimits.maxTransformFeedbackBufferDataStride<32)) {
                    log(@"CASE %s UNSUPPORTED reason=transform_feedback_feature_limit_or_entry_missing; NOT_RUN",c.name); ++blocked; continue;
                }
                try {
                    unsigned validationBefore=validationErrors.load(), driverBefore=driverErrors.load();
                    e.createPipeline(c); bool ok=true;
                    // G4/G5: three updates on one pipeline/allocation, confirmed fence before reuse.
                    // Diagnostic serialized submissions, NOT overlapping throughput/cancellation testing.
                    for(int r=0;r<3;++r) ok=compare(c,r,e.draw(c,r)) && ok;
                    ok=ok && validationErrors==validationBefore && driverErrors==driverBefore;
                    log(@"CASE %s %@ G4_updates=3 G5_fenced_reuse=3; no performance/full-lifecycle claim",c.name,ok?@"PASS_DEVICE_EXECUTED":@"BLOCKED");
                    if(ok) ++pass; else ++blocked;
                } catch(const std::exception &error) {
                    log(@"CASE %s BLOCKED error=%s; later unexecuted steps NOT_RUN",c.name,error.what()); ++blocked;
                    if(!e.safeToDestroy) throw;
                }
            }
            log(@"SUMMARY geometry_cases_pass=%u blocked_or_unsupported=%u validation=%@ validation_errors=%u driver_errors=%u",pass,blocked,e.validation?@"ENABLED":@"NOT_AVAILABLE_NOT_TESTED",validationErrors.load(),driverErrors.load());
            log(@"G4/G5 apply ONLY to actually executed cases; blocked cases do not establish update/sync/lifecycle success.\nXFB non-geometry baseline/streams/counters and full limits: NOT_TESTED.\nDECISION: no automatic GO; device report and GL/VirGL integration review required. Zink/GL3.2/guest/Minecraft NOT_TESTED.");
        } catch(const std::exception &error) { log(@"PROBE BLOCKED error=%s. Unexecuted cases NOT_RUN. Share partial report.",error.what()); }
        log(@"END_REPORT"); [journal closeFile]; journal=nil;
        return [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil]?:@"Read report.txt in Files.";
    }
}
