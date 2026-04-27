#include <SDL.h>
#include <SDL_vulkan.h>
#include <vulkan/vulkan.h>

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    DEFAULT_WINDOW_WIDTH = 960,
    DEFAULT_WINDOW_HEIGHT = 540,
    DEFAULT_RUN_SECONDS = 20,
    MAX_FRAMES_IN_FLIGHT = 2,
};

typedef struct Options {
    bool fullscreen_desktop;
    bool log_frames;
    int seconds;
} Options;

typedef struct FrameSync {
    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkFence in_flight;
} FrameSync;

typedef struct App {
    SDL_Window *window;
    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family;
    VkSwapchainKHR swapchain;
    VkFormat swapchain_format;
    VkExtent2D extent;
    uint32_t image_count;
    VkImage images[8];
    VkImageView image_views[8];
    VkRenderPass render_pass;
    VkFramebuffer framebuffers[8];
    VkCommandPool command_pool;
    VkCommandBuffer command_buffers[8];
    FrameSync sync[MAX_FRAMES_IN_FLIGHT];
    uint32_t frame_index;
} App;

static void usage(const char *argv0)
{
    fprintf(stderr, "usage: %s [--fullscreen-desktop] [--log-frames] [--seconds N]\n", argv0);
}

static bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--fullscreen-desktop") == 0) {
            options->fullscreen_desktop = true;
        } else if (strcmp(argv[i], "--log-frames") == 0) {
            options->log_frames = true;
        } else if (strcmp(argv[i], "--seconds") == 0) {
            if (i + 1 >= argc) return false;
            options->seconds = atoi(argv[++i]);
            if (options->seconds <= 0) return false;
        } else {
            return false;
        }
    }
    return true;
}

static bool check_vk(VkResult result, const char *what)
{
    if (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) return true;
    fprintf(stderr, "katzensteg-vulkan-probe: %s failed: %d\n", what, result);
    return false;
}

static bool extension_available(const char *name, const VkExtensionProperties *props, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++)
        if (strcmp(name, props[i].extensionName) == 0) return true;
    return false;
}

static bool create_instance(App *app)
{
    uint32_t sdl_ext_count = 0;
    if (!SDL_Vulkan_GetInstanceExtensions(app->window, &sdl_ext_count, NULL)) {
        fprintf(stderr, "katzensteg-vulkan-probe: SDL_Vulkan_GetInstanceExtensions failed: %s\n", SDL_GetError());
        return false;
    }

    const char **extensions = calloc(sdl_ext_count + 2, sizeof(*extensions));
    if (!extensions) return false;
    if (!SDL_Vulkan_GetInstanceExtensions(app->window, &sdl_ext_count, extensions)) {
        fprintf(stderr, "katzensteg-vulkan-probe: SDL_Vulkan_GetInstanceExtensions failed: %s\n", SDL_GetError());
        free(extensions);
        return false;
    }

    uint32_t available_count = 0;
    vkEnumerateInstanceExtensionProperties(NULL, &available_count, NULL);
    VkExtensionProperties *available = calloc(available_count, sizeof(*available));
    if (available) vkEnumerateInstanceExtensionProperties(NULL, &available_count, available);

    VkInstanceCreateFlags flags = 0;
    if (available && extension_available(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME, available, available_count)) {
        extensions[sdl_ext_count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    free(available);

    VkApplicationInfo app_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "katzensteg-vulkan-probe",
        .applicationVersion = VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "katzensteg",
        .engineVersion = VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = VK_API_VERSION_1_0,
    };
    VkInstanceCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .flags = flags,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = sdl_ext_count,
        .ppEnabledExtensionNames = extensions,
    };
    bool ok = check_vk(vkCreateInstance(&create_info, NULL, &app->instance), "vkCreateInstance");
    free(extensions);
    return ok;
}

static bool pick_device(App *app)
{
    uint32_t device_count = 0;
    if (!check_vk(vkEnumeratePhysicalDevices(app->instance, &device_count, NULL), "vkEnumeratePhysicalDevices") || device_count == 0)
        return false;
    VkPhysicalDevice *devices = calloc(device_count, sizeof(*devices));
    if (!devices) return false;
    vkEnumeratePhysicalDevices(app->instance, &device_count, devices);

    for (uint32_t d = 0; d < device_count; d++) {
        uint32_t family_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &family_count, NULL);
        VkQueueFamilyProperties *families = calloc(family_count, sizeof(*families));
        if (!families) continue;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &family_count, families);
        for (uint32_t i = 0; i < family_count; i++) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(devices[d], i, app->surface, &present);
            if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                app->physical_device = devices[d];
                app->queue_family = i;
                free(families);
                free(devices);
                return true;
            }
        }
        free(families);
    }

    free(devices);
    fprintf(stderr, "katzensteg-vulkan-probe: no graphics+present Vulkan queue found\n");
    return false;
}

