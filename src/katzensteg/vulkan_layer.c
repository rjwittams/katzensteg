#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define KS_LAYER_NAME "VK_LAYER_KATZENSTEG_capture"
#define KS_MAX_INSTANCES 8
#define KS_MAX_PHYSICAL_DEVICES 32
#define KS_MAX_DEVICES 16
#define KS_MAX_QUEUES 64
#define KS_MAX_SWAPCHAINS 64
#define KS_MAX_SWAPCHAIN_IMAGES 16
#define KS_MAX_PRESENT_WAITS 16

typedef void (*ks_present_external_framebuffer_fn)(int32_t width, int32_t height, int32_t format, const uint8_t *pixels, size_t len);

enum {
    KS_EXTERNAL_FRAMEBUFFER_RGBA8 = 0,
    KS_EXTERNAL_FRAMEBUFFER_BGRA8 = 1,
    KS_EXTERNAL_FRAMEBUFFER_A2B10G10R10_UNORM_PACK32 = 2,
};

typedef struct InstanceRecord {
    VkInstance instance;
    PFN_vkGetInstanceProcAddr gip;
    PFN_vkDestroyInstance DestroyInstance;
    PFN_vkEnumeratePhysicalDevices EnumeratePhysicalDevices;
    PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties;
} InstanceRecord;

typedef struct PhysicalDeviceRecord {
    VkPhysicalDevice physical;
    VkInstance instance;
} PhysicalDeviceRecord;

typedef struct DeviceRecord {
    VkDevice device;
    VkPhysicalDevice physical;
    PFN_vkGetDeviceProcAddr gdp;
    VkPhysicalDeviceMemoryProperties memory_properties;

    PFN_vkDestroyDevice DestroyDevice;
    PFN_vkGetDeviceQueue GetDeviceQueue;
    PFN_vkGetDeviceQueue2 GetDeviceQueue2;
    PFN_vkCreateSwapchainKHR CreateSwapchainKHR;
    PFN_vkDestroySwapchainKHR DestroySwapchainKHR;
    PFN_vkGetSwapchainImagesKHR GetSwapchainImagesKHR;
    PFN_vkQueuePresentKHR QueuePresentKHR;
    PFN_vkCreateBuffer CreateBuffer;
    PFN_vkDestroyBuffer DestroyBuffer;
    PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
    PFN_vkAllocateMemory AllocateMemory;
    PFN_vkFreeMemory FreeMemory;
    PFN_vkBindBufferMemory BindBufferMemory;
    PFN_vkMapMemory MapMemory;
    PFN_vkUnmapMemory UnmapMemory;
    PFN_vkInvalidateMappedMemoryRanges InvalidateMappedMemoryRanges;
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkDestroyCommandPool DestroyCommandPool;
    PFN_vkResetCommandPool ResetCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdCopyImageToBuffer CmdCopyImageToBuffer;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkCreateFence CreateFence;
    PFN_vkDestroyFence DestroyFence;
    PFN_vkResetFences ResetFences;
    PFN_vkWaitForFences WaitForFences;
} DeviceRecord;

typedef struct QueueRecord {
    VkQueue queue;
    VkDevice device;
    uint32_t family;
} QueueRecord;

typedef struct CaptureResources {
    VkCommandPool command_pool;
    VkCommandBuffer command_buffer;
    VkFence fence;
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize byte_len;
    bool coherent;
} CaptureResources;

typedef struct SwapchainRecord {
    VkSwapchainKHR swapchain;
    VkDevice device;
    VkFormat format;
    VkExtent2D extent;
    bool transfer_src;
    uint32_t image_count;
    VkImage images[KS_MAX_SWAPCHAIN_IMAGES];
    CaptureResources capture;
    bool logged_unsupported_format;
    bool logged_no_transfer_src;
    bool logged_missing_images;
    bool logged_capture_error;
    bool logged_capture_success;
} SwapchainRecord;

static bool g_logged_present_missing_real;
static bool g_logged_present_missing_queue;
static bool g_logged_present_missing_device;
static bool g_logged_present_missing_swapchain;
static bool g_logged_present_unsupported_shape;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static InstanceRecord g_instances[KS_MAX_INSTANCES];
static PhysicalDeviceRecord g_physical_devices[KS_MAX_PHYSICAL_DEVICES];
static DeviceRecord g_devices[KS_MAX_DEVICES];
static QueueRecord g_queues[KS_MAX_QUEUES];
static SwapchainRecord g_swapchains[KS_MAX_SWAPCHAINS];
static ks_present_external_framebuffer_fn g_present_external_framebuffer;
static bool g_capture_enabled;
static bool g_trace_enabled;

extern void ks_scrub_colon_env_entry(const char *name, const char *entry);

static PFN_vkVoidFunction VKAPI_CALL ks_vkGetInstanceProcAddr(VkInstance instance, const char *name);
static PFN_vkVoidFunction VKAPI_CALL ks_vkGetDeviceProcAddr(VkDevice device, const char *name);
static VkResult VKAPI_CALL ks_vkCreateInstance(const VkInstanceCreateInfo *create_info, const VkAllocationCallbacks *allocator, VkInstance *instance);
static void VKAPI_CALL ks_vkDestroyInstance(VkInstance instance, const VkAllocationCallbacks *allocator);
static VkResult VKAPI_CALL ks_vkEnumeratePhysicalDevices(VkInstance instance, uint32_t *count, VkPhysicalDevice *physical_devices);
static VkResult VKAPI_CALL ks_vkCreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo *create_info, const VkAllocationCallbacks *allocator, VkDevice *device);
static void VKAPI_CALL ks_vkDestroyDevice(VkDevice device, const VkAllocationCallbacks *allocator);
static void VKAPI_CALL ks_vkGetDeviceQueue(VkDevice device, uint32_t queue_family, uint32_t queue_index, VkQueue *queue);
static void VKAPI_CALL ks_vkGetDeviceQueue2(VkDevice device, const VkDeviceQueueInfo2 *queue_info, VkQueue *queue);
static VkResult VKAPI_CALL ks_vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *create_info, const VkAllocationCallbacks *allocator, VkSwapchainKHR *swapchain);
static void VKAPI_CALL ks_vkDestroySwapchainKHR(VkDevice device, VkSwapchainKHR swapchain, const VkAllocationCallbacks *allocator);
static VkResult VKAPI_CALL ks_vkGetSwapchainImagesKHR(VkDevice device, VkSwapchainKHR swapchain, uint32_t *count, VkImage *images);
static VkResult VKAPI_CALL ks_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *present_info);

static bool env_enabled(const char *name)
{
    const char *value = getenv(name);
    if (!value || !*value) return false;
    return strcmp(value, "0") != 0 && strcasecmp(value, "false") != 0 && strcasecmp(value, "no") != 0 && strcasecmp(value, "off") != 0;
}

static bool capture_enabled(void)
{
    return g_capture_enabled;
}

static bool trace_enabled(void)
{
    return g_trace_enabled;
}

__attribute__((constructor))
static void katzensteg_vulkan_layer_constructor(void)
{
    g_capture_enabled = env_enabled("KATZENSTEG_VULKAN_CAPTURE");
    g_trace_enabled = env_enabled("KATZENSTEG_TRACE_VULKAN");
    ks_scrub_colon_env_entry("VK_INSTANCE_LAYERS", KS_LAYER_NAME);
    unsetenv("KATZENSTEG_VULKAN_CAPTURE");
    unsetenv("KATZENSTEG_TRACE_VULKAN");
}