static bool create_device(App *app)
{
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = app->queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };

    uint32_t ext_count = 0;
    vkEnumerateDeviceExtensionProperties(app->physical_device, NULL, &ext_count, NULL);
    VkExtensionProperties *exts = calloc(ext_count, sizeof(*exts));
    if (exts) vkEnumerateDeviceExtensionProperties(app->physical_device, NULL, &ext_count, exts);
    const char *device_exts[2] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME, NULL };
    uint32_t device_ext_count = 1;
    if (exts && extension_available("VK_KHR_portability_subset", exts, ext_count))
        device_exts[device_ext_count++] = "VK_KHR_portability_subset";
    free(exts);

    VkDeviceCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = device_ext_count,
        .ppEnabledExtensionNames = device_exts,
    };
    if (!check_vk(vkCreateDevice(app->physical_device, &create_info, NULL, &app->device), "vkCreateDevice"))
        return false;
    vkGetDeviceQueue(app->device, app->queue_family, 0, &app->queue);
    return true;
}

static VkSurfaceFormatKHR choose_surface_format(VkSurfaceFormatKHR *formats, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM || formats[i].format == VK_FORMAT_B8G8R8A8_SRGB)
            return formats[i];
    }
    return formats[0];
}

static bool create_swapchain(App *app)
{
    VkSurfaceCapabilitiesKHR caps;
    if (!check_vk(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(app->physical_device, app->surface, &caps), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"))
        return false;

    uint32_t format_count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(app->physical_device, app->surface, &format_count, NULL);
    VkSurfaceFormatKHR *formats = calloc(format_count, sizeof(*formats));
    if (!formats) return false;
    vkGetPhysicalDeviceSurfaceFormatsKHR(app->physical_device, app->surface, &format_count, formats);
    VkSurfaceFormatKHR format = choose_surface_format(formats, format_count);
    free(formats);

    app->extent = caps.currentExtent;
    if (app->extent.width == UINT32_MAX) {
        int w = DEFAULT_WINDOW_WIDTH;
        int h = DEFAULT_WINDOW_HEIGHT;
        SDL_Vulkan_GetDrawableSize(app->window, &w, &h);
        app->extent.width = (uint32_t)w;
        app->extent.height = (uint32_t)h;
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount) image_count = caps.maxImageCount;

    VkSwapchainCreateInfoKHR create_info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = app->surface,
        .minImageCount = image_count,
        .imageFormat = format.format,
        .imageColorSpace = format.colorSpace,
        .imageExtent = app->extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
    };
    if (!check_vk(vkCreateSwapchainKHR(app->device, &create_info, NULL, &app->swapchain), "vkCreateSwapchainKHR"))
        return false;
    app->swapchain_format = format.format;

    app->image_count = 8;
    if (!check_vk(vkGetSwapchainImagesKHR(app->device, app->swapchain, &app->image_count, app->images), "vkGetSwapchainImagesKHR"))
        return false;
    if (app->image_count > 8) app->image_count = 8;

    for (uint32_t i = 0; i < app->image_count; i++) {
        VkImageViewCreateInfo view_info = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = app->images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = app->swapchain_format,
            .components = { VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY },
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
        if (!check_vk(vkCreateImageView(app->device, &view_info, NULL, &app->image_views[i]), "vkCreateImageView"))
            return false;
    }
    return true;
}

static bool create_rendering(App *app)
{
    VkAttachmentDescription color_attachment = {
        .format = app->swapchain_format,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    VkAttachmentReference color_ref = { .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_ref,
    };
    VkSubpassDependency dependency = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };
    VkRenderPassCreateInfo pass_info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };
    if (!check_vk(vkCreateRenderPass(app->device, &pass_info, NULL, &app->render_pass), "vkCreateRenderPass"))
        return false;

    for (uint32_t i = 0; i < app->image_count; i++) {
        VkFramebufferCreateInfo fb_info = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = app->render_pass,
            .attachmentCount = 1,
            .pAttachments = &app->image_views[i],
            .width = app->extent.width,
            .height = app->extent.height,
            .layers = 1,
        };
        if (!check_vk(vkCreateFramebuffer(app->device, &fb_info, NULL, &app->framebuffers[i]), "vkCreateFramebuffer"))
            return false;
    }

    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = app->queue_family,
    };
    if (!check_vk(vkCreateCommandPool(app->device, &pool_info, NULL, &app->command_pool), "vkCreateCommandPool"))
        return false;

    VkCommandBufferAllocateInfo cmd_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = app->command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = app->image_count,
    };
    if (!check_vk(vkAllocateCommandBuffers(app->device, &cmd_info, app->command_buffers), "vkAllocateCommandBuffers"))
        return false;

    for (uint32_t i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
        VkSemaphoreCreateInfo sem_info = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
        if (!check_vk(vkCreateSemaphore(app->device, &sem_info, NULL, &app->sync[i].image_available), "vkCreateSemaphore") ||
            !check_vk(vkCreateSemaphore(app->device, &sem_info, NULL, &app->sync[i].render_finished), "vkCreateSemaphore") ||
            !check_vk(vkCreateFence(app->device, &fence_info, NULL, &app->sync[i].in_flight), "vkCreateFence"))
            return false;
    }
    return true;
}