static void tracef(const char *fmt, ...)
{
    if (!trace_enabled()) return;
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "katzensteg-vulkan: ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

static ks_present_external_framebuffer_fn present_fn(void)
{
    if (!g_present_external_framebuffer)
        g_present_external_framebuffer = (ks_present_external_framebuffer_fn)dlsym(RTLD_DEFAULT, "ks_katzensteg_present_external_framebuffer");
    return g_present_external_framebuffer;
}

static VkLayerInstanceCreateInfo *instance_link_info(const VkInstanceCreateInfo *create_info)
{
    for (const VkBaseInStructure *chain = (const VkBaseInStructure *)create_info->pNext; chain; chain = chain->pNext) {
        if (chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO) {
            VkLayerInstanceCreateInfo *info = (VkLayerInstanceCreateInfo *)chain;
            if (info->function == VK_LAYER_LINK_INFO) return info;
        }
    }
    return NULL;
}

static VkLayerDeviceCreateInfo *device_link_info(const VkDeviceCreateInfo *create_info)
{
    for (const VkBaseInStructure *chain = (const VkBaseInStructure *)create_info->pNext; chain; chain = chain->pNext) {
        if (chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO) {
            VkLayerDeviceCreateInfo *info = (VkLayerDeviceCreateInfo *)chain;
            if (info->function == VK_LAYER_LINK_INFO) return info;
        }
    }
    return NULL;
}

static InstanceRecord *find_instance(VkInstance instance)
{
    for (size_t i = 0; i < KS_MAX_INSTANCES; i++)
        if (g_instances[i].instance == instance) return &g_instances[i];
    return NULL;
}

static InstanceRecord *add_instance(VkInstance instance, PFN_vkGetInstanceProcAddr gip)
{
    for (size_t i = 0; i < KS_MAX_INSTANCES; i++) {
        if (g_instances[i].instance == VK_NULL_HANDLE) {
            InstanceRecord *rec = &g_instances[i];
            memset(rec, 0, sizeof(*rec));
            rec->instance = instance;
            rec->gip = gip;
            rec->DestroyInstance = (PFN_vkDestroyInstance)gip(instance, "vkDestroyInstance");
            rec->EnumeratePhysicalDevices = (PFN_vkEnumeratePhysicalDevices)gip(instance, "vkEnumeratePhysicalDevices");
            rec->GetPhysicalDeviceMemoryProperties = (PFN_vkGetPhysicalDeviceMemoryProperties)gip(instance, "vkGetPhysicalDeviceMemoryProperties");
            return rec;
        }
    }
    return NULL;
}

static void remove_instance(VkInstance instance)
{
    for (size_t i = 0; i < KS_MAX_PHYSICAL_DEVICES; i++)
        if (g_physical_devices[i].instance == instance) memset(&g_physical_devices[i], 0, sizeof(g_physical_devices[i]));
    for (size_t i = 0; i < KS_MAX_INSTANCES; i++)
        if (g_instances[i].instance == instance) memset(&g_instances[i], 0, sizeof(g_instances[i]));
}

static void remember_physical_device(VkInstance instance, VkPhysicalDevice physical)
{
    for (size_t i = 0; i < KS_MAX_PHYSICAL_DEVICES; i++) {
        if (g_physical_devices[i].physical == physical) {
            g_physical_devices[i].instance = instance;
            return;
        }
    }
    for (size_t i = 0; i < KS_MAX_PHYSICAL_DEVICES; i++) {
        if (g_physical_devices[i].physical == VK_NULL_HANDLE) {
            g_physical_devices[i].physical = physical;
            g_physical_devices[i].instance = instance;
            return;
        }
    }
}

static VkInstance instance_for_physical(VkPhysicalDevice physical)
{
    for (size_t i = 0; i < KS_MAX_PHYSICAL_DEVICES; i++)
        if (g_physical_devices[i].physical == physical) return g_physical_devices[i].instance;
    return VK_NULL_HANDLE;
}

static DeviceRecord *find_device(VkDevice device)
{
    for (size_t i = 0; i < KS_MAX_DEVICES; i++)
        if (g_devices[i].device == device) return &g_devices[i];
    return NULL;
}

static DeviceRecord *add_device(VkDevice device, VkPhysicalDevice physical, PFN_vkGetDeviceProcAddr gdp)
{
    for (size_t i = 0; i < KS_MAX_DEVICES; i++) {
        if (g_devices[i].device == VK_NULL_HANDLE) {
            DeviceRecord *rec = &g_devices[i];
            memset(rec, 0, sizeof(*rec));
            rec->device = device;
            rec->physical = physical;
            rec->gdp = gdp;
            rec->DestroyDevice = (PFN_vkDestroyDevice)gdp(device, "vkDestroyDevice");
            rec->GetDeviceQueue = (PFN_vkGetDeviceQueue)gdp(device, "vkGetDeviceQueue");
            rec->GetDeviceQueue2 = (PFN_vkGetDeviceQueue2)gdp(device, "vkGetDeviceQueue2");
            rec->CreateSwapchainKHR = (PFN_vkCreateSwapchainKHR)gdp(device, "vkCreateSwapchainKHR");
            rec->DestroySwapchainKHR = (PFN_vkDestroySwapchainKHR)gdp(device, "vkDestroySwapchainKHR");
            rec->GetSwapchainImagesKHR = (PFN_vkGetSwapchainImagesKHR)gdp(device, "vkGetSwapchainImagesKHR");
            rec->QueuePresentKHR = (PFN_vkQueuePresentKHR)gdp(device, "vkQueuePresentKHR");
            rec->CreateBuffer = (PFN_vkCreateBuffer)gdp(device, "vkCreateBuffer");
            rec->DestroyBuffer = (PFN_vkDestroyBuffer)gdp(device, "vkDestroyBuffer");
            rec->GetBufferMemoryRequirements = (PFN_vkGetBufferMemoryRequirements)gdp(device, "vkGetBufferMemoryRequirements");
            rec->AllocateMemory = (PFN_vkAllocateMemory)gdp(device, "vkAllocateMemory");
            rec->FreeMemory = (PFN_vkFreeMemory)gdp(device, "vkFreeMemory");
            rec->BindBufferMemory = (PFN_vkBindBufferMemory)gdp(device, "vkBindBufferMemory");
            rec->MapMemory = (PFN_vkMapMemory)gdp(device, "vkMapMemory");
            rec->UnmapMemory = (PFN_vkUnmapMemory)gdp(device, "vkUnmapMemory");
            rec->InvalidateMappedMemoryRanges = (PFN_vkInvalidateMappedMemoryRanges)gdp(device, "vkInvalidateMappedMemoryRanges");
            rec->CreateCommandPool = (PFN_vkCreateCommandPool)gdp(device, "vkCreateCommandPool");
            rec->DestroyCommandPool = (PFN_vkDestroyCommandPool)gdp(device, "vkDestroyCommandPool");
            rec->ResetCommandPool = (PFN_vkResetCommandPool)gdp(device, "vkResetCommandPool");
            rec->AllocateCommandBuffers = (PFN_vkAllocateCommandBuffers)gdp(device, "vkAllocateCommandBuffers");
            rec->BeginCommandBuffer = (PFN_vkBeginCommandBuffer)gdp(device, "vkBeginCommandBuffer");
            rec->EndCommandBuffer = (PFN_vkEndCommandBuffer)gdp(device, "vkEndCommandBuffer");
            rec->CmdPipelineBarrier = (PFN_vkCmdPipelineBarrier)gdp(device, "vkCmdPipelineBarrier");
            rec->CmdCopyImageToBuffer = (PFN_vkCmdCopyImageToBuffer)gdp(device, "vkCmdCopyImageToBuffer");
            rec->QueueSubmit = (PFN_vkQueueSubmit)gdp(device, "vkQueueSubmit");
            rec->CreateFence = (PFN_vkCreateFence)gdp(device, "vkCreateFence");
            rec->DestroyFence = (PFN_vkDestroyFence)gdp(device, "vkDestroyFence");
            rec->ResetFences = (PFN_vkResetFences)gdp(device, "vkResetFences");
            rec->WaitForFences = (PFN_vkWaitForFences)gdp(device, "vkWaitForFences");

            VkInstance instance = instance_for_physical(physical);
            InstanceRecord *inst = find_instance(instance);
            if (inst && inst->GetPhysicalDeviceMemoryProperties)
                inst->GetPhysicalDeviceMemoryProperties(physical, &rec->memory_properties);
            return rec;
        }
    }
    return NULL;
}

static void destroy_capture_resources(DeviceRecord *dev, CaptureResources *res)
{
    if (!dev || !res) return;
    if (res->buffer && dev->DestroyBuffer) dev->DestroyBuffer(dev->device, res->buffer, NULL);
    if (res->memory && dev->FreeMemory) dev->FreeMemory(dev->device, res->memory, NULL);
    if (res->fence && dev->DestroyFence) dev->DestroyFence(dev->device, res->fence, NULL);
    if (res->command_pool && dev->DestroyCommandPool) dev->DestroyCommandPool(dev->device, res->command_pool, NULL);
    memset(res, 0, sizeof(*res));
}

static void remove_swapchain(VkSwapchainKHR swapchain)
{
    for (size_t i = 0; i < KS_MAX_SWAPCHAINS; i++) {
        if (g_swapchains[i].swapchain == swapchain) {
            DeviceRecord *dev = find_device(g_swapchains[i].device);
            destroy_capture_resources(dev, &g_swapchains[i].capture);
            memset(&g_swapchains[i], 0, sizeof(g_swapchains[i]));
        }
    }
}

static void remove_device(VkDevice device)
{
    for (size_t i = 0; i < KS_MAX_SWAPCHAINS; i++)
        if (g_swapchains[i].device == device) remove_swapchain(g_swapchains[i].swapchain);
    for (size_t i = 0; i < KS_MAX_QUEUES; i++)
        if (g_queues[i].device == device) memset(&g_queues[i], 0, sizeof(g_queues[i]));
    for (size_t i = 0; i < KS_MAX_DEVICES; i++)
        if (g_devices[i].device == device) memset(&g_devices[i], 0, sizeof(g_devices[i]));
}

static QueueRecord *find_queue(VkQueue queue)
{
    for (size_t i = 0; i < KS_MAX_QUEUES; i++)
        if (g_queues[i].queue == queue) return &g_queues[i];
    return NULL;
}

static void remember_queue(VkDevice device, VkQueue queue, uint32_t family)
{
    if (!queue) return;
    for (size_t i = 0; i < KS_MAX_QUEUES; i++) {
        if (g_queues[i].queue == queue) {
            g_queues[i].device = device;
            g_queues[i].family = family;
            tracef("remembered queue %p device=%p family=%u", (void *)queue, (void *)device, family);
            return;
        }
    }
    for (size_t i = 0; i < KS_MAX_QUEUES; i++) {
        if (g_queues[i].queue == VK_NULL_HANDLE) {
            g_queues[i].queue = queue;
            g_queues[i].device = device;
            g_queues[i].family = family;
            tracef("remembered queue %p device=%p family=%u", (void *)queue, (void *)device, family);
            return;
        }
    }
}

static SwapchainRecord *find_swapchain(VkSwapchainKHR swapchain)
{
    for (size_t i = 0; i < KS_MAX_SWAPCHAINS; i++)
        if (g_swapchains[i].swapchain == swapchain) return &g_swapchains[i];
    return NULL;
}

static SwapchainRecord *add_swapchain(VkDevice device, VkSwapchainKHR swapchain, const VkSwapchainCreateInfoKHR *info)
{
    remove_swapchain(swapchain);
    for (size_t i = 0; i < KS_MAX_SWAPCHAINS; i++) {
        if (g_swapchains[i].swapchain == VK_NULL_HANDLE) {
            SwapchainRecord *rec = &g_swapchains[i];
            memset(rec, 0, sizeof(*rec));
            rec->swapchain = swapchain;
            rec->device = device;
            rec->format = info->imageFormat;
            rec->extent = info->imageExtent;
            rec->transfer_src = (info->imageUsage & VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0;
            return rec;
        }
    }
    return NULL;
}

static uint32_t find_memory_type(DeviceRecord *dev, uint32_t type_bits, VkMemoryPropertyFlags required, bool *coherent)
{
    for (uint32_t i = 0; i < dev->memory_properties.memoryTypeCount; i++) {
        if ((type_bits & (1u << i)) &&
            (dev->memory_properties.memoryTypes[i].propertyFlags & required) == required) {
            if (coherent) *coherent = (dev->memory_properties.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
            return i;
        }
    }
    VkMemoryPropertyFlags fallback = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    for (uint32_t i = 0; i < dev->memory_properties.memoryTypeCount; i++) {
        if ((type_bits & (1u << i)) &&
            (dev->memory_properties.memoryTypes[i].propertyFlags & fallback) == fallback) {
            if (coherent) *coherent = (dev->memory_properties.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
            return i;
        }
    }
    return UINT32_MAX;
}

static bool ensure_capture_resources(DeviceRecord *dev, QueueRecord *queue, SwapchainRecord *swapchain)
{
    CaptureResources *res = &swapchain->capture;
    VkDeviceSize byte_len = (VkDeviceSize)swapchain->extent.width * (VkDeviceSize)swapchain->extent.height * 4u;
    if (res->byte_len == byte_len && res->buffer && res->memory && res->command_pool && res->command_buffer && res->fence)
        return true;

    destroy_capture_resources(dev, res);

    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue->family,
    };
    if (dev->CreateCommandPool(dev->device, &pool_info, NULL, &res->command_pool) != VK_SUCCESS) return false;

    VkCommandBufferAllocateInfo cmd_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = res->command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    if (dev->AllocateCommandBuffers(dev->device, &cmd_info, &res->command_buffer) != VK_SUCCESS) {
        destroy_capture_resources(dev, res);
        return false;
    }

    VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (dev->CreateFence(dev->device, &fence_info, NULL, &res->fence) != VK_SUCCESS) {
        destroy_capture_resources(dev, res);
        return false;
    }

    VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = byte_len,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (dev->CreateBuffer(dev->device, &buffer_info, NULL, &res->buffer) != VK_SUCCESS) {
        destroy_capture_resources(dev, res);
        return false;
    }

    VkMemoryRequirements req;
    dev->GetBufferMemoryRequirements(dev->device, res->buffer, &req);
    bool coherent = false;
    uint32_t memory_type = find_memory_type(dev, req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &coherent);
    if (memory_type == UINT32_MAX) {
        destroy_capture_resources(dev, res);
        return false;
    }

    VkMemoryAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type,
    };
    if (dev->AllocateMemory(dev->device, &alloc_info, NULL, &res->memory) != VK_SUCCESS ||
        dev->BindBufferMemory(dev->device, res->buffer, res->memory, 0) != VK_SUCCESS) {
        destroy_capture_resources(dev, res);
        return false;
    }

    res->byte_len = byte_len;
    res->coherent = coherent;
    return true;
}

static int external_format_for_vk(VkFormat format)
{
    switch (format) {
    case VK_FORMAT_R8G8B8A8_UNORM:
    case VK_FORMAT_R8G8B8A8_SRGB:
        return KS_EXTERNAL_FRAMEBUFFER_RGBA8;
    case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
        return KS_EXTERNAL_FRAMEBUFFER_A2B10G10R10_UNORM_PACK32;
    case VK_FORMAT_B8G8R8A8_UNORM:
    case VK_FORMAT_B8G8R8A8_SRGB:
        return KS_EXTERNAL_FRAMEBUFFER_BGRA8;
    default:
        return -1;
    }
}

static bool format_supported(VkFormat format)
{
    return external_format_for_vk(format) >= 0;
}

#if defined(KS_VULKAN_LAYER_TESTING)
int ks_vulkan_test_capture_enabled(void) { return capture_enabled(); }
int ks_vulkan_test_trace_enabled(void) { return trace_enabled(); }
int ks_vulkan_test_external_format_for_vk(int format) { return external_format_for_vk((VkFormat)format); }
#endif

static bool capture_swapchain_image(DeviceRecord *dev, QueueRecord *queue, SwapchainRecord *swapchain, uint32_t image_index, const VkPresentInfoKHR *present_info)
{
    if (!capture_enabled()) return false;
    if (!swapchain) return false;
    if (image_index >= swapchain->image_count) {
        if (!swapchain->logged_missing_images) {
            tracef("swapchain image index unavailable; image_index=%u image_count=%u", image_index, swapchain->image_count);
            swapchain->logged_missing_images = true;
        }
        return false;
    }
    if (!swapchain->transfer_src) {
        if (!swapchain->logged_no_transfer_src) {
            tracef("swapchain lacks VK_IMAGE_USAGE_TRANSFER_SRC_BIT; skipping capture");
            swapchain->logged_no_transfer_src = true;
        }
        return false;
    }
    if (!format_supported(swapchain->format)) {
        if (!swapchain->logged_unsupported_format) {
            tracef("unsupported swapchain format %d; skipping capture", (int)swapchain->format);
            swapchain->logged_unsupported_format = true;
        }
        return false;
    }
    if (present_info->waitSemaphoreCount > KS_MAX_PRESENT_WAITS) {
        tracef("present has too many wait semaphores; count=%u", present_info->waitSemaphoreCount);
        return false;
    }
    if (!present_fn()) {
        tracef("preload framebuffer callback not found; skipping capture");
        return false;
    }
    if (!ensure_capture_resources(dev, queue, swapchain)) {
        tracef("failed to initialize capture resources");
        return false;
    }

    CaptureResources *res = &swapchain->capture;
    VkResult rc = dev->ResetFences(dev->device, 1, &res->fence);
    if (rc != VK_SUCCESS) return false;
    rc = dev->ResetCommandPool(dev->device, res->command_pool, 0);
    if (rc != VK_SUCCESS) return false;

    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    rc = dev->BeginCommandBuffer(res->command_buffer, &begin);
    if (rc != VK_SUCCESS) return false;

    VkImageMemoryBarrier to_transfer = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = swapchain->images[image_index],
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    dev->CmdPipelineBarrier(res->command_buffer,
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &to_transfer);

    VkBufferImageCopy copy = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { swapchain->extent.width, swapchain->extent.height, 1 },
    };
    dev->CmdCopyImageToBuffer(res->command_buffer, swapchain->images[image_index],
        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, res->buffer, 1, &copy);

    VkImageMemoryBarrier to_present = to_transfer;
    to_present.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    to_present.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
    to_present.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    to_present.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    dev->CmdPipelineBarrier(res->command_buffer,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        0, 0, NULL, 0, NULL, 1, &to_present);

    rc = dev->EndCommandBuffer(res->command_buffer);
    if (rc != VK_SUCCESS) return false;

    VkPipelineStageFlags wait_stages[KS_MAX_PRESENT_WAITS];
    for (uint32_t i = 0; i < present_info->waitSemaphoreCount; i++)
        wait_stages[i] = VK_PIPELINE_STAGE_TRANSFER_BIT;

    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = present_info->waitSemaphoreCount,
        .pWaitSemaphores = present_info->pWaitSemaphores,
        .pWaitDstStageMask = wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &res->command_buffer,
    };
    rc = dev->QueueSubmit(queue->queue, 1, &submit, res->fence);
    if (rc != VK_SUCCESS) return false;

    rc = dev->WaitForFences(dev->device, 1, &res->fence, VK_TRUE, UINT64_MAX);
    if (rc != VK_SUCCESS) return false;

    if (!res->coherent && dev->InvalidateMappedMemoryRanges) {
        VkMappedMemoryRange range = {
            .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = res->memory,
            .offset = 0,
            .size = res->byte_len,
        };
        dev->InvalidateMappedMemoryRanges(dev->device, 1, &range);
    }

    void *mapped = NULL;
    rc = dev->MapMemory(dev->device, res->memory, 0, res->byte_len, 0, &mapped);
    if (rc != VK_SUCCESS || !mapped) return false;
    const int external_format = external_format_for_vk(swapchain->format);
    if (external_format < 0) {
        dev->UnmapMemory(dev->device, res->memory);
        return false;
    }
    present_fn()((int32_t)swapchain->extent.width, (int32_t)swapchain->extent.height, external_format, (const uint8_t *)mapped, (size_t)res->byte_len);
    dev->UnmapMemory(dev->device, res->memory);

    if (!swapchain->logged_capture_success) {
        tracef("captured first swapchain frame %ux%u format=%d", swapchain->extent.width, swapchain->extent.height, (int)swapchain->format);
        swapchain->logged_capture_success = true;
    }
    return true;
}

VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *version)
{
    if (!version) return VK_ERROR_INITIALIZATION_FAILED;
    if (version->loaderLayerInterfaceVersion > 2)
        version->loaderLayerInterfaceVersion = 2;
    version->pfnGetInstanceProcAddr = ks_vkGetInstanceProcAddr;
    version->pfnGetDeviceProcAddr = ks_vkGetDeviceProcAddr;
    version->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
    return ks_vkGetInstanceProcAddr(instance, name);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice device, const char *name)
{
    return ks_vkGetDeviceProcAddr(device, name);
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(uint32_t *count, VkLayerProperties *properties)
{
    if (!properties) {
        *count = 1;
        return VK_SUCCESS;
    }
    if (*count < 1) return VK_INCOMPLETE;
    memset(properties, 0, sizeof(*properties));
    strncpy(properties->layerName, KS_LAYER_NAME, sizeof(properties->layerName) - 1);
    properties->specVersion = VK_API_VERSION_1_0;
    properties->implementationVersion = 1;
    strncpy(properties->description, "Katzensteg Vulkan capture layer", sizeof(properties->description) - 1);
    *count = 1;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(const char *layer_name, uint32_t *count, VkExtensionProperties *properties)
{
    if (layer_name && strcmp(layer_name, KS_LAYER_NAME) == 0) {
        *count = 0;
        return VK_SUCCESS;
    }
    *count = 0;
    (void)properties;
    return VK_SUCCESS;
}

static VkResult VKAPI_CALL ks_vkCreateInstance(const VkInstanceCreateInfo *create_info, const VkAllocationCallbacks *allocator, VkInstance *instance)
{
    VkLayerInstanceCreateInfo *chain = instance_link_info(create_info);
    if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr next_gip = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

    PFN_vkCreateInstance create = (PFN_vkCreateInstance)next_gip(VK_NULL_HANDLE, "vkCreateInstance");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult rc = create(create_info, allocator, instance);
    if (rc == VK_SUCCESS && instance && *instance) {
        pthread_mutex_lock(&g_lock);
        add_instance(*instance, next_gip);
        pthread_mutex_unlock(&g_lock);
        tracef("created instance %p", (void *)*instance);
    }
    return rc;
}

static void VKAPI_CALL ks_vkDestroyInstance(VkInstance instance, const VkAllocationCallbacks *allocator)
{
    PFN_vkDestroyInstance destroy = NULL;
    pthread_mutex_lock(&g_lock);
    InstanceRecord *rec = find_instance(instance);
    if (rec) destroy = rec->DestroyInstance;
    remove_instance(instance);
    pthread_mutex_unlock(&g_lock);
    if (destroy) destroy(instance, allocator);
}

static VkResult VKAPI_CALL ks_vkEnumeratePhysicalDevices(VkInstance instance, uint32_t *count, VkPhysicalDevice *physical_devices)
{
    PFN_vkEnumeratePhysicalDevices enumerate = NULL;
    pthread_mutex_lock(&g_lock);
    InstanceRecord *rec = find_instance(instance);
    if (rec) enumerate = rec->EnumeratePhysicalDevices;
    pthread_mutex_unlock(&g_lock);
    if (!enumerate) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult rc = enumerate(instance, count, physical_devices);
    if ((rc == VK_SUCCESS || rc == VK_INCOMPLETE) && physical_devices) {
        pthread_mutex_lock(&g_lock);
        for (uint32_t i = 0; i < *count; i++) remember_physical_device(instance, physical_devices[i]);
        pthread_mutex_unlock(&g_lock);
    }
    return rc;
}

static VkResult VKAPI_CALL ks_vkCreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo *create_info, const VkAllocationCallbacks *allocator, VkDevice *device)
{
    VkLayerDeviceCreateInfo *chain = device_link_info(create_info);
    if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr next_gip = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr next_gdp = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

    PFN_vkCreateDevice create = (PFN_vkCreateDevice)next_gip(VK_NULL_HANDLE, "vkCreateDevice");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult rc = create(physical, create_info, allocator, device);
    if (rc == VK_SUCCESS && device && *device) {
        pthread_mutex_lock(&g_lock);
        add_device(*device, physical, next_gdp);
        pthread_mutex_unlock(&g_lock);
        tracef("created device %p", (void *)*device);
    }
    return rc;
}

static void VKAPI_CALL ks_vkDestroyDevice(VkDevice device, const VkAllocationCallbacks *allocator)
{
    PFN_vkDestroyDevice destroy = NULL;
    pthread_mutex_lock(&g_lock);
    DeviceRecord *rec = find_device(device);
    if (rec) destroy = rec->DestroyDevice;
    remove_device(device);
    pthread_mutex_unlock(&g_lock);
    if (destroy) destroy(device, allocator);
}

static void VKAPI_CALL ks_vkGetDeviceQueue(VkDevice device, uint32_t queue_family, uint32_t queue_index, VkQueue *queue)
{
    PFN_vkGetDeviceQueue real = NULL;
    pthread_mutex_lock(&g_lock);
    DeviceRecord *dev = find_device(device);
    if (dev) real = dev->GetDeviceQueue;
    pthread_mutex_unlock(&g_lock);
    if (real) real(device, queue_family, queue_index, queue);
    if (queue && *queue) {
        pthread_mutex_lock(&g_lock);
        remember_queue(device, *queue, queue_family);
        pthread_mutex_unlock(&g_lock);
    }
}

static void VKAPI_CALL ks_vkGetDeviceQueue2(VkDevice device, const VkDeviceQueueInfo2 *queue_info, VkQueue *queue)
{
    PFN_vkGetDeviceQueue2 real = NULL;
    pthread_mutex_lock(&g_lock);
    DeviceRecord *dev = find_device(device);
    if (dev) real = dev->GetDeviceQueue2;
    pthread_mutex_unlock(&g_lock);
    if (real) real(device, queue_info, queue);
    if (queue_info && queue && *queue) {
        pthread_mutex_lock(&g_lock);
        remember_queue(device, *queue, queue_info->queueFamilyIndex);
        pthread_mutex_unlock(&g_lock);
    }
}

static VkResult VKAPI_CALL ks_vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *create_info, const VkAllocationCallbacks *allocator, VkSwapchainKHR *swapchain)
{
    PFN_vkCreateSwapchainKHR real = NULL;
    pthread_mutex_lock(&g_lock);
    DeviceRecord *dev = find_device(device);
    if (dev) real = dev->CreateSwapchainKHR;
    pthread_mutex_unlock(&g_lock);
    if (!real) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult rc = real(device, create_info, allocator, swapchain);
    if (rc == VK_SUCCESS && swapchain && *swapchain && create_info) {
        pthread_mutex_lock(&g_lock);
        if (create_info->oldSwapchain) remove_swapchain(create_info->oldSwapchain);
        add_swapchain(device, *swapchain, create_info);
        pthread_mutex_unlock(&g_lock);
        tracef("created swapchain %p %ux%u format=%d usage=0x%x", (void *)*swapchain, create_info->imageExtent.width, create_info->imageExtent.height, (int)create_info->imageFormat, create_info->imageUsage);
    }
    return rc;
}