static float wave(unsigned frame, float phase)
{
    return 0.5f + 0.5f * sinf((float)frame * 0.032f + phase);
}

static bool record_command(App *app, uint32_t image_index, unsigned frame)
{
    VkCommandBuffer cmd = app->command_buffers[image_index];
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    if (!check_vk(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer")) return false;

    VkClearValue clear = { .color = { .float32 = { 0.03f + wave(frame, 0.0f) * 0.20f, 0.04f + wave(frame, 2.1f) * 0.16f, 0.07f + wave(frame, 4.2f) * 0.22f, 1.0f } } };
    VkRenderPassBeginInfo pass = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = app->render_pass,
        .framebuffer = app->framebuffers[image_index],
        .renderArea = { { 0, 0 }, app->extent },
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(cmd, &pass, VK_SUBPASS_CONTENTS_INLINE);

    VkClearAttachment attachments[3] = {
        { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue = { .color = { .float32 = { 1.00f, 0.18f, 0.12f, 1.0f } } } },
        { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue = { .color = { .float32 = { 0.14f, 0.72f, 1.00f, 1.0f } } } },
        { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue = { .color = { .float32 = { 0.20f, 0.92f, 0.38f, 1.0f } } } },
    };
    int32_t w = (int32_t)app->extent.width;
    int32_t h = (int32_t)app->extent.height;
    int32_t block_w = w / 3;
    int32_t block_h = h / 3;
    int32_t x = (int32_t)((sinf(frame * 0.035f) * 0.5f + 0.5f) * (float)(w - block_w));
    int32_t y = (int32_t)((cosf(frame * 0.028f) * 0.5f + 0.5f) * (float)(h - block_h));
    VkClearRect rects[3] = {
        { .rect = { { x, y }, { (uint32_t)block_w, (uint32_t)block_h } }, .baseArrayLayer = 0, .layerCount = 1 },
        { .rect = { { w / 2 - block_w / 2, h / 2 - block_h / 2 }, { (uint32_t)block_w, (uint32_t)block_h } }, .baseArrayLayer = 0, .layerCount = 1 },
        { .rect = { { w - x - block_w, h - y - block_h }, { (uint32_t)block_w, (uint32_t)block_h } }, .baseArrayLayer = 0, .layerCount = 1 },
    };
    for (uint32_t i = 0; i < 3; i++)
        vkCmdClearAttachments(cmd, 1, &attachments[i], 1, &rects[i]);

    vkCmdEndRenderPass(cmd);
    return check_vk(vkEndCommandBuffer(cmd), "vkEndCommandBuffer");
}

static bool draw_frame(App *app, unsigned frame)
{
    FrameSync *sync = &app->sync[app->frame_index % MAX_FRAMES_IN_FLIGHT];
    vkWaitForFences(app->device, 1, &sync->in_flight, VK_TRUE, UINT64_MAX);

    uint32_t image_index = 0;
    VkResult acquire = vkAcquireNextImageKHR(app->device, app->swapchain, UINT64_MAX, sync->image_available, VK_NULL_HANDLE, &image_index);
    if (acquire == VK_ERROR_OUT_OF_DATE_KHR) return true;
    if (!check_vk(acquire, "vkAcquireNextImageKHR")) return false;

    vkResetFences(app->device, 1, &sync->in_flight);
    vkResetCommandBuffer(app->command_buffers[image_index], 0);
    if (!record_command(app, image_index, frame)) return false;

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &sync->image_available,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &app->command_buffers[image_index],
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &sync->render_finished,
    };
    if (!check_vk(vkQueueSubmit(app->queue, 1, &submit, sync->in_flight), "vkQueueSubmit")) return false;

    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &sync->render_finished,
        .swapchainCount = 1,
        .pSwapchains = &app->swapchain,
        .pImageIndices = &image_index,
    };
    VkResult presented = vkQueuePresentKHR(app->queue, &present);
    if (presented != VK_ERROR_OUT_OF_DATE_KHR && !check_vk(presented, "vkQueuePresentKHR")) return false;
    app->frame_index++;
    return true;
}