static void VKAPI_CALL ks_vkDestroySwapchainKHR(VkDevice device, VkSwapchainKHR swapchain, const VkAllocationCallbacks *allocator)
{
    PFN_vkDestroySwapchainKHR real = NULL;
    pthread_mutex_lock(&g_lock);
    DeviceRecord *dev = find_device(device);
    if (dev) real = dev->DestroySwapchainKHR;
    remove_swapchain(swapchain);
    pthread_mutex_unlock(&g_lock);
    if (real) real(device, swapchain, allocator);
}

static VkResult VKAPI_CALL ks_vkGetSwapchainImagesKHR(VkDevice device, VkSwapchainKHR swapchain, uint32_t *count, VkImage *images)
{
    PFN_vkGetSwapchainImagesKHR real = NULL;
    pthread_mutex_lock(&g_lock);
    DeviceRecord *dev = find_device(device);
    if (dev) real = dev->GetSwapchainImagesKHR;
    pthread_mutex_unlock(&g_lock);
    if (!real) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult rc = real(device, swapchain, count, images);
    if ((rc == VK_SUCCESS || rc == VK_INCOMPLETE) && count && images) {
        pthread_mutex_lock(&g_lock);
        SwapchainRecord *rec = find_swapchain(swapchain);
        if (rec) {
            rec->image_count = *count < KS_MAX_SWAPCHAIN_IMAGES ? *count : KS_MAX_SWAPCHAIN_IMAGES;
            for (uint32_t i = 0; i < rec->image_count; i++) rec->images[i] = images[i];
            tracef("recorded %u swapchain images for %p", rec->image_count, (void *)swapchain);
        }
        pthread_mutex_unlock(&g_lock);
    }
    return rc;
}

static VkResult VKAPI_CALL ks_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *present_info)
{
    PFN_vkQueuePresentKHR real = NULL;
    DeviceRecord *dev = NULL;
    QueueRecord *queue_rec = NULL;
    SwapchainRecord *swapchain = NULL;
    uint32_t image_index = 0;

    pthread_mutex_lock(&g_lock);
    queue_rec = find_queue(queue);
    if (queue_rec) dev = find_device(queue_rec->device);
    if (dev) real = dev->QueuePresentKHR;
    if (present_info && present_info->swapchainCount == 1 && present_info->pSwapchains && present_info->pImageIndices) {
        swapchain = find_swapchain(present_info->pSwapchains[0]);
        image_index = present_info->pImageIndices[0];
    } else if (!g_logged_present_unsupported_shape) {
        tracef("present shape unsupported; present_info=%p", (const void *)present_info);
        g_logged_present_unsupported_shape = true;
    }
    pthread_mutex_unlock(&g_lock);

    if (!real) {
        if (!g_logged_present_missing_real) {
            tracef("present hook missing real vkQueuePresentKHR");
            g_logged_present_missing_real = true;
        }
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    bool consumed_waits = false;
    if (dev && queue_rec && swapchain) {
        consumed_waits = capture_swapchain_image(dev, queue_rec, swapchain, image_index, present_info);
    } else {
        if (!queue_rec && !g_logged_present_missing_queue) {
            tracef("present queue not remembered; queue=%p", (void *)queue);
            g_logged_present_missing_queue = true;
        }
        if (queue_rec && !dev && !g_logged_present_missing_device) {
            tracef("present queue device not remembered; queue=%p device=%p", (void *)queue, (void *)queue_rec->device);
            g_logged_present_missing_device = true;
        }
        if (!swapchain && !g_logged_present_missing_swapchain) {
            const VkSwapchainKHR missing = (present_info && present_info->swapchainCount > 0 && present_info->pSwapchains) ? present_info->pSwapchains[0] : VK_NULL_HANDLE;
            tracef("present swapchain not remembered; swapchain=%p", (void *)missing);
            g_logged_present_missing_swapchain = true;
        }
    }

    if (consumed_waits) {
        VkPresentInfoKHR copy = *present_info;
        copy.waitSemaphoreCount = 0;
        copy.pWaitSemaphores = NULL;
        return real(queue, &copy);
    }
    return real(queue, present_info);
}

static PFN_vkVoidFunction VKAPI_CALL ks_vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
    if (!name) return NULL;
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)ks_vkGetInstanceProcAddr;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)ks_vkGetDeviceProcAddr;
    if (strcmp(name, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)ks_vkCreateInstance;
    if (strcmp(name, "vkDestroyInstance") == 0) return (PFN_vkVoidFunction)ks_vkDestroyInstance;
    if (strcmp(name, "vkEnumeratePhysicalDevices") == 0) return (PFN_vkVoidFunction)ks_vkEnumeratePhysicalDevices;
    if (strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)ks_vkCreateDevice;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)ks_vkDestroyDevice;
    if (strcmp(name, "vkGetDeviceQueue") == 0) return (PFN_vkVoidFunction)ks_vkGetDeviceQueue;
    if (strcmp(name, "vkGetDeviceQueue2") == 0) return (PFN_vkVoidFunction)ks_vkGetDeviceQueue2;
    if (strcmp(name, "vkCreateSwapchainKHR") == 0) return (PFN_vkVoidFunction)ks_vkCreateSwapchainKHR;
    if (strcmp(name, "vkDestroySwapchainKHR") == 0) return (PFN_vkVoidFunction)ks_vkDestroySwapchainKHR;
    if (strcmp(name, "vkGetSwapchainImagesKHR") == 0) return (PFN_vkVoidFunction)ks_vkGetSwapchainImagesKHR;
    if (strcmp(name, "vkQueuePresentKHR") == 0) return (PFN_vkVoidFunction)ks_vkQueuePresentKHR;
    if (strcmp(name, "vkEnumerateInstanceLayerProperties") == 0) return (PFN_vkVoidFunction)vkEnumerateInstanceLayerProperties;
    if (strcmp(name, "vkEnumerateInstanceExtensionProperties") == 0) return (PFN_vkVoidFunction)vkEnumerateInstanceExtensionProperties;

    PFN_vkGetInstanceProcAddr gip = NULL;
    pthread_mutex_lock(&g_lock);
    InstanceRecord *rec = find_instance(instance);
    if (rec) gip = rec->gip;
    pthread_mutex_unlock(&g_lock);
    return gip ? gip(instance, name) : NULL;
}