static bool init_app(App *app, const Options *options)
{
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        fprintf(stderr, "katzensteg-vulkan-probe: SDL_Init failed: %s\n", SDL_GetError());
        return false;
    }
    if (SDL_Vulkan_LoadLibrary(NULL) != 0)
        fprintf(stderr, "katzensteg-vulkan-probe: SDL_Vulkan_LoadLibrary warning: %s\n", SDL_GetError());

    Uint32 flags = SDL_WINDOW_VULKAN | SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE;
    if (options->fullscreen_desktop) flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    app->window = SDL_CreateWindow("katzensteg-vulkan-probe",
                                   SDL_WINDOWPOS_CENTERED,
                                   SDL_WINDOWPOS_CENTERED,
                                   DEFAULT_WINDOW_WIDTH,
                                   DEFAULT_WINDOW_HEIGHT,
                                   flags);
    if (!app->window) {
        fprintf(stderr, "katzensteg-vulkan-probe: SDL_CreateWindow failed: %s\n", SDL_GetError());
        return false;
    }
    return create_instance(app) &&
           SDL_Vulkan_CreateSurface(app->window, app->instance, &app->surface) &&
           pick_device(app) &&
           create_device(app) &&
           create_swapchain(app) &&
           create_rendering(app);
}

static void destroy_app(App *app)
{
    if (app->device) vkDeviceWaitIdle(app->device);
    for (uint32_t i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
        if (app->sync[i].image_available) vkDestroySemaphore(app->device, app->sync[i].image_available, NULL);
        if (app->sync[i].render_finished) vkDestroySemaphore(app->device, app->sync[i].render_finished, NULL);
        if (app->sync[i].in_flight) vkDestroyFence(app->device, app->sync[i].in_flight, NULL);
    }
    if (app->command_pool) vkDestroyCommandPool(app->device, app->command_pool, NULL);
    for (uint32_t i = 0; i < app->image_count; i++) {
        if (app->framebuffers[i]) vkDestroyFramebuffer(app->device, app->framebuffers[i], NULL);
        if (app->image_views[i]) vkDestroyImageView(app->device, app->image_views[i], NULL);
    }
    if (app->render_pass) vkDestroyRenderPass(app->device, app->render_pass, NULL);
    if (app->swapchain) vkDestroySwapchainKHR(app->device, app->swapchain, NULL);
    if (app->device) vkDestroyDevice(app->device, NULL);
    if (app->surface) vkDestroySurfaceKHR(app->instance, app->surface, NULL);
    if (app->instance) vkDestroyInstance(app->instance, NULL);
    if (app->window) SDL_DestroyWindow(app->window);
    SDL_Vulkan_UnloadLibrary();
    SDL_Quit();
}

int main(int argc, char **argv)
{
    Options options = {
        .fullscreen_desktop = false,
        .log_frames = false,
        .seconds = DEFAULT_RUN_SECONDS,
    };
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }

    App app;
    memset(&app, 0, sizeof(app));
    if (!init_app(&app, &options)) {
        destroy_app(&app);
        return 1;
    }

    int window_w = 0, window_h = 0, drawable_w = 0, drawable_h = 0;
    SDL_GetWindowSize(app.window, &window_w, &window_h);
    SDL_Vulkan_GetDrawableSize(app.window, &drawable_w, &drawable_h);
    fprintf(stderr, "katzensteg-vulkan-probe: window=%dx%d drawable=%dx%d swapchain=%ux%u fullscreen_desktop=%s\n",
            window_w, window_h, drawable_w, drawable_h, app.extent.width, app.extent.height,
            options.fullscreen_desktop ? "yes" : "no");

    const Uint32 start_ms = SDL_GetTicks();
    const Uint32 run_ms = (Uint32)options.seconds * 1000u;
    unsigned frame = 0;
    bool running = true;
    while (running && SDL_GetTicks() - start_ms < run_ms) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) running = false;
            if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE) running = false;
        }
        if (!draw_frame(&app, frame)) break;
        if (options.log_frames && (frame % 60u) == 0u)
            fprintf(stderr, "katzensteg-vulkan-probe: frame=%u swapchain=%ux%u\n", frame, app.extent.width, app.extent.height);
        frame++;
    }

    destroy_app(&app);
    return 0;
}