static PFN_vkVoidFunction VKAPI_CALL ks_vkGetDeviceProcAddr(VkDevice device, const char *name)
{
    if (!name) return NULL;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)ks_vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)ks_vkDestroyDevice;
    if (strcmp(name, "vkGetDeviceQueue") == 0) return (PFN_vkVoidFunction)ks_vkGetDeviceQueue;
    if (strcmp(name, "vkGetDeviceQueue2") == 0) return (PFN_vkVoidFunction)ks_vkGetDeviceQueue2;
    if (strcmp(name, "vkCreateSwapchainKHR") == 0) return (PFN_vkVoidFunction)ks_vkCreateSwapchainKHR;
    if (strcmp(name, "vkDestroySwapchainKHR") == 0) return (PFN_vkVoidFunction)ks_vkDestroySwapchainKHR;
    if (strcmp(name, "vkGetSwapchainImagesKHR") == 0) return (PFN_vkVoidFunction)ks_vkGetSwapchainImagesKHR;
    if (strcmp(name, "vkQueuePresentKHR") == 0) return (PFN_vkVoidFunction)ks_vkQueuePresentKHR;

    PFN_vkGetDeviceProcAddr gdp = NULL;
    pthread_mutex_lock(&g_lock);
    DeviceRecord *rec = find_device(device);
    if (rec) gdp = rec->gdp;
    pthread_mutex_unlock(&g_lock);
    return gdp ? gdp(device, name) : NULL;
}
